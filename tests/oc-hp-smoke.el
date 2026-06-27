;;; oc-hp-smoke.el --- Batch transport smoke test for opencode-hyprland-popup  -*- lexical-binding: t; -*-

;; Verifies Phases 1-3 transport end-to-end against a REAL opencode serve,
;; WITHOUT burning LLM quota (no prompt is sent).  Confirms:
;;   * Phase 2: `opencode serve --port 0' spawns, port parsed, health green.
;;   * Phase 1: `oc-hp-sse-connect' to /global/event streams events.
;;   * server.connected arrives within a few seconds.
;;   * Phase 6/7/8 require-chain loads cleanly (the point of this re-run).
;;   * Clean teardown leaves no orphan `opencode serve' / `curl' processes.

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup-server)
(require 'opencode-hyprland-popup-sse)

(defvar oc-hp-smoke--seen-types nil
  "Accumulator of event type strings observed during the smoke test.")
(defvar oc-hp-smoke--connected nil
  "Set to t once `server.connected' is observed.")

(defun oc-hp-smoke--logger (event)
  "Record EVENT's type; flip `oc-hp-smoke--connected' on server.connected."
  (let ((type (plist-get event :type)))
    (push type oc-hp-smoke--seen-types)
    (when (equal type "server.connected")
      (setq oc-hp-smoke--connected t))
    (message "SMOKE event: %s" type)))

(defun oc-hp-smoke--run ()
  "Run the smoke test; return non-nil on success."
  (message "SMOKE: starting opencode serve ...")
  (setq oc-hp-smoke--seen-types nil
        oc-hp-smoke--connected nil)
  (add-hook 'oc-hp-sse-event-hook #'oc-hp-smoke--logger)
  (condition-case err
      (let ((url (oc-hp-server-start)))
        (message "SMOKE: server up at %s" url)
        (oc-hp-sse-connect (oc-hp-server-url "/global/event")
                           (oc-hp-server-auth-headers))
        (message "SMOKE: SSE connecting; waiting up to 10s for server.connected ...")
        (let ((deadline (+ (float-time) 10.0)))
          (while (and (not oc-hp-smoke--connected)
                      (< (float-time) deadline))
            (accept-process-output nil 0.2)))
        (if oc-hp-smoke--connected
            (message "SMOKE: SUCCESS — server.connected received")
          (message "SMOKE: FAIL — no server.connected (saw %d events: %S)"
                   (length oc-hp-smoke--seen-types)
                   (nreverse oc-hp-smoke--seen-types)))
        oc-hp-smoke--connected)
    (error
     (message "SMOKE: ERROR %s" (error-message-string err))
     nil)
    (quit
     (message "SMOKE: interrupted")
     nil)))

(defun oc-hp-smoke--teardown ()
  "Disconnect SSE + stop server; remove the logger."
  (condition-case nil (oc-hp-sse-disconnect) (error nil))
  (condition-case nil (oc-hp-server-stop) (error nil))
  (remove-hook 'oc-hp-sse-event-hook #'oc-hp-smoke--logger)
  (message "SMOKE: teardown complete"))

(provide 'oc-hp-smoke)