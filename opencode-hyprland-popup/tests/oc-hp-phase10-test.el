;;; oc-hp-phase10-test.el --- unit test for Phase 10 buffer pool  -*- lexical-binding: t; -*-

;; Verifies (no server, no quota):
;;   * oc-hp-popup--ensure-buffer reuses the SAME live buffer for a given
;;     session-id across calls (re-open is instant — brief §3.9).
;;   * Distinct session-ids get DISTINCT buffers that coexist in the pool
;;     (so a prefix-arg picker swap leaves the original session's buffer
;;     buried-but-alive, ready to re-open).
;;   * oc-hp-popup-quit buries (not kills) — the buffer stays in the pool.

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup)

(defvar oc-hp-p10--res nil)
(defun oc-hp-p10--ok (label got want)
  (let ((pass (equal got want)))
    (push (format "[%s] %s" (if pass "PASS" "FAIL") label) oc-hp-p10--res)
    (unless pass (push (format "    got=%S want=%S" got want) oc-hp-p10--res))
    pass))

(defun oc-hp-p10-run ()
  (setq oc-hp-p10--res nil)
  (let ((dir "/tmp"))
    (let* ((b1a (oc-hp-popup--ensure-buffer "ses_A" dir))
           (b1b (oc-hp-popup--ensure-buffer "ses_A" dir)))   ; reuse
      (oc-hp-p10--ok "reuse same session-id -> eq buffer" (eq b1a b1b) t))
    (let* ((ba (oc-hp-popup--ensure-buffer "ses_B" dir))
           (bb (oc-hp-popup--ensure-buffer "ses_C" dir)))
      (oc-hp-p10--ok "distinct ids -> distinct buffers" (eq ba bb) nil)
      (oc-hp-p10--ok "ses_B buffer alive in pool"
                     (buffer-live-p (get-buffer "*opencode-prompt<ses_B>*")) t)
      (oc-hp-p10--ok "ses_C buffer alive in pool"
                     (buffer-live-p (get-buffer "*opencode-prompt<ses_C>*")) t))
    (let ((bd (oc-hp-popup--ensure-buffer "ses_D" dir)))
      (with-current-buffer bd (oc-hp-popup-quit))
      (oc-hp-p10--ok "quit buries (buffer still live)"
                     (buffer-live-p (get-buffer "*opencode-prompt<ses_D>*")) t))
    (let* ((be1 (oc-hp-popup--ensure-buffer "ses_E" dir)))
      (with-current-buffer be1
        (insert "preserved state")
        (oc-hp-popup-quit))
      (let ((be2 (oc-hp-popup--ensure-buffer "ses_E" dir)))
        (oc-hp-p10--ok "re-open reuses buried buffer" (eq be1 be2) t)
        (oc-hp-p10--ok "preserved content survives bury/quit"
                       (and (with-current-buffer be2
                              (string-match-p "preserved state" (buffer-string)))
                            t) t))))
  (let ((lines (nreverse oc-hp-p10--res)))
    (dolist (l lines) (message "P10 %s" l))
    (let ((fails (seq-filter (lambda (s) (string-prefix-p "[FAIL]" s)) lines)))
      (message "P10 RESULT: %d checks, %s" (length lines)
               (if fails (format "%d FAILED" (length fails)) "ALL PASS")))))

(provide 'oc-hp-phase10-test)