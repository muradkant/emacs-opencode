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
;;   4. create a session if none exist for the project; otherwise ask the
;;      user to choose `*new session*' or an existing project session;
;;   5. `make-frame' titled \"OpenCode Prompt\" and switch a dedicated
;;      buffer to it; the buffer is editable, runs Evil, and overrides
;;      `:w' buffer-locally to send the buffer text to the session via
;;      `prompt_async'.  (Display is added in Phase 5.)
;;   6. Hyprland floats the new frame imperatively via `hyprctl dispatch
;;      setfloating address:<addr>', where <addr> is resolved by matching
;;      the frame's title against `hyprctl clients -j' (the user may also
;;      add a static title-only rule — see RESEARCH.md §3).  Address-
;;      targeting (NOT bare `setfloating', which floats the active window)
;;      avoids the focus race where the *original* Emacs window gets
;;      floated instead of the popup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
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

(defcustom oc-hp-popup-frame-width 68
  "Width (chars) of the popup frame."
  :type 'integer
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-frame-height 19
  "Height (lines) of the popup frame."
  :type 'integer
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-frame-title "OpenCode Prompt"
  "Frame title — Hyprland matches this for the floating rule (RESEARCH §3)."
  :type 'string
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-float-on-hyprland t
  "If non-nil, float the new frame via `hyprctl dispatch setfloating'
address-targeted to that frame's window (resolved by title)."
  :type 'boolean
  :group 'opencode-hyprland-popup)

(defcustom oc-hp-popup-default-model nil
  "Optional model to pass when creating a new session.
Use \"provider/model\", such as \"opencode/mimo-v2.5-free\".  nil means
the server default."
  :type '(choice (const :tag "Server default" nil) string)
  :group 'opencode-hyprland-popup)

(defvar oc-hp-popup--last-frame nil
  "Most recent popup frame, including when it is invisible.")

(defvar oc-hp-popup--last-buffer nil
  "Most recent popup buffer shown in `oc-hp-popup--last-frame'.")

(defvar opencode-hyprland-popup-global-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c o") #'opencode-hyprland-popup-prompt)
    (define-key map (kbd "C-c h") #'opencode-hyprland-popup-toggle-frame)
    map)
  "Global keymap for `opencode-hyprland-popup-global-mode'.")

;;;###autoload
(define-minor-mode opencode-hyprland-popup-global-mode
  "Global keybindings for the OpenCode popup frontend.
`C-c o' opens/selects a project session.  `C-c h' hides the popup frame
when invoked inside it, or restores the same hidden frame from another
Emacs frame."
  :global t
  :keymap opencode-hyprland-popup-global-mode-map
  :group 'opencode-hyprland-popup)

;;; --- Buffer-local popup state ---

(defvar-local oc-hp-popup-session-id nil
  "The OpenCode session id backing this popup buffer.")
(defvar-local oc-hp-popup-directory nil
  "The project directory (x-opencode-directory) backing this popup buffer.")
(defvar-local oc-hp-popup-model nil
  "The selected OpenCode model plist backing future prompts in this buffer.")
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

(defvar opencode-hyprland-popup-mode-map (make-sparse-keymap)
  "Keymap for `opencode-hyprland-popup-mode'.")
(define-key opencode-hyprland-popup-mode-map (kbd "q")       #'oc-hp-popup-quit)
(define-key opencode-hyprland-popup-mode-map (kbd "C-c C-k") #'oc-hp-popup-quit)
(define-key opencode-hyprland-popup-mode-map (kbd "C-c C-c") #'oc-hp-popup-send)
(define-key opencode-hyprland-popup-mode-map (kbd "C-c h")
            #'opencode-hyprland-popup-toggle-frame)

(defconst oc-hp-popup--mode-map opencode-hyprland-popup-mode-map
  "Compatibility alias for the popup mode keymap.")

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

;;; --- Session selection ---

(defun oc-hp-popup--new-session (directory model)
  "Create a fresh OpenCode session in DIRECTORY with MODEL and return its id."
  (let ((created (oc-hp-session-create nil nil directory model)))
    (and created (plist-get created :id))))

(defun oc-hp-popup--choose-session (directory &optional force-new)
  "Return a session selection for DIRECTORY.
The result is either an existing session plist or `(:new t)'.  With
FORCE-NEW, request a fresh session immediately.  Otherwise, request a
fresh session when none exist for DIRECTORY; when sessions do exist, ask
the user to choose `*new session*' or one of the existing project sessions."
  (oc-hp-popup--ensure-backend)
  (if force-new
      (list :new t)
    (let ((sessions (oc-hp-session-list directory)))
      (if (null sessions)
          (list :new t)
        (oc-hp-picker-select sessions directory)))))

(defun oc-hp-popup--choose-model (directory &optional default-model)
  "Return a configured OpenCode model plist for DIRECTORY."
  (let ((models (oc-hp-session-models directory)))
    (unless models
      (user-error "OpenCode: no configured models found"))
    (or (oc-hp-picker-select-model models
                                   (or default-model
                                       oc-hp-popup-default-model))
        (user-error "OpenCode: no model selected"))))

(defun oc-hp-popup--session-id-for-selection (directory selection model)
  "Return a session id for SELECTION, creating a new session with MODEL."
  (cond
   ((plist-get selection :new)
    (or (oc-hp-popup--new-session directory model)
        (error "OpenCode: could not create session")))
   ((plist-get selection :id)
    (plist-get selection :id))
   (t nil)))

(defun oc-hp-popup--selection-default-model (selection directory)
  "Return the best default model for SELECTION in DIRECTORY, or nil."
  (or oc-hp-popup-default-model
      (and (plist-get selection :id)
           (oc-hp-popup--session-last-model (plist-get selection :id)
                                            directory))))

(defun oc-hp-popup--session-last-model (session-id directory)
  "Return the most recent model used by SESSION-ID, or nil."
  (condition-case _err
      (cl-block nil
        (dolist (message (reverse (oc-hp-session-messages session-id directory)))
          (let* ((info (oc-hp-popup--message-info message))
                 (model (or (plist-get info :model)
                            (and (plist-get info :providerID)
                                 (list :providerID (plist-get info :providerID)
                                       :modelID (plist-get info :modelID))))))
            (when (and (plist-get model :providerID)
                       (or (plist-get model :modelID)
                           (plist-get model :id)))
              (cl-return model)))))
    (error nil)))

;;; --- Send (the :w handler) ---

(defun oc-hp-popup-send (&optional _bang)
  "Send the editable prompt text in this popup as a new turn to OpenCode.
First turn (phase 0): the whole buffer is the prompt.  Follow-up turn
(phase 2): ONLY prompt2 — the text typed below the last finished answer —
is sent; the buffer is then wiped to [prompt2] before the Phase 5 divider
opens, so the new turn shows [prompt2] then [answer2] (brief §1.6).
Phase 1 (a turn still streaming) is refused to protect the display FSM."
  (interactive "P")
  (when (eq oc-hp-popup-phase 1)
    (user-error "OpenCode: a turn is still in progress; wait for it to finish"))
  (let* ((session-id oc-hp-popup-session-id)
         (directory oc-hp-popup-directory)
         (follow-up-p (eq oc-hp-popup-phase 2))
         (prompt (string-trim-right (oc-hp-popup--current-prompt-text))))
    (unless (and session-id directory)
      (user-error "Popup buffer has no session/directory attached"))
    (when (string-empty-p prompt)
      (user-error "Prompt is empty"))
    (oc-hp-popup--ensure-backend)
    (when follow-up-p
      ;; Phase 9: wipe to [prompt2] so Phase 5's divider opens above only
      ;; the new prompt (not [answer1 + prompt2]).  erase-buffer repoints
      ;; every marker to point-min; on-send re-creates the eph markers and
      ;; finalize re-anchors oc-hp-popup-answer-end for this turn.
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert prompt)
        (setq-local oc-hp-popup-phase 0)))
    (condition-case err
        (progn
          (oc-hp-display--on-send)         ; open ephemeral region + prep SSE handlers (Phase 5)
          (oc-hp-session-prompt-async session-id prompt directory
                                      oc-hp-popup-model)
          (message "OpenCode: prompt sent to session %s%s"
                   session-id (if follow-up-p " (follow-up)" "")))
      (error
       (message "OpenCode: send failed: %s" (error-message-string err))))))

(defun oc-hp-popup--current-prompt-text ()
  "Return the current editable prompt text in the popup buffer.
First turn (phase 0): the whole buffer is the prompt.
Follow-up turn (phase 2): ONLY the text typed after the last finished
answer — i.e. buffer[oc-hp-popup-answer-end .. point-max] — so the
prior answer is never re-sent (OpenCode holds prompt1+answer1 server-side).
Trimmed on both ends so a leading/trailing blank the user left is ignored."
  (if (eq oc-hp-popup-phase 2)
      (let* ((end (or (marker-position oc-hp-popup-answer-end) (point-min)))
             (start (min end (point-max))))
        (string-trim
         (buffer-substring-no-properties start (point-max))))
    (buffer-substring-no-properties (point-min) (point-max))))

;;; --- Dismiss / quit ---

(defun oc-hp-popup--frame-buffer (frame)
  "Return FRAME's root-window buffer, or nil."
  (when (frame-live-p frame)
    (let ((window (frame-root-window frame)))
      (and (window-live-p window)
           (window-buffer window)))))

(defun oc-hp-popup--popup-frame-p (frame)
  "Return non-nil when FRAME is an OpenCode popup frame."
  (and (frame-live-p frame)
       (or (eq frame oc-hp-popup--last-frame)
           (equal (frame-parameter frame 'name) oc-hp-popup-frame-title)
           (let ((buf (oc-hp-popup--frame-buffer frame)))
             (and (buffer-live-p buf)
                  (with-current-buffer buf
                    (derived-mode-p 'opencode-hyprland-popup-mode)))))))

(defun oc-hp-popup--remember-frame (frame buffer)
  "Remember FRAME and BUFFER as the active popup pair."
  (when (frame-live-p frame)
    (setq oc-hp-popup--last-frame frame)
    (when (buffer-live-p buffer)
      (setq oc-hp-popup--last-buffer buffer)
      (with-current-buffer buffer
        (setq-local oc-hp-popup-frame frame)))))

(defun oc-hp-popup--known-frame ()
  "Return the remembered popup frame, or discover a live one."
  (or (and (frame-live-p oc-hp-popup--last-frame)
           oc-hp-popup--last-frame)
      (setq oc-hp-popup--last-frame
            (cl-find-if #'oc-hp-popup--popup-frame-p (frame-list)))))

(defun oc-hp-popup--visible-graphic-frame-count ()
  "Return the number of visible graphical Emacs frames."
  (cl-count-if (lambda (frame)
                 (and (frame-live-p frame)
                      (display-graphic-p frame)
                      (frame-visible-p frame)))
               (frame-list)))

(defun oc-hp-popup--hide-frame (frame)
  "Make FRAME invisible without deleting it."
  (let ((buf (oc-hp-popup--frame-buffer frame)))
    (oc-hp-popup--remember-frame frame buf)
    (if (<= (oc-hp-popup--visible-graphic-frame-count) 1)
        (user-error "OpenCode popup: cannot hide the only visible graphical Emacs frame")
      (make-frame-invisible frame t)
      (when (buffer-live-p buf)
        (bury-buffer buf))
      (message "OpenCode popup: hidden"))))

(defun oc-hp-popup--show-frame (frame)
  "Make FRAME visible and focused without recreating it."
  (let ((buf (or (oc-hp-popup--frame-buffer frame)
                 oc-hp-popup--last-buffer)))
    (make-frame-visible frame)
    (oc-hp-popup--resize-frame frame)
    (when (buffer-live-p buf)
      (set-window-buffer (frame-root-window frame) buf)
      (oc-hp-popup--remember-frame frame buf))
    (oc-hp-popup--hyprland-float frame)
    (raise-frame frame)
    (select-frame-set-input-focus frame)
    (message "OpenCode popup: shown")))

;;;###autoload
(defun opencode-hyprland-popup-toggle-frame ()
  "Hide the popup frame, or restore the last hidden popup frame.
When invoked from the popup frame, the frame is made invisible rather
than deleted.  When invoked from any other Emacs frame, the same live
frame is made visible again, preserving its buffer, point, window state,
and OpenCode session."
  (interactive)
  (let ((selected (selected-frame)))
    (if (oc-hp-popup--popup-frame-p selected)
        (oc-hp-popup--hide-frame selected)
      (let ((frame (oc-hp-popup--known-frame)))
        (unless (frame-live-p frame)
          (user-error "OpenCode popup: no hidden popup frame to restore"))
        (oc-hp-popup--show-frame frame)))))

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
    (oc-hp-popup--resize-frame frame)
    (run-with-timer 0.15 nil #'oc-hp-popup--resize-frame frame)
    frame))

(defun oc-hp-popup--resize-frame (frame)
  "Apply the configured popup size to FRAME when it is still live."
  (when (frame-live-p frame)
    (set-frame-size frame
                    oc-hp-popup-frame-width
                    oc-hp-popup-frame-height)))

(defun oc-hp-popup--hyprland-float (frame)
  "Imperatively float FRAME on Hyprland if running under XWayland.
Guarded so the no-op path is taken on pgtk / terminal Emacs (per
RESEARCH §2 the build here is `window-system = x').

We float FRAME by its specific Hyprland window address — resolved by
matching the frame's title against `hyprctl clients -j' — NOT by the
\"active\" window.  Bare `hyprctl dispatch setfloating' (the old code)
operates on whatever Hyprland considers active at dispatch time; under
XWayland the new frame's title/focus can lag make-frame by a few ms,
so the dispatch would race and float the *original* Emacs window
instead of the popup.  Address-targeting is deterministic and
focus-independent, so the wrong window can never be floated.

Emacs's `outer-window-id' frame parameter is the X11 window id, which
is a *different* namespace from Hyprland's internal address —
`hyprctl clients' exposes no X11-id field, only address/pid/class/title
— so title resolution is the correct (and robust) bridge."
  (when (and oc-hp-popup-float-on-hyprland
             (eq window-system 'x)
             (executable-find "hyprctl"))
    (select-frame frame)
    (let ((default-directory (or default-directory "~/"))
          (title oc-hp-popup-frame-title))
      (condition-case err
          (let ((address (oc-hp-popup--hyprland-address-for-title title)))
            (cond
             (address
              (call-process "hyprctl" nil 0 nil
                            "dispatch" "setfloating"
                            (concat "address:" address)))
             (t
              ;; Title not yet seen by the compositor (XWayland title lag).
              ;; Bail out rather than fall back to the active window — that
              ;; fallback is exactly the focus race this function exists to
              ;; avoid.  The user's static title-only windowrule still floats it.
              (message "opencode popup: hyprctl float skipped: no window \
matched title %S (it may appear shortly)" title))))
        (error
         (message "opencode popup: hyprctl float failed: %s"
                  (error-message-string err)))))))

(defun oc-hp-popup--hyprland-address-for-title (title)
  "Return the Hyprland window address whose title is TITLE, or nil.
Reads `hyprctl clients -j' and matches the `title' field exactly.
Returns nil if no client matches (e.g. the new frame's title hasn't
propagated yet) or if the compositor output is unparseable — both are
handled gracefully by the caller rather than falling back to the
focus-race-prone active-window dispatch."
  (condition-case err
      (with-temp-buffer
        (when (zerop (call-process "hyprctl" nil t nil "clients" "-j"))
          (goto-char (point-min))
          (let ((clients (oc-hp-popup--json-parse-plist-array
                          (buffer-string))))
            (and (listp clients)
                 (cl-some (lambda (c)
                            (and (equal (plist-get c :title) title)
                                 (plist-get c :address)))
                          clients)))))
    (error
     (message "opencode popup: hyprctl clients parse failed: %s"
              (error-message-string err))
     nil)))

(defun oc-hp-popup--json-parse-plist-array (string)
  "Parse STRING (the JSON from `hyprctl clients -j') into a list of plists.
Mirrors `oc-hp-session--json-parse' (json-object-type plist,
json-array-type list, json-key-type keyword); returns the raw string
on parse failure so the caller's `listp' guard rejects it cleanly."
  (let ((json-object-type 'plist)
        (json-array-type  'list)
        (json-key-type    'keyword)
        (json-null        nil))
    (condition-case _err
        (json-read-from-string string)
      (error string))))

;;; --- Entrypoint ---

;;;###autoload
(defun opencode-hyprland-popup-prompt (&optional arg)
  "Open a floating OpenCode popup for the current project.
If the current project has no sessions, create one immediately.  Otherwise
ask whether to create a new session or continue an existing project session.
With prefix ARG, create a new session immediately."
  (interactive "P")
  (oc-hp-popup--ensure-backend)
  (let* ((directory (oc-hp-session-find-directory))
         (selection (or (oc-hp-popup--choose-session directory arg)
                        (error "OpenCode: could not pick or create a session")))
         (model (oc-hp-popup--choose-model
                 directory
                 (oc-hp-popup--selection-default-model selection directory)))
         (session-id (or (oc-hp-popup--session-id-for-selection
                          directory selection model)
                         (error "OpenCode: could not pick or create a session"))))
    (unless session-id
      (user-error "OpenCode: no session selected"))
    (let ((buf (oc-hp-popup--ensure-buffer session-id directory)))
      (with-current-buffer buf
        (setq-local oc-hp-popup-model model))
      (oc-hp-popup--pop buf))))

(defun oc-hp-popup--ensure-buffer (session-id directory)
  "Return a live popup buffer for SESSION-ID, creating or resurrecting it."
  (or (oc-hp-popup--live-buffer session-id)
      (let ((buf (get-buffer-create (oc-hp-popup--buffer-name session-id))))
        (with-current-buffer buf
          (unless (derived-mode-p 'opencode-hyprland-popup-mode)
            (opencode-hyprland-popup-mode))
          (setq-local oc-hp-popup-session-id session-id
                      oc-hp-popup-directory directory
                      oc-hp-popup-model nil
                      oc-hp-popup-phase 0)
          (erase-buffer)
          (unless (and (ignore-errors (oc-hp-server-connected-p))
                       (oc-hp-popup--hydrate-buffer session-id directory))
            (insert "\n"))
          (goto-char (point-min)))
        buf)))

(defun oc-hp-popup--hydrate-buffer (session-id directory)
  "Populate the current popup buffer from SESSION-ID history.
Returns non-nil when history was rendered.  Only the latest useful turn is
shown: the last user prompt plus the last assistant response.  If the
session has a user prompt but no assistant response yet, render that prompt
as an editable phase-0 prompt."
  (condition-case err
      (let* ((messages (oc-hp-session-messages session-id directory))
             (turn (oc-hp-popup--last-turn messages))
             (prompt (plist-get turn :prompt))
             (answer (plist-get turn :answer)))
        (cond
         ((and prompt answer)
          (let ((inhibit-read-only t))
            (insert prompt)
            (unless (bolp) (insert "\n"))
            (insert "\n")
            (insert (propertize oc-hp-display-divider
                                'face 'oc-hp-display-divider-face
                                'read-only t))
            (insert "\n")
            (insert (propertize answer 'face 'oc-hp-display-answer-face))
            (insert "\n\n")
            (setq-local oc-hp-popup-phase 2
                        oc-hp-display--finalized t
                        oc-hp-popup-answer-end (copy-marker (point) nil)))
          t)
         (prompt
          (let ((inhibit-read-only t))
            (insert prompt)
            (setq-local oc-hp-popup-phase 0))
          t)
         (t nil)))
    (error
     (message "OpenCode popup: could not hydrate session %s: %s"
              session-id (error-message-string err))
     nil)))

(defun oc-hp-popup--last-turn (messages)
  "Return a plist with the latest prompt/answer extracted from MESSAGES."
  (let* ((assistant (oc-hp-popup--last-message-with-role messages "assistant"))
         (answer (and assistant (oc-hp-popup--message-text assistant)))
         (parent-id (and assistant
                         (plist-get (oc-hp-popup--message-info assistant)
                                    :parentID)))
         (user (or (and parent-id
                        (oc-hp-popup--message-by-id messages parent-id))
                   (and assistant
                        (oc-hp-popup--previous-message-with-role
                         messages assistant "user"))
                   (oc-hp-popup--last-message-with-role messages "user")))
         (prompt (and user
                      (oc-hp-popup--normalize-user-prompt
                       (oc-hp-popup--message-text user)
                       messages user))))
    (cond
     ((and prompt answer)
      (list :prompt prompt :answer answer))
     (prompt
      (list :prompt prompt))
     (answer
      (list :answer answer)))))

(defun oc-hp-popup--message-info (message)
  "Return MESSAGE's info plist, accepting raw info plists too."
  (or (plist-get message :info) message))

(defun oc-hp-popup--message-role (message)
  "Return MESSAGE's role string."
  (plist-get (oc-hp-popup--message-info message) :role))

(defun oc-hp-popup--message-id (message)
  "Return MESSAGE's id string."
  (plist-get (oc-hp-popup--message-info message) :id))

(defun oc-hp-popup--message-text (message)
  "Return MESSAGE text by joining its text parts."
  (let ((texts nil))
    (dolist (part (plist-get message :parts))
      (when (and (equal (plist-get part :type) "text")
                 (plist-get part :text))
        (push (plist-get part :text) texts)))
    (let ((text (string-trim (mapconcat #'identity (nreverse texts) "\n\n"))))
      (unless (string-empty-p text)
        text))))

(defun oc-hp-popup--normalize-user-prompt (prompt messages user)
  "Return PROMPT as it should appear in the popup.
Old follow-up sends could accidentally store the whole visible transcript
as the next user message.  When that legacy shape is detectable, trim it
back to only the trailing prompt the user actually typed."
  (let* ((previous-assistant
          (and prompt
               (oc-hp-popup--previous-message-with-role messages user "assistant")))
         (previous-answer
          (and previous-assistant
               (oc-hp-popup--message-text previous-assistant)))
         (after-answer
          (and previous-answer
               (oc-hp-popup--substring-after-last prompt previous-answer)))
         (divider-p
          (and prompt
               (string-match-p (regexp-quote oc-hp-display-divider) prompt)))
         (legacy-after-answer-p
          (and after-answer
               (string-match-p "\\`[ \t\n\r]+\\S-" after-answer)))
         (normalized
          (cond
           (legacy-after-answer-p after-answer)
           (divider-p (oc-hp-popup--prompt-after-last-divider prompt)))))
    (if (and normalized (not (string-empty-p (string-trim normalized))))
        (string-trim normalized)
      prompt)))

(defun oc-hp-popup--substring-after-last (string needle)
  "Return the substring after NEEDLE's last occurrence in STRING."
  (when (and string needle (not (string-empty-p needle)))
    (let ((start 0)
          end)
      (while (string-match (regexp-quote needle) string start)
        (setq end (match-end 0)
              start (match-end 0)))
      (and end (substring string end)))))

(defun oc-hp-popup--prompt-after-last-divider (prompt)
  "Best-effort fallback for a PROMPT containing a historical transcript."
  (let ((after-divider (oc-hp-popup--substring-after-last
                        prompt oc-hp-display-divider)))
    (when after-divider
      (car (last (split-string after-divider "\n[ \t]*\n+" t))))))

(defun oc-hp-popup--last-message-with-role (messages role)
  "Return the last message in MESSAGES whose role is ROLE."
  (cl-find-if (lambda (message)
                (equal (oc-hp-popup--message-role message) role))
              (reverse messages)))

(defun oc-hp-popup--message-by-id (messages id)
  "Return the message in MESSAGES whose id is ID."
  (cl-find-if (lambda (message)
                (equal (oc-hp-popup--message-id message) id))
              messages))

(defun oc-hp-popup--previous-message-with-role (messages marker role)
  "Return the last ROLE message before MARKER in MESSAGES."
  (let ((seen nil)
        (found nil))
    (dolist (message messages)
      (cond
       ((eq message marker)
        (setq seen t))
       ((and (not seen)
             (equal (oc-hp-popup--message-role message) role))
        (setq found message))))
    found))

(defun oc-hp-popup--pop (buf)
  "Show BUF in a popup frame, focused.
Reuse BUF's existing live frame when present, including an invisible one."
  (let ((frame (or (with-current-buffer buf
                     (and (frame-live-p oc-hp-popup-frame)
                          oc-hp-popup-frame))
                   (oc-hp-popup--make-frame))))
    (let ((win (frame-root-window frame)))
      (make-frame-visible frame)
      (set-window-buffer win buf)
      (select-frame frame)
      (select-window win)
      (with-current-buffer buf
        (goto-char (point-min))
        ;; give buffer its own modeline indicator
        (setq mode-line-format
              '("OC-Prompt  session: " (:eval (or oc-hp-popup-session-id "?"))
                "  dir: " (:eval (or oc-hp-popup-directory "?"))
                "  model: " (:eval (if oc-hp-popup-model
                                       (oc-hp-session-model-key
                                        oc-hp-popup-model)
                                     "?"))
                "  phase: " (:eval (number-to-string oc-hp-popup-phase))))))
    (oc-hp-popup--remember-frame frame buf)
    (oc-hp-popup--resize-frame frame)
    (oc-hp-popup--hyprland-float frame)
    (raise-frame frame)
    (select-frame-set-input-focus frame)
    frame))

(provide 'opencode-hyprland-popup)
;;; opencode-hyprland-popup.el ends here
