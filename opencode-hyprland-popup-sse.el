;;; opencode-hyprland-popup-sse.el --- SSE client for opencode-hyprland-popup  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; Copyright (C) 2025 opencode.el contributors   ; logic adapted from karta0807913/opencode.el
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Real-time Server-Sent-Events consumer for the OpenCode HTTP server's
;; `/global/event` stream.  Uses a `curl --no-buffer' subprocess for true
;; streaming (the built-in `url-retrieve' buffers the whole body and
;; fires once — unusable for SSE).
;;
;; Phase 1 of the opencode-hyprland-popup package: pure transport.  The
;; caller supplies a URL (and optional auth headers) via `oc-hp-sse-connect';
;; there is no dependency on a server-lifecycle module here.  Phase 2 will
;; obtain the URL from a spawned `opencode serve' process.
;;
;; Key gotchas honoured here (each confirmed against the reference impl and
;; the live server on 2026-06-25):
;;   * `curl -N' / `--no-buffer' is mandatory or curl blocks on stdio.
;;   * `'utf-8-unix' coding forces unix EOLs; the default autodetect can
;;     buffer data until a line ending appears, starving the filter.
;;   * `process-adaptive-read-buffering' set to nil disables Emacs's
;;     coalescing of small reads, which otherwise adds seconds of latency.
;;   * The event TYPE lives in the JSON payload's `type' field (the SSE
;;     `event:' wire field is only a fallback) — the OpenCode server emits
;;     bare `data:' lines.  Two JSON envelope shapes are handled: the
;;     global `{directory, payload:{type,properties}}' form and the
;;     instance `{type, properties}' form.  `sync' envelopes are dropped
;;     because the server re-publishes each as a bus event.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'map)

(defgroup opencode-hyprland-popup nil
  "OpenCode Hyprland popup — Emacs frontend over a local OpenCode server."
  :group 'tools)

(defgroup oc-hp-sse nil
  "Server-Sent-Events stream for opencode-hyprland-popup."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-sse-")

(defcustom oc-hp-sse-heartbeat-timeout 60
  "Seconds with no event before assuming the connection is dead.
The OpenCode server emits a heartbeat roughly every 30s."
  :type 'integer
  :group 'oc-hp-sse)

(defcustom oc-hp-sse-max-reconnect-delay 30
  "Upper bound (seconds) on the exponential reconnect backoff."
  :type 'integer
  :group 'oc-hp-sse)

(defcustom oc-hp-sse-auto-reconnect t
  "When non-nil, reconnect automatically after the stream drops."
  :type 'boolean
  :group 'oc-hp-sse)

(defcustom oc-hp-sse-debug nil
  "When non-nil, log raw events and filter details to a debug buffer.
Set this to `t' to diagnose transport issues; it is silent by default."
  :type 'boolean
  :group 'oc-hp-sse)

;;; --- Hook variables ---

(defvar oc-hp-sse-event-hook nil
  "Hook run for EVERY parsed event.
Each function gets one argument: the event plist
\(:type :properties :id :directory\).")

(defvar oc-hp-sse-server-connected-hook nil
  "Hook run on `server.connected'.")
(defvar oc-hp-sse-server-heartbeat-hook nil
  "Hook run on `server.heartbeat'.")
(defvar oc-hp-sse-server-instance-disposed-hook nil
  "Hook run on `server.instance.disposed'.")
(defvar oc-hp-sse-session-updated-hook nil
  "Hook run on `session.updated' (props include :sessionID).")
(defvar oc-hp-sse-session-created-hook nil
  "Hook run on `session.created'.")
(defvar oc-hp-sse-session-status-hook nil
  "Hook run on `session.status' (props include :sessionID and :status).
The brief's turn-complete signal is `session.status' with status type
`idle' — this is the hook Phase 5 keystones on.")
(defvar oc-hp-sse-session-idle-hook nil
  "Hook run on `session.idle'.")
(defvar oc-hp-sse-session-deleted-hook nil
  "Hook run on `session.deleted'.")
(defvar oc-hp-sse-session-error-hook nil
  "Hook run on `session.error'.")
(defvar oc-hp-sse-session-diff-hook nil
  "Hook run on `session.diff'.")
(defvar oc-hp-sse-session-compacted-hook nil
  "Hook run on `session.compacted'.")

;; v1 message.* events — kept for parity; Phase 5 will decide whether
;; the live 1.17.11 stream uses these or the v2 session.next.* set.
(defvar oc-hp-sse-message-updated-hook nil
  "Hook run on `message.updated'.")
(defvar oc-hp-sse-message-removed-hook nil
  "Hook run on `message.removed'.")
(defvar oc-hp-sse-message-part-updated-hook nil
  "Hook run on `message.part.updated' (alias: `.delta').")
(defvar oc-hp-sse-message-part-removed-hook nil
  "Hook run on `message.part.removed'.")

;; v2 session.next.* events — the brief (§4) prefers these over v1.
(defvar oc-hp-sse-session-next-reasoning-hook nil
  "Hook run on `session.next.reasoning.{started,delta,ended}'.")
(defvar oc-hp-sse-session-next-tool-hook nil
  "Hook run on `session.next.tool.{called,success,failed}'.")
(defvar oc-hp-sse-session-next-text-hook nil
  "Hook run on `session.next.text.{delta,ended}'.")
(defvar oc-hp-sse-session-next-step-hook nil
  "Hook run on `session.next.step.{started,ended}'.")

(defvar oc-hp-sse-permission-asked-hook nil
  "Hook run on `permission.asked' (Phase 7).")
(defvar oc-hp-sse-permission-replied-hook nil
  "Hook run on `permission.replied'.")
(defvar oc-hp-sse-question-asked-hook nil
  "Hook run on `question.asked'.")
(defvar oc-hp-sse-question-replied-hook nil
  "Hook run on `question.replied'.")
(defvar oc-hp-sse-question-rejected-hook nil
  "Hook run on `question.rejected'.")
(defvar oc-hp-sse-todo-updated-hook nil
  "Hook run on `todo.updated'.")
(defvar oc-hp-sse-installation-update-available-hook nil
  "Hook run on `installation.update-available'.")
(defvar oc-hp-sse-tui-toast-show-hook nil
  "Hook run on `tui.toast.show' (props include :message).")

;;; --- Internal state ---

(defvar oc-hp-sse--process nil
  "The `curl' subprocess driving the SSE stream.")

(defvar oc-hp-sse--buffer nil
  "Accumulator buffer for partial SSE data.
A real buffer (gap buffer) is used instead of string concat for O(1)
appends and a single bulk delete of consumed lines.")

(defvar oc-hp-sse--current-event nil
  "Plist for the SSE event currently being assembled.")
(defvar oc-hp-sse--last-event-id nil
  "ID of the most recent SSE event (used for resume / diagnostics).")
(defvar oc-hp-sse--url nil
  "URL the stream is connected to (kept for reconnect).")
(defvar oc-hp-sse--auth-headers nil
  "Auth header alist passed to `curl' (kept for reconnect).")
(defvar oc-hp-sse--reconnect-timer nil)
(defvar oc-hp-sse--reconnect-delay 1)
(defvar oc-hp-sse--heartbeat-timer nil)
(defvar oc-hp-sse--last-event-time nil)
(defvar oc-hp-sse--curl-path-cache nil)

;;; --- Predicates / state helpers ---

(defun oc-hp-sse-connected-p ()
  "Return non-nil if the SSE stream is alive."
  (and (processp oc-hp-sse--process)
       (process-live-p oc-hp-sse--process)))

(defun oc-hp-sse--ensure-buffer ()
  "Return the SSE accumulator buffer, creating it if needed."
  (or (and (buffer-live-p oc-hp-sse--buffer) oc-hp-sse--buffer)
      (let ((buf (generate-new-buffer " *oc-hp-sse-accum*")))
        (with-current-buffer buf (set-buffer-multibyte t))
        (setq oc-hp-sse--buffer buf))))

(defun oc-hp-sse--kill-buffer ()
  "Kill the accumulator buffer if present."
  (when (buffer-live-p oc-hp-sse--buffer)
    (kill-buffer oc-hp-sse--buffer))
  (setq oc-hp-sse--buffer nil))

(defun oc-hp-sse--reset-state ()
  "Clear per-connection mutable state (not the reconnect/URL state)."
  (oc-hp-sse--kill-buffer)
  (setq oc-hp-sse--current-event nil
        oc-hp-sse--last-event-time nil))

;;; --- Debug ---

(defun oc-hp-sse--debug (fmt &rest args)
  "When `oc-hp-sse-debug', append FMT/ARGS to the debug buffer."
  (when oc-hp-sse-debug
    (let ((buf (get-buffer-create "*OC HP SSE Debug*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (apply #'format fmt args) "\n"))))))

;;; --- SSE line parser ---

(defun oc-hp-sse--process-line (line)
  "Fold one SSE LINE into the current event, dispatching on a blank line."
  (cond
   ((string-empty-p line)
    (when oc-hp-sse--current-event
      (let ((type (or (plist-get oc-hp-sse--current-event :event-type) "message"))
            (data (plist-get oc-hp-sse--current-event :data))
            (id   (plist-get oc-hp-sse--current-event :id)))
        (when data (oc-hp-sse--dispatch-event type data id)))
      (setq oc-hp-sse--current-event nil)))
   ((string-prefix-p ":" line) nil)            ; SSE comment / keepalive
   ((string-match "^event: ?\\(.*\\)" line)
    (setq oc-hp-sse--current-event
          (plist-put (or oc-hp-sse--current-event '())
                     :event-type (match-string 1 line))))
   ((string-match "^data: ?\\(.*\\)" line)
    (let ((prev (plist-get oc-hp-sse--current-event :data)))
      (setq oc-hp-sse--current-event
            (plist-put (or oc-hp-sse--current-event '())
                       :data (if prev
                                 (concat prev "\n" (match-string 1 line))
                               (match-string 1 line))))))
   ((string-match "^id: ?\\(.*\\)" line)
    (setq oc-hp-sse--current-event
          (plist-put (or oc-hp-sse--current-event '())
                     :id (match-string 1 line)))
    (setq oc-hp-sse--last-event-id (match-string 1 line)))
   (t nil)))                                    ; unknown field, per spec ignore

;;; --- Event dispatch ---

(defun oc-hp-sse--dispatch-event (event-type data-string &optional id)
  "Parse DATA-STRING and run hooks for the SSE event EVENT-TYPE."
  (oc-hp-sse--debug "raw: type=%s data=%s" event-type data-string)
  (setq oc-hp-sse--last-event-time (float-time))
  (setq oc-hp-sse--reconnect-delay 1)          ; reset backoff on activity
  (condition-case err
      (let ((event (oc-hp-sse--parse-event event-type data-string id)))
        (when event (oc-hp-sse--run-hooks event)))
    (error
     (oc-hp-sse--debug "dispatch error (%s): %s"
                       event-type (error-message-string err)))))

(defun oc-hp-sse--parse-event (event-type data-string id)
  "Parse DATA-STRING into a normalized event plist, or nil to drop it.
Handles the two OpenCode envelopes:
  global:   {directory, payload:{type, properties}}
  instance: {type, properties}
`sync' envelopes return nil — the server re-publishes every sync event as
a bus event, so processing both would double-fire every handler."
  (let* ((json-data (oc-hp-sse--json-parse data-string))
         (payload (plist-get json-data :payload)))
    (cond
     ((and payload (equal (plist-get payload :type) "sync")) nil)
     (payload
      (list :type (or (plist-get payload :type) event-type)
            :properties (plist-get payload :properties)
            :directory (plist-get json-data :directory)
            :id id))
     ((plist-get json-data :type)
      (list :type (plist-get json-data :type)
            :properties (plist-get json-data :properties)
            :id id))
     (t (list :type event-type :properties json-data :id id)))))

(defun oc-hp-sse--json-parse (string)
  "Parse STRING as JSON into a plist with keyword keys."
  (let ((json-object-type 'plist)
        (json-array-type  'list)
        (json-key-type    'keyword)
        (json-null        nil))
    (json-read-from-string string)))

(defun oc-hp-sse--run-hooks (event)
  "Run the catch-all hook and the type-specific hook for EVENT."
  (let ((type (plist-get event :type)))
    (oc-hp-sse--debug "[%s] dir=%s props=%S"
                      type
                      (plist-get event :directory)
                      (and (plist-get event :properties)
                           (map-keys (plist-get event :properties))))
    (run-hook-with-args 'oc-hp-sse-event-hook event)
    (when-let ((hook (oc-hp-sse--hook-for-type type)))
      (run-hook-with-args hook event))))

(defconst oc-hp-sse--type->hook
  '(("server.connected"              . oc-hp-sse-server-connected-hook)
    ("server.heartbeat"             . oc-hp-sse-server-heartbeat-hook)
    ("server.instance.disposed"      . oc-hp-sse-server-instance-disposed-hook)
    ("session.updated"              . oc-hp-sse-session-updated-hook)
    ("session.created"              . oc-hp-sse-session-created-hook)
    ("session.status"               . oc-hp-sse-session-status-hook)
    ("session.idle"                 . oc-hp-sse-session-idle-hook)
    ("session.deleted"              . oc-hp-sse-session-deleted-hook)
    ("session.error"                . oc-hp-sse-session-error-hook)
    ("session.diff"                 . oc-hp-sse-session-diff-hook)
    ("session.compacted"            . oc-hp-sse-session-compacted-hook)
    ("message.updated"              . oc-hp-sse-message-updated-hook)
    ("message.removed"             . oc-hp-sse-message-removed-hook)
    ("message.part.updated"         . oc-hp-sse-message-part-updated-hook)
    ("message.part.delta"          . oc-hp-sse-message-part-updated-hook)
    ("message.part.removed"         . oc-hp-sse-message-part-removed-hook)
    ;; v2 session.next.* — Phase 5 will confirm which these map to.
    ("session.next.reasoning.started" . oc-hp-sse-session-next-reasoning-hook)
    ("session.next.reasoning.delta"   . oc-hp-sse-session-next-reasoning-hook)
    ("session.next.reasoning.ended"   . oc-hp-sse-session-next-reasoning-hook)
    ("session.next.tool.called"       . oc-hp-sse-session-next-tool-hook)
    ("session.next.tool.success"      . oc-hp-sse-session-next-tool-hook)
    ("session.next.tool.failed"       . oc-hp-sse-session-next-tool-hook)
    ("session.next.text.delta"        . oc-hp-sse-session-next-text-hook)
    ("session.next.text.ended"        . oc-hp-sse-session-next-text-hook)
    ("session.next.step.started"      . oc-hp-sse-session-next-step-hook)
    ("session.next.step.ended"        . oc-hp-sse-session-next-step-hook)
    ("permission.asked"            . oc-hp-sse-permission-asked-hook)
    ("permission.replied"          . oc-hp-sse-permission-replied-hook)
    ("question.asked"              . oc-hp-sse-question-asked-hook)
    ("question.replied"            . oc-hp-sse-question-replied-hook)
    ("question.rejected"           . oc-hp-sse-question-rejected-hook)
    ("todo.updated"                . oc-hp-sse-todo-updated-hook)
    ("installation.update-available" . oc-hp-sse-installation-update-available-hook)
    ("tui.toast.show"              . oc-hp-sse-tui-toast-show-hook))
  "Map event TYPE (string) → hook variable symbol.")

(defun oc-hp-sse--hook-for-type (type)
  "Return the hook symbol for event TYPE, or nil."
  (cdr (assoc type oc-hp-sse--type->hook)))

;;; --- Process filter ---

(defun oc-hp-sse--filter (_process output)
  "Append OUTPUT to the accumulator and dispatch any complete SSE lines.
Two optimizations from the reference impl:
  1. skip the newline scan entirely when the new chunk has no `\\n' —
     the leftover tail has no complete lines, so only new data can close one;
  2. one bulk `delete-region' of all consumed lines instead of per-line
     deletes (avoids O(k*n) on big turns)."
  (let ((accum-buf (oc-hp-sse--ensure-buffer)))
    (with-current-buffer accum-buf
      (goto-char (point-max))
      (insert output)
      (when (string-search "\n" output)
        (goto-char (point-min))
        (let (consumed-end line-count)
          (while (search-forward "\n" nil t)
            (let* ((nl-pos (point))
                   (raw (buffer-substring-no-properties
                         (or consumed-end (point-min)) (1- nl-pos)))
                   (line (if (and (not (string-empty-p raw))
                                  (eq (aref raw (1- (length raw))) ?\r))
                             (substring raw 0 -1)
                           raw)))
              (setq consumed-end nl-pos
                    line-count (1+ (or line-count 0)))
              (oc-hp-sse--process-line line)))
          (when consumed-end
            (delete-region (point-min) consumed-end))
          (when line-count
            (oc-hp-sse--debug "processed %d lines, %d bytes held"
                              line-count (- (point-max) (point-min)))))))))

;;; --- Sentinel / reconnect / heartbeat ---

(defun oc-hp-sse--sentinel (_process event)
  "Handle stream loss; schedule a reconnect if auto-reconnect is on."
  (let ((s (string-trim event)))
    (oc-hp-sse--debug "sentinel: %s" s)
    (unless (string-match-p "\\`open" s)
      (setq oc-hp-sse--process nil)
      (oc-hp-sse--stop-heartbeat)
      (when oc-hp-sse-auto-reconnect
        (oc-hp-sse--schedule-reconnect)))))

(defun oc-hp-sse--schedule-reconnect ()
  "Arm a one-shot reconnect timer with exponential backoff."
  (when oc-hp-sse--reconnect-timer
    (cancel-timer oc-hp-sse--reconnect-timer))
  (setq oc-hp-sse--reconnect-timer
        (run-with-timer oc-hp-sse--reconnect-delay nil
                        #'oc-hp-sse--do-reconnect))
  (setq oc-hp-sse--reconnect-delay
        (min (* oc-hp-sse--reconnect-delay 2)
             oc-hp-sse-max-reconnect-delay)))

(defun oc-hp-sse--do-reconnect ()
  "Retry `oc-hp-sse-connect' against the last recorded URL."
  (setq oc-hp-sse--reconnect-timer nil)
  (condition-case err
      (when oc-hp-sse--url
        (oc-hp-sse--debug "reconnecting to %s" oc-hp-sse--url)
        (oc-hp-sse-connect oc-hp-sse--url oc-hp-sse--auth-headers))
    (error
     (oc-hp-sse--debug "reconnect failed: %s" (error-message-string err))
     (when oc-hp-sse-auto-reconnect
       (oc-hp-sse--schedule-reconnect)))))

(defun oc-hp-sse--start-heartbeat ()
  "Arm the heartbeat watchdog."
  (oc-hp-sse--stop-heartbeat)
  (setq oc-hp-sse--last-event-time (float-time))
  (setq oc-hp-sse--heartbeat-timer
        (run-with-timer oc-hp-sse-heartbeat-timeout
                        oc-hp-sse-heartbeat-timeout
                        #'oc-hp-sse--check-heartbeat)))

(defun oc-hp-sse--stop-heartbeat ()
  "Cancel the heartbeat watchdog, if armed."
  (when oc-hp-sse--heartbeat-timer
    (cancel-timer oc-hp-sse--heartbeat-timer)
    (setq oc-hp-sse--heartbeat-timer nil)))

(defun oc-hp-sse--check-heartbeat ()
  "Reconnect if no event has arrived within the heartbeat window."
  (when (and oc-hp-sse--last-event-time
             (> (- (float-time) oc-hp-sse--last-event-time)
                oc-hp-sse-heartbeat-timeout))
    (oc-hp-sse--debug "heartbeat timeout — reconnecting")
    (oc-hp-sse-disconnect)
    (when oc-hp-sse-auto-reconnect
      (oc-hp-sse--schedule-reconnect))))

;;; --- Curl transport ---

(defun oc-hp-sse--curl-path ()
  "Return the cached path to `curl', or error if missing."
  (or oc-hp-sse--curl-path-cache
      (setq oc-hp-sse--curl-path-cache
            (or (executable-find "curl")
                (error "curl not found in exec-path")))))

(defun oc-hp-sse-connect (url &optional auth-headers)
  "Connect to the OpenCode SSE stream at URL via `curl --no-buffer'.
AUTH-HEADERS is an alist of extra header conses
\(\(\"Header-Name\" . \"value\"\)\), e.g. for HTTP Basic auth.

Returns the curl process on success; nil otherwise.  Connecting while
already connected first disconnects."
  (interactive
   (list (read-string "OpenCode SSE URL: "
                      (or oc-hp-sse--url "http://localhost:4100/global/event"))))
  (when (oc-hp-sse-connected-p)
    (oc-hp-sse-disconnect))
  (oc-hp-sse--reset-state)
  (let* ((process-adaptive-read-buffering nil)   ; CRITICAL streaming latency
         (header-args
          (cl-loop for (k . v) in auth-headers
                   append (list "-H" (format "%s: %s" k v))))
         (curl-args
          (append (list "-s" "-N"
                        "-H" "Accept: text/event-stream"
                        "-H" "Cache-Control: no-cache")
                  header-args
                  (list url))))
    (setq oc-hp-sse--url url
          oc-hp-sse--auth-headers auth-headers)
    (oc-hp-sse--debug "connecting to %s" url)
    (oc-hp-sse--debug "curl args: %S" curl-args)
    (condition-case err
        (let ((proc (apply #'start-process
                            "oc-hp-sse" nil
                            (oc-hp-sse--curl-path) curl-args)))
          (when proc
            (setq oc-hp-sse--process proc)
            (set-process-filter proc #'oc-hp-sse--filter)
            (set-process-sentinel proc #'oc-hp-sse--sentinel)
            (set-process-query-on-exit-flag proc nil)
            (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
            (when (fboundp 'set-process-adaptive-read-buffering)
              (set-process-adaptive-read-buffering proc nil))
            (oc-hp-sse--start-heartbeat)
            (oc-hp-sse--debug "curl pid=%s" (process-id proc))
            proc))
      (error
       (oc-hp-sse--debug "connect failed: %s" (error-message-string err))
       (signal (car err) (cdr err))))))

(defun oc-hp-sse-disconnect ()
  "Tear down the SSE stream and its timers."
  (interactive)
  (oc-hp-sse--debug "disconnecting")
  (when oc-hp-sse--reconnect-timer
    (cancel-timer oc-hp-sse--reconnect-timer)
    (setq oc-hp-sse--reconnect-timer nil))
  (oc-hp-sse--stop-heartbeat)
  (when (and oc-hp-sse--process (process-live-p oc-hp-sse--process))
    (set-process-sentinel oc-hp-sse--process #'ignore)
    (delete-process oc-hp-sse--process))
  (setq oc-hp-sse--process nil)
  (oc-hp-sse--reset-state)
  (when (called-interactively-p 'interactive)
    (message "oc-hp-sse: disconnected")))

;;; --- Test entrypoint (Phase 1 only) ---

(defvar oc-hp-sse--test-logger-added nil
  "Non-nil while the test logger is on `oc-hp-sse-event-hook'.")

(defun oc-hp-sse--test-logger (event)
  "Message the type and top-level property keys of EVENT."
  (message "oc-hp-sse: [%s] props=%S"
           (plist-get event :type)
           (and (plist-get event :properties)
                (map-keys (plist-get event :properties)))))

(defun oc-hp-sse-test-connect (url &optional auth-headers)
  "Connect to URL and echo every event to `*Messages*'.
Enables `oc-hp-sse-debug' and installs a one-shot logger on the event
hook (removed by `oc-hp-sse-test-disconnect').  Use this to verify
transport against a live `opencode serve' server.
URL defaults to `http://localhost:4100/global/event'."
  (interactive
   (list (read-string "OpenCode SSE URL: "
                      (or oc-hp-sse--url "http://localhost:4100/global/event"))))
  (setq oc-hp-sse-debug t)
  (unless oc-hp-sse--test-logger-added
    (add-hook 'oc-hp-sse-event-hook #'oc-hp-sse--test-logger)
    (setq oc-hp-sse--test-logger-added t))
  (let ((proc (oc-hp-sse-connect url auth-headers)))
    (message "oc-hp-sse: test connect %s -> %s"
             url (if proc "ok" "FAILED"))
    proc))

(defun oc-hp-sse-test-disconnect ()
  "Disconnect and remove the test logger installed by `oc-hp-sse-test-connect'."
  (interactive)
  (oc-hp-sse-disconnect)
  (when oc-hp-sse--test-logger-added
    (remove-hook 'oc-hp-sse-event-hook #'oc-hp-sse--test-logger)
    (setq oc-hp-sse--test-logger-added nil))
  (setq oc-hp-sse-debug nil)
  (message "oc-hp-sse: test disconnect done"))

;; Danger guard: background curl should never prompt on Emacs exit.
(add-hook 'kill-emacs-hook #'oc-hp-sse-disconnect)

(provide 'opencode-hyprland-popup-sse)
;;; opencode-hyprland-popup-sse.el ends here