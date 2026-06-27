;;; oc-hp-session-safety-test.el --- regression test: directory resolution must not mutate the caller's buffer  -*- lexical-binding: t; -*-

;; Regression guard for the "project path injected at cursor on C-c o" bug.
;;
;; Root cause (fixed in c8ccbb3): oc-hp-session--git-toplevel ran
;;   (call-process "git" nil t nil "rev-parse" "--show-toplevel")
;; where the destination `t' means "the CURRENT BUFFER". So git's stdout —
;; the absolute project path — was written straight into whatever buffer the
;; user was editing, exactly at point, the moment C-c o resolved the project.
;; (The visible symptom: the project directory appeared at the cursor.)
;;
;; The fix routes output to a dedicated temp buffer instead. This test pins
;; that contract: resolving the directory must NEVER change the text of the
;; calling buffer, no matter what default-directory it runs under. It needs
;; no server and no LLM quota — the dangerous call is on the open path, well
;; before any network activity.
;;
;; Note on the "reloaded but didn't take" trap: under native-comp, a stale
;; .eln in eln-cache shadows the fixed .el/.elc, so the bug can persist in a
;; long-lived daemon even after the source is corrected. This test will FAIL
;; in such a daemon (it runs the live loaded definition), making the shadow
;; obvious instead of silent.

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'opencode-hyprland-popup-session)

(defvar oc-hp-session-safety--res nil)

(defun oc-hp-session-safety--ok (label got want)
  (let ((pass (equal got want)))
    (push (format "[%s] %s" (if pass "PASS" "FAIL") label)
          oc-hp-session-safety--res)
    (unless pass
      (push (format "    got=%S want=%S" got want) oc-hp-session-safety--res))
    pass))

(defun oc-hp-session-safety--summarise ()
  "Print the collected results and a one-line RESULT summary."
  (let ((lines (nreverse oc-hp-session-safety--res)))
    (dolist (l lines) (message "SAFETY %s" l))
    (let ((fails (seq-filter
                  (lambda (s) (string-prefix-p "[FAIL]" s)) lines)))
      (message "SAFETY RESULT: %d checks, %s"
               (length lines)
               (if fails (format "%d FAILED" (length fails))
                 "ALL PASS")))))

(defun oc-hp-session-safety--check-visiting-buffer (proj want-text)
  "Scenario 1: resolve from a buffer VISITING a file in PROJ.
The C-c o path. The buffer's text must be unchanged afterward."
  (let ((tmp (expand-file-name "oc-safety-source.txt" proj))
        buf)
    (unwind-protect
        (progn
          (with-temp-file tmp (insert want-text))
          (setq buf (find-file-noselect tmp))
          (with-current-buffer buf
            ;; sit at the middle line — the historical injection point
            (goto-char (point-min))
            (forward-line 1)
            (let ((pt-before (point))
                  (resolved  (oc-hp-session-find-directory)))
              (oc-hp-session-safety--ok
               "resolved to project root" resolved proj)
              (oc-hp-session-safety--ok
               "visiting buffer text unchanged by resolution"
               (buffer-string) want-text)
              (oc-hp-session-safety--ok
               "point unchanged by resolution" (point) pt-before))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-exists-p tmp) (delete-file tmp))))
  nil)

(defun oc-hp-session-safety--check-scratch-buffer (proj want-text)
  "Scenario 2: resolve from a NON-file buffer with default-directory PROJ."
  (let ((buf (get-buffer-create "*oc-safety-scratch*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert want-text)
          (let ((default-directory proj)
                (pt-before (progn (goto-char (point-min))
                                  (forward-line 1) (point))))
            (oc-hp-session-find-directory)
            (oc-hp-session-safety--ok
             "scratch buffer text unchanged by resolution"
             (buffer-string) want-text)
            (oc-hp-session-safety--ok
             "scratch point unchanged by resolution" (point) pt-before)))
      (when (buffer-live-p buf) (kill-buffer buf))))
  nil)

;;;###autoload
(defun oc-hp-session-safety-run ()
  "Run the directory-resolution safety regression tests."
  (setq oc-hp-session-safety--res nil)
  (let ((want-text "AAA\nBBB\nCCC\n"))
    ;; Guard: this test only means something inside a git repo (otherwise
    ;; git-toplevel isn't on the code path). Skip with a clear note if not.
    (if (not (oc-hp-session--git-toplevel default-directory))
        (progn
          (message "SAFETY SKIPPED: not inside a git repo (run from the project root)")
          (message "SAFETY RESULT: skipped"))
      (let ((proj (oc-hp-session-find-directory)))
        (oc-hp-session-safety--check-visiting-buffer proj want-text)
        (oc-hp-session-safety--check-scratch-buffer proj want-text)
        (oc-hp-session-safety--summarise))))
  nil)

(provide 'oc-hp-session-safety-test)
;;; oc-hp-session-safety-test.el ends here
