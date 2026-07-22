;;; opencode-hyprland-popup-permission.el --- Tool permission prompts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/muradkant/emacs-oc

;;; Commentary:

;; When OpenCode's turn hits a per-tool `ask' permission rule, the
;; server emits `permission.asked' on the SSE stream and pauses the turn
;; until we reply via POST /session/:id/permissions/:permissionID with
;; {"response":"once"|"always"|"reject"}.
;;
;; We queue the ask outside the SSE process filter and offer explicit
;; once, always, and reject choices in the session popup's minibuffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup-sse)
(require 'opencode-hyprland-popup-session)

(defgroup oc-hp-permission nil
  "Permission prompts for opencode-hyprland-popup."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-permission-")

(defcustom oc-hp-permission-default-yes "once"
  "Obsolete affirmative default retained for configuration compatibility."
  :type '(choice (const :tag "Approve once (recommended)" "once")
                 (const :tag "Approve and persist as always" "always"))
  :group 'oc-hp-permission)
(make-obsolete-variable 'oc-hp-permission-default-yes nil "0.2.0")

(defvar oc-hp-permission--handlers-attached nil
  "Non-nil once SSE handlers are registered.")
(defvar oc-hp-permission--queue nil
  "Permission events waiting for user input.")
(defvar oc-hp-permission--prompt-active nil
  "Non-nil while a queued permission is being answered.")
(defvar oc-hp-popup-frame nil
  "Popup frame associated with the current session buffer.")

(defun oc-hp-permission-attach ()
  "Register the `permission.asked' handler on the SSE hook (idempotent)."
  (unless oc-hp-permission--handlers-attached
    (add-hook 'oc-hp-sse-permission-asked-hook #'oc-hp-permission--on-asked)
    (setq oc-hp-permission--handlers-attached t)))

(defun oc-hp-permission-detach ()
  "Unregister the handler (used by tests / unload)."
  (remove-hook 'oc-hp-sse-permission-asked-hook #'oc-hp-permission--on-asked)
  (setq oc-hp-permission--handlers-attached nil))

(defun oc-hp-permission--on-asked (event)
  "Prompt the user about EVENT (a `permission.asked' SSE event).
EVENT's properties carry OpenCode's permission request shape:
  {id, sessionID, permission, patterns, metadata, always, tool?}.
The request is queued for the matching popup frame when present."
  (let* ((props (plist-get event :properties))
         (request-id (plist-get props :id))
         (session-id (plist-get props :sessionID))
         (permission (plist-get props :permission)))
    (if (and session-id request-id permission)
        (progn
          (setq oc-hp-permission--queue
                (append oc-hp-permission--queue (list event)))
          (run-at-time 0 nil #'oc-hp-permission--process-queue))
      (message "OpenCode permission: malformed event; skipping: %S" event))))

(defun oc-hp-permission--process-queue ()
  "Prompt for the next queued permission outside the SSE process filter."
  (unless (or oc-hp-permission--prompt-active
              (null oc-hp-permission--queue))
    (setq oc-hp-permission--prompt-active t)
    (let* ((event (pop oc-hp-permission--queue))
           (props (plist-get event :properties)))
      (unwind-protect
          (oc-hp-permission--raise-ask
           (plist-get props :sessionID) (plist-get props :id)
           (plist-get props :permission) (plist-get props :patterns)
           (plist-get props :tool) (plist-get event :directory))
        (setq oc-hp-permission--prompt-active nil)
        (when oc-hp-permission--queue
          (run-at-time 0 nil #'oc-hp-permission--process-queue))))))

(defun oc-hp-permission--raise-ask (session-id request-id permission
                                               patterns tool directory)
  "Ask once/always/reject for a permission, then reply to OpenCode."
  (let* ((prompt (concat (oc-hp-permission--format permission patterns tool)
                         "[o]nce [a]lways [r]eject "))
         (buf (get-buffer (format "*opencode-prompt<%s>*" session-id)))
         (frame (and (buffer-live-p buf)
                     (buffer-local-value 'oc-hp-popup-frame buf)))
         (read-answer
          (lambda ()
            (condition-case nil
                (pcase (read-char-choice prompt '(?o ?a ?r))
                  (?o "once") (?a "always") (_ "reject"))
              (quit "reject"))))
         (answer (if (frame-live-p frame)
                     (with-selected-frame frame (funcall read-answer))
                   (funcall read-answer))))
    (condition-case err
        (progn
          (oc-hp-session-reply-permission session-id request-id answer directory)
          (message "OpenCode permission: %s -> %s" permission answer))
      (error
       (message "OpenCode permission: reply failed: %s"
                (error-message-string err))))))

(defun oc-hp-permission--format (permission patterns tool)
  "Build the yes/no prompt string for a permission ask.
PERMISSION is the human-readable permission name (e.g. `bash', `edit').
PATTERNS is a list of filesystem/command patterns; TOOL carries call context."
  (let ((pats (if (listp patterns)
                  (mapconcat #'identity patterns " ")
                (prin1-to-string patterns)))
        (tool-msg (if tool
                      (format " [call %s/%s]"
                              (plist-get tool :messageID)
                              (plist-get tool :callID))
                    "")))
    (format "OpenCode wants permission `%s' on `%s'%s — allow? "
            permission
            (if (string-empty-p pats) "(unspecified)" pats)
            tool-msg)))

(provide 'opencode-hyprland-popup-permission)
;;; opencode-hyprland-popup-permission.el ends here
