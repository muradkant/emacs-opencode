;;; opencode-hyprland-popup.el --- OpenCode Hyprland popup frontend  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;; Commentary: see RESEARCH.md and the build brief.  This is the main
;; entrypoint file; transport (SSE), server lifecycle, and session HTTP
;; live in sibling opencode-hyprland-popup-{sse,server,session}.el files.

;;; Commentary:

;; User-facing entrypoint `opencode-hyprland-popup-prompt':
;;
;;   1. ensure the OpenCode server is running (Phase 2);
;;   2. ensure the global SSE stream is connected (Phase 1);
;;   3. resolve the per-project directory (Phase 3);
;;   4. pick (default: most-recent) or create a session for it;
;;   5. `make-frame' titled \"OpenCode Prompt\" and switch a dedicated
;;      buffer to it; the buffer is editable, runs Evil, and overrides
;;      `:w' buffer-locally to send the buffer text to the session via
;;      `prompt_async'.  (Display is added in Phase 5.)
;;   6. Hyprland floats the new frame imperatively via `hyprctl dispatch
;;      setfloating' (the user may also add a static title-only rule — see
;;      RESEARCH.md §3).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'evil nil t)                        ; soft require — popup needs it

(require 'opencode-hyprland-popup-server)
(require 'opencode-hyprland-popup-session)
(require 'opencode-hyprland-popup-sse)
(require 'opencode-hyprland-popup-display)
(require 'opencode-hyprland-popup-picker)
(require 'opencode-hyprland-popup-permission)
(require 'opencode-hyprland-popup-revert)

(defgroup opencode-hyprland-popup nil
  "OpenCode Hyprland popup frontend."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-popup-")

(defcustom oc-hp-popup-frame-width 90
  "Width (chars) of the popup frame."
  :type 'integer
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-frame-height 28
  "Height (lines) of the popup frame."
  :type 'integer
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-frame-title "OpenCode Prompt"
  "Frame title — Hyprland matches this for the floating rule (RESEARCH §3)."
  :type 'string
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-float-on-hyprland t
  "If non-nil, imperatively run `hyprctl dispatch setfloating' after make-frame."
  :type 'boolean
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-default-model nil
  "Optional model id to pass when creating a new session.  nil = server default."
  :type '(choice (const :tag "Server default" nil) string)
  :group 'opencode-hyprland-popup)

;;; --- Buffer-local popup state ---

(defvar-local oc-hp-popup-session-id nil
  "The OpenCode session id backing this popup buffer.")
(defvar-local oc-hp-popup-directory nil
  "The project directory (x-opencode-directory) backing this popup buffer.")
(defvar-local oc-hp-popup-frame nil
  "The dedicated frame for this popup buffer (if any).")
(defvar-local oc-hp-popup-phase 0
  "Current turn phase: 0 (prompt, pre-:w), 1 (streaming), 2 (answer placed).")

(defvar-local oc-hp-popup-answer-end (make-marker)
  "Marker at the end of the most recent finished answer; the editable prompt
above it is what the user is currently writing.  -- used from Phase 9 onward.")

;;; --- Buffer pool helpers ---

(defun oc-hp-popup--buffer-name (session-id)
  "Return the canonical buffer name for SESSION-ID."
  (format "*opencode-prompt<%s>*" session-id))

(defun oc-hp-popup--live-buffer (session-id)
  "Return the live popup buffer for SESSION-ID, or nil."
  (let ((name (oc-hp-popup--buffer-name session-id)))
    (let ((buf (get-buffer name)))
      (and (buffer-live-p buf) buf))))

(defconst oc-hp-popup--mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q")          #'oc-hp-popup-quit)
    (define-key map (kbd "C-c C-k")    #'oc-hp-popup-quit)
    (define-key map (kbd "C-c C-c")    #'oc-hp-popup-send)
    map)
  "Keymap for `opencode-hyprland-popup-mode'.")

(define-derived-mode opencode-hyprland-popup-mode text-mode
  "OC-Popup"
  "Major mode for the OpenCode Hyprland popup editor.
The buffer is editable; Evil `:w' sends its contents as a prompt to the
OpenCode session backing it (Phase 4).  `q'/`C-c C-k' dismiss the frame;
the buffer is buried (not killed) for instant re-open (Phase 10).
\\{opencode-hyprland-popup-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local window-point-insertion-type t)        ; stream-friendly (Phase 5)
  (when (fboundp 'evil-local-mode) (evil-local-mode 1))
  (oc-hp-popup--install-evil-write-override))

;;; --- Evil `:w' buffer-local override (brief §3.5 / RESEARCH §3c) ---

(defun oc-hp-popup--install-evil-write-override ()
  "Bind `:w'/`:write'/`:wq'/`:x'/`:q' buffer-locally without leaking globally.
The `copy-alist' is CRITICAL: `evil-ex-define-cmd' mutates via `setcdr',
so without the copy the override would leak into every other buffer."
  (when (and (boundp 'evil-ex-commands) (fboundp 'evil-ex-define-cmd))
    (setq-local evil-ex-commands (copy-alist evil-ex-commands))
    (evil-ex-define-cmd "w[rite]"     #'oc-hp-popup-send)
    (evil-ex-define-cmd "wq"          #'oc-hp-popup-send)
    (evil-ex-define-cmd "x[it]"       #'oc-hp-popup-send)
    (evil-ex-define-cmd "q[uit]"      #'oc-hp-popup-quit)))

;;; --- Core: server + SSE glue ---

(defun oc-hp-popup--ensure-backend ()
  "Start the server if needed and connect the global SSE stream.  No-op if up."
  (unless (oc-hp-server-connected-p)
    (oc-hp-server-start))
  (unless (oc-hp-sse-connected-p)
    (oc-hp-sse-connect (oc-hp-server-url "/global/event")
                       (oc-hp-server-auth-headers)))
  (oc-hp-permission-attach)              ; Phase 7: register permission.asked
  (oc-hp-revert-attach))                 ; Phase 8: reverts touched buffers

;;; --- Session selection (default path) ---

(defun oc-hp-popup--pick-session (directory)
  "Return a session id for DIRECTORY: the most recent, or a freshly created one.
This is the Phase-4 default; the prefix-arg session picker is Phase 6."
  (oc-hp-popup--ensure-backend)
  (let* ((sessions (oc-hp-session-list directory))
         (recent (oc-hp-session-most-recent sessions)))
    (or (and recent (plist-get recent :id))
        (let ((created (oc-hp-session-create nil nil directory)))
          (and created (plist-get created :id))))))

;;; --- Send (the :w handler) ---

(defun oc-hp-popup-send (&optional _bang)
  "Send the editable prompt text in this popup as a new turn to OpenCode.
For Phase 4 this just fires `prompt_async' and reports a message; the live
three-phase display is added in Phase 5."
  (interactive "P")
  (let* ((session-id oc-hp-popup-session-id)
         (directory oc-hp-popup-directory)
         (prompt (string-trim-right (oc-hp-popup--current-prompt-text))))
    (unless (and session-id directory)
      (user-error "Popup buffer has no session/directory attached"))
    (when (string-empty-p prompt)
      (user-error "Prompt is empty"))
    (oc-hp-popup--ensure-backend)
    (condition-case err
        (progn
          (oc-hp-display--on-send)         ; open ephemeral region + prep SSE handlers (Phase 5)
          (oc-hp-session-prompt-async session-id prompt directory)
          (message "OpenCode: prompt sent to session %s" session-id))
      (error
       (message "OpenCode: send failed: %s" (error-message-string err))))))

(defun oc-hp-popup--current-prompt-text ()
  "Return the current editable prompt text in the popup buffer.
For Phase 4 + initial `:w' this is the entire buffer; Phase 9 narrows to
the text after the last answer marker for follow-up turns."
  (buffer-substring-no-properties (point-min) (point-max)))

;;; --- Dismiss / quit ---

(defun oc-hp-popup-quit ()
  "Dismiss the popup frame and bury its buffer (don't kill — Phase 10)."
  (interactive)
  (let* ((frame oc-hp-popup-frame)
         (buf (current-buffer)))
    (when (and frame (frame-live-p frame) (> (length (frame-list)) 1))
      (delete-frame frame))
    (when (buffer-live-p buf)
      (bury-buffer buf))
    (message "OpenCode popup: dismissed (session %s)"
             (or oc-hp-popup-session-id "?"))))

;;; --- Frame creation ---

(defun oc-hp-popup--make-frame ()
  "Create (or reuse) the popup frame and switch the current buffer into it."
  (let* ((name oc-hp-popup-frame-title)
         (width oc-hp-popup-frame-width)
         (height oc-hp-popup-frame-height)
         (params `((name . ,name)
                   (minibuffer . t)
                   (width . ,width)
                   (height . ,height)
                   (unsplittable . t)
                   (auto-raise . t)
                   (visibility . t)
                   (tool-bar-lines . 0)
                   (menu-bar-lines . 0)
                   (tab-bar-lines . 0)
                   (vertical-scroll-bars . nil)))
         (frame (make-frame params)))
    (with-current-buffer (window-buffer (frame-root-window frame))
      (setq oc-hp-popup-frame frame))
    (oc-hp-popup--hyprland-float frame)
    frame))

(defun oc-hp-popup--hyprland-float (frame)
  "Imperatively float FRAME on Hyprland if running under XWayland.
Guarded so the no-op path is taken on pgtk / terminal Emacs (per
RESEARCH §2 the build here is `window-system = x')."
  (when (and oc-hp-popup-float-on-hyprland
             (eq window-system 'x)
             (executable-find "hyprctl"))
    (select-frame frame)
    (let ((default-directory (or default-directory "~/")))
      (condition-case err
          (call-process "hyprctl" nil 0 nil "dispatch" "setfloating")
        (error
         (message "opencode popup: hyprctl float failed: %s"
                  (error-message-string err)))))))

;;; --- Entrypoint ---

;;;###autoload
(defun opencode-hyprland-popup-prompt (&optional arg)
  "Open a floating OpenCode popup for the current project.
With prefix ARG, show a session picker for this project; otherwise
continue the most-recent session for the project (or create one)."
  (interactive "P")
  (oc-hp-popup--ensure-backend)
  (let* ((directory (oc-hp-session-find-directory))
         (session-id
          (if arg
              (oc-hp-popup--pick-session-with-picker directory)
            (or (oc-hp-popup--pick-session directory)
                (error "OpenCode: could not pick or create a session")))))
    (unless session-id
      (user-error "OpenCode: no session selected"))
    (let ((buf (oc-hp-popup--ensure-buffer session-id directory)))
      (oc-hp-popup--pop buf))))

(defun oc-hp-popup--pick-session-with-picker (directory)
  "Show the session picker for DIRECTORY; return the chosen session id."
  (let* ((sessions (oc-hp-session-list directory))
         (chosen (oc-hp-picker-select sessions directory)))
    (and chosen (plist-get chosen :id))))

(defun oc-hp-popup--ensure-buffer (session-id directory)
  "Return a live popup buffer for SESSION-ID, creating or resurrecting it."
  (or (oc-hp-popup--live-buffer session-id)
      (let ((buf (get-buffer-create (oc-hp-popup--buffer-name session-id))))
        (with-current-buffer buf
          (unless (derived-mode-p 'opencode-hyprland-popup-mode)
            (opencode-hyprland-popup-mode))
          (setq-local oc-hp-popup-session-id session-id
                      oc-hp-popup-directory directory
                      oc-hp-popup-phase 0)
          (erase-buffer)
          (insert "\n")
          (goto-char (point-min)))
        buf)))

(defun oc-hp-popup--pop (buf)
  "Show BUF in a fresh popup frame, focused."
  (let ((frame (oc-hp-popup--make-frame)))
    (let ((win (frame-root-window frame)))
      (set-window-buffer win buf)
      (select-frame frame)
      (select-window win)
      (with-current-buffer buf
        (goto-char (point-min))
        ;; give buffer its own modeline indicator
        (setq mode-line-format
              '("OC-Prompt  session: " (:eval (or oc-hp-popup-session-id "?"))
                "  dir: " (:eval (or oc-hp-popup-directory "?"))
                "  phase: " (:eval (number-to-string oc-hp-popup-phase))))))
    (with-current-buffer buf
      (setq oc-hp-popup-frame frame))
    frame))

(provide 'opencode-hyprland-popup)
;;; opencode-hyprland-popup.el ends here