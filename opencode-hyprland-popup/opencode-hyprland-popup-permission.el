;;; opencode-hyprland-popup-permission.el --- Tool permission prompts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 7 of opencode-hyprland-popup.  When OpenCode's turn hits a
;; per-tool `ask' permission rule (RESEARCH §13.2 / brief §3.8), the
;; server emits `permission.asked' on the SSE stream and pauses the turn
;; until we reply via POST /session/:id/permissions/:permissionID with
;; {"response":"once"|"always"|"reject"}.
;;
;; We surface the ask as a `y-or-n-p' in the popup frame's own minibuffer
;; (the reason `make-frame' was built with `(minibuffer . t)').  Yes ->
;; "once" by default; `C-u` yes -> "always"; No -> "reject".  All
;; OpenCode semantics are respected (we DO NOT modify the server's
;; permission ruleset ourselves — see brief §2 philosophy).

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
  "Response to send when the user answers yes by default.
One of `once' or `always'.  `once' is the conservative default
(approve this one tool call); an `always' default would persist the
rule, which slightly conflicts with brief §2 \"we don't modify
OpenCode's permission rules\" — kept available but not the default."
  :type '(choice (const :tag "Approve once (recommended)" "once")
                 (const :tag "Approve and persist as always" "always"))
  :group 'oc-hp-permission)

(defvar oc-hp-permission--handlers-attached nil
  "Non-nil once SSE handlers are registered.")

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
EVENT's properties carry the request shape from
`packages/schema/src/permission-v1.ts:27' (RESEARCH §13.2):
  {id, sessionID, permission, patterns, metadata, always, tool?}.
Defaults to the popup frame's own minibuffer when present; otherwise
the current frame's."
  (let* ((props (plist-get event :properties))
         (request-id (plist-get props :id))
         (session-id (plist-get props :sessionID))
         (permission (plist-get props :permission))
         (patterns (plist-get props :patterns))
         (tool (plist-get props :tool)))
    (if (and session-id request-id permission)
        (oc-hp-permission--raise-ask session-id request-id permission
                                     patterns tool)
      (message "OpenCode permission: malformed event; skipping: %S" event))))

(defun oc-hp-permission--raise-ask (session-id request-id permission
                                              patterns tool)
  "Pop a yes/no in the popup frame's minibuffer; reply to OpenCode.
TOOL (an alist with :messageID and :callID) is shown for context.
A plain yes answers `once'; a `C-u` yes answers `always'; no answers `reject'."
  (let* ((prompt (oc-hp-permission--format permission patterns tool))
         (answer
          (condition-case _err
              (if (y-or-n-p prompt)
                  (if current-prefix-arg "always" oc-hp-permission-default-yes)
                "reject")
            (quit "reject"))))
    (condition-case err
        (progn
          (oc-hp-session-reply-permission session-id request-id answer)
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