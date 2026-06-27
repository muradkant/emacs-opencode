;;; opencode-hyprland-popup-server.el --- opencode serve subprocess lifecycle  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; Copyright (C) 2025 opencode.el contributors   ; logic adapted from karta0807913/opencode.el
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 2 of opencode-hyprland-popup: own the `opencode serve' subprocess.
;;
;; We spawn `opencode serve --port 0 --print-logs' (the OS picks a free
;; port), parse the assigned port from the server's stdout via a process
;; filter, poll GET /global/health until healthy, and kill the process on
;; Emacs exit.  This is the lifecycle half of brief §3.2; it supplies the
;; base URL that Phase 1's SSE client consumes.
;;
;; Two modes:
;;   * managed  — we spawn the process (default; `oc-hp-server-port' nil).
;;   * attach   — the user sets `oc-hp-server-port' to a number and we
;;                merely connect to an externally-run server (no spawn,
;;                no kill on exit).  See brief §3.2 "Fallback: attach to
;;                a user-provided server URL via a config option".

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)

(defvar url-http-end-of-headers)

(defgroup oc-hp-server nil
  "`opencode serve' subprocess lifecycle."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-server-")

(defcustom oc-hp-server-command (or (executable-find "opencode") "opencode")
  "Path to the `opencode' executable."
  :type 'string
  :group 'oc-hp-server)

(defcustom oc-hp-server-args '("serve" "--port" "0" "--print-logs")
  "Args passed to `oc-hp-server-command'.
Default uses `--port 0' so the OS assigns a free port."
  :type '(repeat string)
  :group 'oc-hp-server)

(defcustom oc-hp-server-host "127.0.0.1"
  "Hostname of the opencode server."
  :type 'string
  :group 'oc-hp-server)

(defcustom oc-hp-server-port nil
  "Fixed port to attach to; nil to spawn our own `opencode serve'."
  :type '(choice (const :tag "Auto-assign (spawn)" nil)
                 (integer :tag "Attach to existing"))
  :group 'oc-hp-server)

(defcustom oc-hp-server-username "opencode"
  "Basic-auth username (used only when `oc-hp-server-password' is non-nil)."
  :type 'string
  :group 'oc-hp-server)

(defcustom oc-hp-server-password nil
  "Basic-auth password for the opencode server (`OPENCODE_SERVER_PASSWORD').
Set to a string to enable HTTP Basic auth; nil disables it (matches the
default OpenCode launch with no OPENCODE_SERVER_PASSWORD env var)."
  :type '(choice (string :tag "Password")
                 (const :tag "None" nil))
  :group 'oc-hp-server)

(defcustom oc-hp-server-auto-restart t
  "If non-nil, restart the spawned server automatically if it crashes."
  :type 'boolean
  :group 'oc-hp-server)

(defcustom oc-hp-server-restart-delay 2
  "Seconds to wait before auto-restarting a crashed server."
  :type 'number
  :group 'oc-hp-server)

(defcustom oc-hp-server-health-retries 5
  "Number of `/global/health' retries during startup."
  :type 'integer
  :group 'oc-hp-server)

(defcustom oc-hp-server-debug nil
  "If non-nil, log lifecycle events to a `*OC HP Server Debug*' buffer."
  :type 'boolean
  :group 'oc-hp-server)

;;; --- Hooks ---

(defvar oc-hp-server-connected-hook nil
  "Hook run when the server becomes reachable and healthy.")
(defvar oc-hp-server-disconnected-hook nil
  "Hook run when the server stops or crashes.")

;;; --- Internal state ---

(defvar oc-hp-server--process nil)
(defvar oc-hp-server--port nil)
(defvar oc-hp-server--status nil)        ; nil | starting | connected | disconnected | error
(defvar oc-hp-server--stdout-buffer nil)
(defvar oc-hp-server--restart-timer nil)
(defvar oc-hp-server--managed-p nil)

;;; --- Helpers ---

(defun oc-hp-server--debug (fmt &rest args)
  "Append FMT/ARGS to the debug buffer when `oc-hp-server-debug'."
  (when oc-hp-server-debug
    (let ((buf (get-buffer-create "*OC HP Server Debug*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (apply #'format fmt args) "\n"))))))

(defun oc-hp-server--json-parse (string)
  "Parse STRING as JSON into a plist with keyword keys."
  (let ((json-object-type 'plist)
        (json-array-type  'list)
        (json-key-type    'keyword)
        (json-null        nil))
    (condition-case err
        (json-read-from-string string)
      (error
       (oc-hp-server--debug "json parse error: %S on %S" (cdr err) string)
       nil))))

(defun oc-hp-server-connected-p ()
  "Return non-nil if the server is reachable and ready."
  (and oc-hp-server--port (eq oc-hp-server--status 'connected)))

(defun oc-hp-server-auth-headers ()
  "Return an alist of Basic-auth headers, or nil if no password is set."
  (let ((pw (or oc-hp-server-password
               (getenv "OPENCODE_SERVER_PASSWORD"))))
    (when pw
      `(("Authorization" .
         ,(concat "Basic "
                  (base64-encode-string
                   (format "%s:%s" oc-hp-server-username pw) t)))))))

(defun oc-hp-server-url (&optional path)
  "Return the server base URL, optionally with PATH appended.
Errors if not connected."
  (unless (oc-hp-server-connected-p)
    (user-error "OpenCode server not connected; run `oc-hp-server-start'"))
  (let ((base (format "http://%s:%d" oc-hp-server-host oc-hp-server--port)))
    (if path
        (concat base (if (string-prefix-p "/" path) path (concat "/" path)))
      base)))

;;; --- stdout accumulator & port parsing ---

(defun oc-hp-server--ensure-stdout-buffer ()
  "Return the stdout accumulator buffer, creating it if needed."
  (or (and (buffer-live-p oc-hp-server--stdout-buffer)
           oc-hp-server--stdout-buffer)
      (let ((buf (generate-new-buffer " *oc-hp-server-stdout*")))
        (with-current-buffer buf (set-buffer-multibyte t))
        (setq oc-hp-server--stdout-buffer buf))))

(defun oc-hp-server--kill-stdout-buffer ()
  "Kill the stdout accumulator."
  (when (buffer-live-p oc-hp-server--stdout-buffer)
    (kill-buffer oc-hp-server--stdout-buffer))
  (setq oc-hp-server--stdout-buffer nil))

(defun oc-hp-server--try-parse-port (line)
  "Parse a port from LINE during startup.
Matches `listening on http://HOST:PORT' or any `http://HOST:PORT' in the log."
  (when (and (eq oc-hp-server--status 'starting)
             (string-match
              "\\(?:listening on \\|http://[^:/]+:\\)\\([0-9]+\\)" line))
    (let ((port (string-to-number (match-string 1 line))))
      (when (> port 0)
        (setq oc-hp-server--port port)
        (oc-hp-server--debug "parsed port: %d" port)))))

(defun oc-hp-server--process-filter (_process output)
  "Append OUTPUT to the stdout accumulator and scan complete lines for a port."
  (let ((buf (oc-hp-server--ensure-stdout-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert output)
      (goto-char (point-min))
      (while (search-forward "\n" nil t)
        (let* ((nl (point))
               (line (buffer-substring-no-properties (point-min) (1- nl))))
          (delete-region (point-min) nl)
          (goto-char (point-min))
          (unless (string-empty-p line)
            (oc-hp-server--debug "srv| %s" line)
            (oc-hp-server--try-parse-port line)))))))

(defun oc-hp-server--process-sentinel (_process event)
  "Handle the server process changing state."
  (let ((s (string-trim event)))
    (oc-hp-server--debug "sentinel: %s" s)
    (cond
     ((string-match-p "finished\\|exited" s)
      (setq oc-hp-server--status 'disconnected
            oc-hp-server--process nil)
      (run-hooks 'oc-hp-server-disconnected-hook))
     ((string-match-p "killed\\|signal\\|abnormal\\|connection broken" s)
      (setq oc-hp-server--status 'error
            oc-hp-server--process nil)
      (run-hooks 'oc-hp-server-disconnected-hook)
      (when (and oc-hp-server-auto-restart oc-hp-server--managed-p)
        (oc-hp-server--schedule-restart))))))

(defun oc-hp-server--schedule-restart ()
  "Arm a one-shot restart timer."
  (when oc-hp-server--restart-timer
    (cancel-timer oc-hp-server--restart-timer))
  (oc-hp-server--debug "scheduling restart in %ds" oc-hp-server-restart-delay)
  (setq oc-hp-server--restart-timer
        (run-with-timer oc-hp-server-restart-delay nil
                        #'oc-hp-server--do-restart)))

(defun oc-hp-server--do-restart ()
  "Restart the server after a crash."
  (setq oc-hp-server--restart-timer nil)
  (oc-hp-server--debug "restarting")
  (condition-case err
      (oc-hp-server-start)
    (error
     (oc-hp-server--debug "restart failed: %s" (error-message-string err)))))

;;; --- Health check ---

(defun oc-hp-server-health-check ()
  "Synchronously GET `/global/health'; return the parsed plist, else error."
  (let ((url (format "http://%s:%d/global/health"
                     oc-hp-server-host oc-hp-server--port))
        (url-request-extra-headers (oc-hp-server-auth-headers)))
    (let ((buf (url-retrieve-synchronously url t nil 5)))
      (unless buf (error "health check: no response"))
      (unwind-protect
          (with-current-buffer buf
            (goto-char url-http-end-of-headers)
            (or (oc-hp-server--json-parse
                 (buffer-substring-no-properties (point) (point-max)))
                (error "health check: bad JSON")))
        (kill-buffer buf)))))

(defun oc-hp-server--wait-for-health ()
  "Poll `/global/health' until healthy or `oc-hp-server-health-retries' exhausted."
  (let ((retries oc-hp-server-health-retries)
        (delay 0.2)
        ok)
    (while (and (> retries 0) (not ok))
      (condition-case _err
          (let ((resp (oc-hp-server-health-check)))
            (when (plist-get resp :healthy) (setq ok t)))
        (error nil))
      (unless ok
        (setq retries (1- retries))
        (when (> retries 0)
          (sleep-for delay)
          (setq delay (min (* delay 2) 5.0)))))
    (unless ok
      (error "server health check failed after %d retries"
             oc-hp-server-health-retries))
    (oc-hp-server--debug "healthy")
    t))

;;; --- Start / Stop ---

(defun oc-hp-server-start ()
  "Start (or attach to) the OpenCode server; return the base URL on success.
In managed mode (`oc-hp-server-port' nil) we spawn `opencode serve --port 0'
and parse the assigned port.  In attach mode (`oc-hp-server-port' a number)
we merely health-check the existing server at that port; no process is owned."
  (interactive)
  (when (oc-hp-server-connected-p)
    (user-error "OpenCode server already running on port %d; run `oc-hp-server-stop' first"
                oc-hp-server--port))
  (oc-hp-server--kill-stdout-buffer)
  (setq oc-hp-server--status 'starting)
  (if oc-hp-server-port
      (oc-hp-server--attach)
    (oc-hp-server--spawn)))

(defun oc-hp-server--attach ()
  "Attach to an existing server at `oc-hp-server-port'; no spawn."
  (setq oc-hp-server--managed-p nil
        oc-hp-server--port oc-hp-server-port)
  (oc-hp-server--debug "attaching to %s:%d"
                       oc-hp-server-host oc-hp-server--port)
  (condition-case err
      (progn
        (oc-hp-server--wait-for-health)
        (setq oc-hp-server--status 'connected)
        (run-hooks 'oc-hp-server-connected-hook)
        (oc-hp-server-url))
    (error
     (setq oc-hp-server--status 'error
           oc-hp-server--port nil)
     (signal (car err) (cdr err)))))

(defun oc-hp-server--spawn ()
  "Spawn the `opencode serve' subprocess and wait for the port + health."
  (setq oc-hp-server--managed-p t)
  (let* ((args (append oc-hp-server-args
                       (list "--hostname" oc-hp-server-host)))
         (proc (apply #'start-process
                      "oc-hp-server" nil
                      oc-hp-server-command args)))
    (oc-hp-server--debug "spawn: %s %s" oc-hp-server-command
                         (string-join args " "))
    (set-process-filter proc #'oc-hp-server--process-filter)
    (set-process-sentinel proc #'oc-hp-server--process-sentinel)
    (set-process-query-on-exit-flag proc nil)
    (setq oc-hp-server--process proc)
    (let ((deadline (+ (float-time) 15.0)))
      (while (and (not oc-hp-server--port)
                  (< (float-time) deadline)
                  (process-live-p proc))
        (accept-process-output proc 0.1)))
    (unless oc-hp-server--port
      (when (process-live-p proc) (delete-process proc))
      (setq oc-hp-server--status 'error
            oc-hp-server--process nil)
      (error "Timed out waiting for opencode server port"))
    (condition-case err
        (progn
          (oc-hp-server--wait-for-health)
          (setq oc-hp-server--status 'connected)
          (oc-hp-server--debug "ready on port %d" oc-hp-server--port)
          (run-hooks 'oc-hp-server-connected-hook)
          (oc-hp-server-url))
      (error
       (when (process-live-p proc) (delete-process proc))
       (setq oc-hp-server--status 'error
             oc-hp-server--process nil
             oc-hp-server--port nil)
       (signal (car err) (cdr err))))))

(defun oc-hp-server-stop ()
  "Stop the managed server (or detach from an attached one)."
  (interactive)
  (when oc-hp-server--restart-timer
    (cancel-timer oc-hp-server--restart-timer)
    (setq oc-hp-server--restart-timer nil))
  ;; Graceful dispose in managed mode only (don't kill someone else's server).
  (when (and oc-hp-server--managed-p
             oc-hp-server--port
             (eq oc-hp-server--status 'connected))
    (condition-case err
        (let* ((url (format "http://%s:%d/global/dispose"
                            oc-hp-server-host oc-hp-server--port))
               (url-request-method "POST")
               (url-request-extra-headers
                (append '(("Content-Type" . "application/json"))
                        (oc-hp-server-auth-headers))))
          (let ((buf (url-retrieve-synchronously url t nil 3)))
            (when buf (kill-buffer buf)))
          (oc-hp-server--debug "disposed"))
      (error
       (oc-hp-server--debug "dispose failed: %s" (error-message-string err)))))
  (when (and oc-hp-server--process (process-live-p oc-hp-server--process))
    (let ((proc oc-hp-server--process))
      (set-process-sentinel proc #'ignore)
      (delete-process proc)
      (oc-hp-server--debug "process killed")))
  (setq oc-hp-server--process nil
        oc-hp-server--port nil
        oc-hp-server--status 'disconnected
        oc-hp-server--managed-p nil)
  (oc-hp-server--kill-stdout-buffer)
  (run-hooks 'oc-hp-server-disconnected-hook)
  (when (called-interactively-p 'interactive)
    (message "opencode server stopped")))

;; Don't orphan a managed server when Emacs dies.
(add-hook 'kill-emacs-hook #'oc-hp-server-stop)

(provide 'opencode-hyprland-popup-server)
;;; opencode-hyprland-popup-server.el ends here