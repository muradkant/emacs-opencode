;;; opencode-hyprland-popup-display.el --- Three-phase streaming display  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/muradkant/emacs-oc

;;; Commentary:

;; Three-stage display for the `message.part.*' event stream emitted by
;; OpenCode 1.17.18.
;;
;; Buffer layout during a turn:
;;
;;   <prompt>               (Phase 0 — user-written, editable)
;;   ─── assistant ───       (ephemeral divider marker)
;;   <ephemeral>            (Phase 1 — thinking/tools/live text delta)
;;   <answer>               (Phase 2 — final answer text, replaces ephemeral)
;;
;; Per-turn machinery:
;;   * `oc-hp-display--on-send' is called by `oc-hp-popup-send' before
;;     `prompt_async' fires: inserts the divider + opens the ephemeral
;;     region, resets per-turn state, attaches SSE handlers (once).
;;   * `message.part.updated'/`.delta' events mutate the ephemeral region.
;;   * On `session.status' = `idle', the ephemeral region is replaced with
;;     the accumulated final answer text; phase becomes 2.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'map)
(require 'opencode-hyprland-popup-sse)
(require 'opencode-hyprland-popup-session)

(defgroup oc-hp-display nil
  "Three-phase streaming display for opencode-hyprland-popup."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-display-")

(defcustom oc-hp-display-divider "─── assistant ───"
  "Text used as the visual divider between prompt and ephemeral region."
  :type 'string
  :group 'oc-hp-display)

(defface oc-hp-display-ephemeral-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for streaming ephemeral content (thinking + tool names + live deltas)."
  :group 'oc-hp-display)

(defface oc-hp-display-divider-face
  '((t :inherit font-lock-comment-face))
  "Face for the divider line."
  :group 'oc-hp-display)

(defface oc-hp-display-tool-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for tool-call summaries ([tool: name args]) in ephemeral region."
  :group 'oc-hp-display)

(defface oc-hp-display-answer-face
  '((t :inherit default))
  "Face for the final answer region."
  :group 'oc-hp-display)

(defvar-local oc-hp-display--eph-start nil
  "Marker at the divider line, start of the ephemeral region.")
(defvar-local oc-hp-display--eph-end nil
  "Marker at end of the ephemeral region (advances as we insert).")
(defvar-local oc-hp-display--parts nil
  "Complete OpenCode parts for this turn, in first-seen order.")
(defvar-local oc-hp-display--text-by-part nil
  "Compatibility view of text parts used by older callers and tests.")
(defvar-local oc-hp-display--finalized nil
  "Non-nil once the turn has finalized, preventing double finalization.")
(defvar-local oc-hp-display--error nil
  "Human-readable error for the current turn, or nil.")

(defvar oc-hp-display--handlers-attached nil
  "Non-nil once we've added the SSE event handlers globally.")

(defvar oc-hp-display--message-role-by-id (make-hash-table :test 'equal)
  "Cache from OpenCode message id to role string.")

;;; --- Buffer guard ---

(defvar oc-hp-popup-phase 0
  "Defined in opencode-hyprland-popup.el; declared here for free-use warnings.")
(defvar oc-hp-popup-directory nil
  "Defined in opencode-hyprland-popup.el; declared here for free-use warnings.")
(defvar oc-hp-popup-session-id nil
  "Defined in opencode-hyprland-popup.el; declared here for reconciliation.")

(defun oc-hp-display--buffer ()
  "Return the popup buffer for the active display turn, or nil.
We rely on the popup buffer being current at send time; the SSE
handlers recover it via `oc-hp-display--live-popup-buffer'."
  (cl-block nil
    (let ((buffers (buffer-list)))
      (dolist (buf buffers)
        (with-current-buffer buf
          (when (and (derived-mode-p 'opencode-hyprland-popup-mode)
                     (eq oc-hp-popup-phase 1))
            (cl-return buf)))))))

(defun oc-hp-display--live-popup-buffer (session-id)
  "Return the live popup buffer for SESSION-ID whose phase is 1, else nil."
  (cl-block nil
    (let ((name (oc-hp-display--buffer-name session-id)))
      (let ((buf (get-buffer name)))
        (when (and (buffer-live-p buf)
                   (with-current-buffer buf
                     (and (eq oc-hp-popup-phase 1)
                          (not oc-hp-display--finalized))))
          (cl-return buf))))))

(defun oc-hp-display--buffer-name (session-id)
  "Canonical popup buffer name for SESSION-ID (lives in the main file too)."
  (format "*opencode-prompt<%s>*" session-id))

;;; --- Per-turn setup (called by oc-hp-popup-send before HTTP) ---

(defun oc-hp-display--on-send ()
  "Prepare the current buffer for streaming: insert divider, reset state.
Called from `oc-hp-popup-send' (Phase 4) right before the prompt_async POST;
the user's prompt text MUST already be in the buffer above point."
  ;; Strip any trailing whitespace/newlines that might confuse phase detection.
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (unless (looking-back "\n\n" (- (point) 4)) (insert "\n"))
    (insert "\n")
    ;; Save divider marker at the start of the ephemeral region
    (let ((divider-start (point)))
      (insert (propertize oc-hp-display-divider
                          'face 'oc-hp-display-divider-face
                          'read-only t))
      (insert "\n")
      (setq-local oc-hp-display--eph-start (copy-marker divider-start t))
      (set-marker-insertion-type oc-hp-display--eph-start t))
    ;; Ephemeral end marker starts just after divider; advances with inserts
    (setq-local oc-hp-display--eph-end (copy-marker (point) t))
    (setq-local oc-hp-display--parts nil
                oc-hp-display--text-by-part nil
                oc-hp-display--finalized nil
                oc-hp-display--error nil)
    (setq-local oc-hp-popup-phase 1)
    (setq-local buffer-read-only t)
    ;; Attach SSE handlers once, globally (popup buffers switch over time)
    (oc-hp-display--attach-handlers)
    (oc-hp-display--render-ephemeral)))

;;; --- SSE handlers (attached once per Emacs session) ---

(defun oc-hp-display--attach-handlers ()
  "Attach the v1 event handlers to the SSE hook (idempotent, global)."
  (unless oc-hp-display--handlers-attached
    (add-hook 'oc-hp-sse-message-updated-hook #'oc-hp-display--handle-message-updated)
    (add-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-display--handle-part-updated)
    (add-hook 'oc-hp-sse-message-part-delta-hook #'oc-hp-display--handle-part-delta)
    (add-hook 'oc-hp-sse-session-status-hook #'oc-hp-display--handle-status)
    (add-hook 'oc-hp-sse-session-error-hook #'oc-hp-display--handle-error)
    (add-hook 'oc-hp-sse-server-connected-hook #'oc-hp-display--reconcile)
    (setq oc-hp-display--handlers-attached t)))

(defun oc-hp-display--detach-handlers ()
  "Detach (for cleanup / test)."
  (remove-hook 'oc-hp-sse-message-updated-hook #'oc-hp-display--handle-message-updated)
  (remove-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-display--handle-part-updated)
  (remove-hook 'oc-hp-sse-message-part-delta-hook #'oc-hp-display--handle-part-delta)
  (remove-hook 'oc-hp-sse-session-status-hook #'oc-hp-display--handle-status)
  (remove-hook 'oc-hp-sse-session-error-hook #'oc-hp-display--handle-error)
  (remove-hook 'oc-hp-sse-server-connected-hook #'oc-hp-display--reconcile)
  (setq oc-hp-display--handlers-attached nil))

(defun oc-hp-display--handle-message-updated (event)
  "Cache message role metadata from a `message.updated' EVENT."
  (let* ((props (plist-get event :properties))
         (message (or (plist-get props :message)
                      (plist-get props :info)
                      props)))
    (oc-hp-display--cache-message-role message)))

(defun oc-hp-display--cache-message-role (message)
  "Record MESSAGE's role by id when both fields are present."
  (let ((id (or (plist-get message :id)
                (plist-get message :messageID)))
        (role (plist-get message :role)))
    (when (and id role)
      (puthash id role oc-hp-display--message-role-by-id))))

(defun oc-hp-display--handle-part-updated (event)
  "Record the part structure declared by `message.part.updated' EVENT."
  (oc-hp-display--in-popup-for event
    (lambda (buf)
      (with-current-buffer buf
        (oc-hp-display--on-part-updated event)))))

(defun oc-hp-display--handle-part-delta (event)
  "Append the delta declared by `message.part.delta' EVENT, if for a text part."
  (when (equal (plist-get event :type) "message.part.delta")
    (oc-hp-display--in-popup-for event
      (lambda (buf)
        (with-current-buffer buf
          (oc-hp-display--on-part-delta event))))))

(defun oc-hp-display--in-popup-for (event fn)
  "Locate the popup buffer for EVENT's session and call FN with it."
  (let* ((props (plist-get event :properties))
         (sid (or (plist-get props :sessionID)
                  (plist-get (plist-get props :part) :sessionID))))
    (when-let ((buf (oc-hp-display--live-popup-buffer sid)))
      (funcall fn buf))))

;;; --- Event handlers proper ---

(defun oc-hp-display--on-part-updated (event)
  "Dispatch on the part type inside EVENT's `:part' object."
  (when (oc-hp-display--assistant-event-p event)
    (let* ((props (plist-get event :properties))
           (part (plist-get props :part))
           (type (plist-get part :type))
           (pid  (plist-get part :id)))
      (pcase type
        ("step-start"  nil)            ; boundary; rendering handled by tool/text themselves
        ("step-finish" nil)            ; finalizer; we render answer cumulatively (cost footer optional)
        ((or "text" "reasoning" "tool")
         (oc-hp-display--put-part pid part)
         (oc-hp-display--render-ephemeral))
        (_ nil)))))

(defun oc-hp-display--on-part-delta (event)
  "Append a streaming text delta."
  (let* ((props (plist-get event :properties))
         (pid (plist-get props :partID))
         (field (plist-get props :field))
         (delta (plist-get props :delta))
         (part (oc-hp-display--part pid)))
    (when (and (oc-hp-display--assistant-event-p event)
               pid delta
               (not (string-empty-p delta))
               part
               (member field '(nil "text")))
      (plist-put part :text (concat (or (plist-get part :text) "") delta))
      (oc-hp-display--sync-text-view)
      (oc-hp-display--render-ephemeral))))

(defun oc-hp-display--part (pid)
  "Return the current part whose ID equals PID."
  (cl-find pid oc-hp-display--parts
           :key (lambda (part) (plist-get part :id)) :test #'equal))

(defun oc-hp-display--put-part (pid part)
  "Insert or replace PART identified by PID without changing its order."
  (let ((existing (oc-hp-display--part pid)))
    (if existing
        (setcar (memq existing oc-hp-display--parts) part)
      (setq-local oc-hp-display--parts
                  (append oc-hp-display--parts (list part)))))
  (oc-hp-display--sync-text-view))

(defun oc-hp-display--sync-text-view ()
  "Refresh the compatibility text-part alist from current part state."
  (setq-local oc-hp-display--text-by-part
              (cl-loop for part in oc-hp-display--parts
                       when (equal (plist-get part :type) "text")
                       collect (cons (plist-get part :id)
                                     (or (plist-get part :text) "")))))

(defun oc-hp-display--assistant-event-p (event)
  "Return non-nil when EVENT belongs to an assistant message.
OpenCode streams the submitted user prompt as a `text' part too.  Rendering
that part under the assistant divider makes the popup show a fake answer."
  (let* ((props (plist-get event :properties))
         (part (plist-get props :part))
         (message-id (or (plist-get props :messageID)
                         (plist-get part :messageID)))
         (session-id (or (plist-get props :sessionID)
                         (plist-get part :sessionID))))
    (if (not message-id)
        t
      (equal (oc-hp-display--message-role session-id message-id
                                          oc-hp-popup-directory)
             "assistant"))))

(defun oc-hp-display--message-role (session-id message-id directory)
  "Return the cached role for MESSAGE-ID, fetching SESSION-ID history if needed."
  (or (gethash message-id oc-hp-display--message-role-by-id)
      (when session-id
        (condition-case _err
            (progn
              (dolist (message (oc-hp-session-messages session-id directory))
                (oc-hp-display--cache-message-role
                 (or (plist-get message :info) message)))
              (gethash message-id oc-hp-display--message-role-by-id))
          (error nil)))))

(defun oc-hp-display--handle-status (event)
  "Finalize the turn when `session.status' reports `idle'."
  (let* ((props (plist-get event :properties))
         (status (plist-get props :status))
         (type (and (listp status) (plist-get status :type))))
    (when (equal type "idle")
      (oc-hp-display--in-popup-for event
        (lambda (buf) (oc-hp-display--finalize buf))))))

(defun oc-hp-display--handle-error (event)
  "Make a `session.error' EVENT visible in its session buffer."
  (oc-hp-display--in-popup-for
   event
   (lambda (buf)
     (with-current-buffer buf
       (let* ((props (plist-get event :properties))
              (err (plist-get props :error))
              (message (or (and (listp err) (plist-get err :message))
                           (and (listp err)
                                (plist-get (plist-get err :data) :message))
                           (and (stringp err) err)
                           "OpenCode reported an unknown session error")))
         (setq-local oc-hp-display--error message)
         (oc-hp-display--render-ephemeral))))))

(defun oc-hp-display--reconcile (_event)
  "Reconcile streaming popup buffers after an SSE connection is established."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (with-current-buffer buf
                 (and (derived-mode-p 'opencode-hyprland-popup-mode)
                      (eq oc-hp-popup-phase 1))))
      (with-current-buffer buf
        (condition-case err
            (let* ((statuses (oc-hp-session-statuses oc-hp-popup-directory))
                   (status (plist-get statuses
                                      (intern (concat ":" oc-hp-popup-session-id))))
                   (type (plist-get status :type)))
              (unless (member type '("busy" "retry"))
                (let* ((messages (oc-hp-session-messages
                                  oc-hp-popup-session-id oc-hp-popup-directory))
                       (assistant
                        (cl-find-if
                         (lambda (message)
                           (equal (plist-get (or (plist-get message :info)
                                                message)
                                             :role)
                                  "assistant"))
                         (reverse messages))))
                  (when assistant
                    (setq-local oc-hp-display--parts
                                (cl-remove-if-not
                                 (lambda (part)
                                   (member (plist-get part :type)
                                           '("text" "reasoning" "tool")))
                                 (plist-get assistant :parts)))
                    (oc-hp-display--sync-text-view))
                  (oc-hp-display--finalize buf))))
          (error
           (message "OpenCode: could not reconcile session %s: %s"
                    oc-hp-popup-session-id (error-message-string err))))))))

;;; --- Final answer assemblage & commit ---

(defun oc-hp-display--record-text (pid text)
  "Note/update a `text' part.  Empty on first sighting, grows per `.updated'."
  (oc-hp-display--put-part pid (list :id pid :type "text" :text text))
  (oc-hp-display--render-ephemeral))

(defun oc-hp-display--summarize-tool-call (name input)
  "Format a tool-name + truncated args line for the ephemeral region."
  (let* ((pairs (when (and (listp input) (keywordp (car input)))
                  (let ((rest input) result)
                    (while rest
                      (push (cons (pop rest) (pop rest)) result))
                    (nreverse result))))
         (arg-str (if pairs
                      (mapconcat
                       (lambda (pair)
                         (let ((value (cdr pair)))
                           (format "%s=%s" (substring (symbol-name (car pair)) 1)
                                   (cond
                                    ((stringp value)
                                     (substring value 0 (min 60 (length value))))
                                    ((null value) "—")
                                    (t (format "%S" value))))))
                       pairs " ")
                    (format "%S" input)))
         (out (format "[%s: %s]" (or name "?") arg-str)))
    (if (> (length out) 120) (concat (substring out 0 117) "...]") out)))

(defun oc-hp-display--render-ephemeral ()
  "Re-render the streaming ephemeral region (between eph-start and eph-end)."
  (when (and oc-hp-display--eph-start
             oc-hp-display--eph-end
             (marker-buffer oc-hp-display--eph-start)
             (marker-buffer oc-hp-display--eph-end))
    (with-current-buffer (marker-buffer oc-hp-display--eph-start)
      (let ((inhibit-read-only t)
            (before-pt (point)))
        ;; Wipe the ephemeral region
        (goto-char oc-hp-display--eph-start)
        (forward-line 1)               ; skip divider line
        (delete-region (point) oc-hp-display--eph-end)
        ;; Build the ephemeral content
        (let ((lines nil))
          (dolist (part oc-hp-display--parts)
            (let ((text (or (plist-get part :text) "")))
              (pcase (plist-get part :type)
                ("reasoning"
                 (unless (string-empty-p text)
                   (push (propertize (concat "* " text)
                                     'face 'oc-hp-display-ephemeral-face)
                         lines)))
                ("tool"
                 (let* ((state (plist-get part :state))
                        (summary (oc-hp-display--summarize-tool-call
                                  (plist-get part :tool)
                                  (plist-get state :input)))
                        (status (plist-get state :status)))
                   (push (propertize
                          (format "%s%s" summary
                                  (if status (format " [%s]" status) ""))
                          'face 'oc-hp-display-tool-face)
                         lines)))
                ("text"
                 (unless (string-empty-p text)
                   (push (propertize text 'face 'oc-hp-display-answer-face)
                         lines))))))
          (when oc-hp-display--error
            (push (propertize (format "[error: %s]" oc-hp-display--error)
                              'face 'error)
                  lines))
          (when lines
            (insert (mapconcat #'identity (nreverse lines) "\n") "\n")))
        (dolist (m (list oc-hp-display--eph-end))
          (set-marker m (point)))
        (goto-char before-pt)))))

(defun oc-hp-display--finalize (buf)
  "Replace the ephemeral region in BUF with the joined final answer text."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (when (and oc-hp-display--eph-start
                   (marker-buffer oc-hp-display--eph-start))
          (goto-char oc-hp-display--eph-start)
          (forward-line 1)               ; skip the divider
          (delete-region (point) (point-max))
          (let ((answer
                 (mapconcat
                  (lambda (part) (or (plist-get part :text) ""))
                  (cl-remove-if-not
                   (lambda (part) (equal (plist-get part :type) "text"))
                   oc-hp-display--parts)
                  "\n\n")))
            (insert (propertize answer 'face 'oc-hp-display-answer-face))
            (when oc-hp-display--error
              (unless (string-empty-p answer) (insert "\n\n"))
              (insert (propertize (format "[OpenCode error: %s]"
                                          oc-hp-display--error)
                                  'face 'error)))
            (insert "\n"))
          (set-marker oc-hp-display--eph-start nil)
          (set-marker oc-hp-display--eph-end nil)
          (setq-local oc-hp-display--finalized t)
          (setq-local oc-hp-popup-phase 2)
          (setq-local buffer-read-only nil)
          (goto-char (point-max))
          (insert "\n")
          ;; Phase 9: anchor so the next :w extracts ONLY the follow-up
          ;; prompt typed below this answer (buffer[answer-end..point-max]).
          ;; insertion-type nil keeps the marker pinned at the end of the
          ;; finalized region while the user types the new prompt after it.
          (setq-local oc-hp-popup-answer-end (copy-marker (point) nil))))))
  ;; notify user visually
  (message (if (with-current-buffer buf oc-hp-display--error)
               "OpenCode: turn failed"
             "OpenCode: turn complete")))

(provide 'opencode-hyprland-popup-display)
;;; opencode-hyprland-popup-display.el ends here
