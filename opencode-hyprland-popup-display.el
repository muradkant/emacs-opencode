;;; opencode-hyprland-popup-display.el --- Three-phase streaming display  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 5 three-phase display for opencode-hyprland-popup, keyed on the
;; v1 event stream emitted by OpenCode 1.17.11 (see RESEARCH §13.7 — the
;; live server emits `message.part.*` events, not the v2 `session.next.*'
;; the dev branch schema describes).
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
(defvar-local oc-hp-display--text-by-part nil
  "Alist of partID -> ordered (index . final-text) for `text' parts.
Insertion-ordered list of `(partID . final-text)' pairs; on idle we
concatenate them in insertion order to form the answer.")
(defvar-local oc-hp-display--tools nil
  "Accumulated tool-call summaries (string list) shown in the ephemeral region.")
(defvar-local oc-hp-display--reasoning nil
  "Accumulated reasoning text (string) shown in the ephemeral region.")
(defvar-local oc-hp-display--finalized nil
  "Non-nil once the turn has finalized (Phase 2) — prevents double-finalize.")

(defvar oc-hp-display--handlers-attached nil
  "Non-nil once we've added the SSE event handlers globally.")

(defvar oc-hp-display--message-role-by-id (make-hash-table :test 'equal)
  "Cache from OpenCode message id to role string.")

;;; --- Buffer guard ---

(defvar oc-hp-popup-phase 0
  "Defined in opencode-hyprland-popup.el; declared here for free-use warnings.")
(defvar oc-hp-popup-directory nil
  "Defined in opencode-hyprland-popup.el; declared here for free-use warnings.")

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
    (setq-local oc-hp-display--text-by-part nil
                oc-hp-display--tools nil
                oc-hp-display--reasoning nil
                oc-hp-display--finalized nil)
    (setq-local oc-hp-popup-phase 1)
    ;; Attach SSE handlers once, globally (popup buffers switch over time)
    (oc-hp-display--attach-handlers)
    (oc-hp-display--render-ephemeral)))

;;; --- SSE handlers (attached once per Emacs session) ---

(defun oc-hp-display--attach-handlers ()
  "Attach the v1 event handlers to the SSE hook (idempotent, global)."
  (unless oc-hp-display--handlers-attached
    (add-hook 'oc-hp-sse-message-updated-hook #'oc-hp-display--handle-message-updated)
    (add-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-display--handle-part-updated)
    (add-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-display--handle-part-delta)
    (add-hook 'oc-hp-sse-session-status-hook #'oc-hp-display--handle-status)
    (setq oc-hp-display--handlers-attached t)))

(defun oc-hp-display--detach-handlers ()
  "Detach (for cleanup / test)."
  (remove-hook 'oc-hp-sse-message-updated-hook #'oc-hp-display--handle-message-updated)
  (remove-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-display--handle-part-updated)
  (remove-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-display--handle-part-delta)
  (remove-hook 'oc-hp-sse-session-status-hook #'oc-hp-display--handle-status)
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
        ("text"
         (let ((text (or (plist-get part :text) "")))
           (oc-hp-display--record-text pid text)))
        ("reasoning"
         (let ((text (or (plist-get part :text) "")))
           (when (and text (not (string-empty-p text)))
             (setq-local oc-hp-display--reasoning
                         (concat oc-hp-display--reasoning text))
             (oc-hp-display--render-ephemeral))))
        ("tool"
         (let* ((name (plist-get part :tool))
                (input (plist-get part :input))
                (summary (oc-hp-display--summarize-tool-call name input)))
           (push (cons pid summary) oc-hp-display--tools)
           (oc-hp-display--render-ephemeral)))
        (_ nil)))))

(defun oc-hp-display--on-part-delta (event)
  "Append a streaming text delta."
  (let* ((props (plist-get event :properties))
         (pid (plist-get props :partID))
         (delta (plist-get props :delta)))
    (when (and (oc-hp-display--assistant-event-p event)
               pid delta
               (not (string-empty-p delta))
               (assq pid oc-hp-display--text-by-part))
      ;; Update final-text for the in-progress text part
      (setcdr (assq pid oc-hp-display--text-by-part)
              (concat (cdr (assq pid oc-hp-display--text-by-part)) delta))
      (oc-hp-display--render-ephemeral))))

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

;;; --- Final answer assemblage & commit ---

(defun oc-hp-display--record-text (pid text)
  "Note/update a `text' part.  Empty on first sighting, grows per `.updated'."
  (if (assq pid oc-hp-display--text-by-part)
      (setcdr (assq pid oc-hp-display--text-by-part) text)
    (push (cons pid text) oc-hp-display--text-by-part))
  (oc-hp-display--render-ephemeral))

(defun oc-hp-display--summarize-tool-call (name input)
  "Format a tool-name + truncated args line for the ephemeral region."
  (let* ((arg-str (if (listp input)
                      (mapconcat (lambda (kv)
                                   (format "%s=%s" (car kv)
                                           (let ((v (if (listp (cdr kv)) (cdr kv) (cdr kv))))
                                             (cond
                                              ((stringp v)
                                               (substring v 0 (min 60 (length v))))
                                              ((null v) "—")
                                              (t (format "%S" v))))))
                                 input " ")
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
          (when (and oc-hp-display--reasoning
                     (not (string-empty-p oc-hp-display--reasoning)))
            (push (propertize (concat "* " oc-hp-display--reasoning)
                              'face 'oc-hp-display-ephemeral-face)
                  lines))
          (dolist (tool (nreverse (mapcar #'cdr oc-hp-display--tools)))
            (push (propertize tool 'face 'oc-hp-display-tool-face) lines))
          (when oc-hp-display--text-by-part
            (let ((live
                   (mapconcat #'cdr (nreverse oc-hp-display--text-by-part) "\n\n")))
              (push (propertize live 'face 'oc-hp-display-answer-face)
                    lines)))
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
                 (mapconcat #'cdr (nreverse oc-hp-display--text-by-part) "\n\n")))
            (insert (propertize answer 'face 'oc-hp-display-answer-face))
            (insert "\n"))
          (set-marker oc-hp-display--eph-start nil)
          (set-marker oc-hp-display--eph-end nil)
          (setq-local oc-hp-display--finalized t)
          (setq-local oc-hp-popup-phase 2)
          (goto-char (point-max))
          (insert "\n")
          ;; Phase 9: anchor so the next :w extracts ONLY the follow-up
          ;; prompt typed below this answer (buffer[answer-end..point-max]).
          ;; insertion-type nil keeps the marker pinned at the end of the
          ;; finalized region while the user types the new prompt after it.
          (setq-local oc-hp-popup-answer-end (copy-marker (point) nil))))))
  ;; notify user visually
  (message "OpenCode: turn complete"))

(provide 'opencode-hyprland-popup-display)
;;; opencode-hyprland-popup-display.el ends here
