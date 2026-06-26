;;; opencode-hyprland-popup-tests.el --- interactive + batch test harness for opencode-hyprland-popup  -*- lexical-binding: t; -*-

;; Test harness for opencode-hyprland-popup.el.  See ../../README.md for the full guide.
;;
;; BATCH (deterministic, no quota) — run from a terminal:
;;   emacs --batch -L <pkg-dir> -L <evil-dir> \
;;         -l tests/opencode-hyprland-popup-tests.el -f oc-hp-run-batch-tests
;; Bundled batch tests (same dir): oc-hp-smoke.el (Phases 1-3 transport),
;; oc-hp-phase9-test.el (Phase 9 FSM), oc-hp-phase10-test.el (Phase 10 pool).
;;
;; INTERACTIVE (needs your real Emacs + display + a little LLM quota).
;; Each command opens the popup and prints acceptance steps to *Messages*:
;;   M-x oc-hp-test-phase5-streaming    live three-phase display (Phase 5)
;;   M-x oc-hp-test-phase6-picker       C-u session picker (Phase 6)
;;   M-x oc-hp-test-phase7-permission   y-or-n-p in popup minibuffer (Phase 7)
;;   M-x oc-hp-test-phase8-revert       revert a buffer OpenCode wrote (Phase 8)
;;   M-x oc-hp-test-phase9-two-turn     two-turn [q2 a2] not stacked (Phase 9)

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup)

;; Directory of THIS file, captured at load time (load-file-name is only
;; bound during the load, so we can't consult it from -f commands later).
(defconst oc-hp-test-dir
  (file-name-directory (or load-file-name default-directory buffer-file-name "."))
  "Directory holding this harness and the bundled batch test .el files.")

(defun oc-hp-test--banner (lines)
  "Print LINES as a banner to *Messages*."
  (message "========================================================")
  (dolist (l lines) (message "%s" l))
  (message "========================================================"))

(defun oc-hp-run-batch-tests ()
  "Run the bundled batch tests (smoke + phase9 + phase10) and summarise."
  (interactive)
  (let ((dir oc-hp-test-dir))
    (dolist (base '("oc-hp-smoke" "oc-hp-phase9-test" "oc-hp-phase10-test"))
      (let ((f (expand-file-name (concat base ".el") dir)))
        (when (file-exists-p f) (load f nil t))))
    (message "----- batch: smoke (Phases 1-3) -----")
    (condition-case e (progn (oc-hp-smoke--run) (oc-hp-smoke--teardown))
      (error (message "smoke error: %s" (error-message-string e))))
    (message "----- batch: phase9 (follow-up FSM) -----")
    (oc-hp-phase9-run)
    (message "----- batch: phase10 (buffer pool) -----")
    (oc-hp-p10-run)
    (message "========================================================")
    (message "BATCH SUMMARY: see the RESULT: lines above for each suite.")
    (message "========================================================")))

(defun oc-hp-test-phase5-streaming ()
  "Phase 5: open the popup and walk the user through a live streaming turn."
  (interactive)
  (oc-hp-test--banner
   '("PHASE 5 — three-phase streaming display"
     "1. A floating popup frame opens (Hyprland floats it)."
     "2. Type a short prompt, e.g.:  list three Linux text editors"
     "3. Press :w  (evil write)."
     "ACCEPTANCE:"
     "  * Below your prompt a divider line appears."
     "  * Tool/reasoning/text deltas stream into the ephemeral region."
     "  * On turn end, the ephemeral region is replaced by the final answer."
     "  * Buffer now reads: [your prompt] / divider / [answer]."))
  (opencode-hyprland-popup-prompt))

(defun oc-hp-test-phase6-picker ()
  "Phase 6: invoke the session picker as if with C-u."
  (interactive)
  (oc-hp-test--banner
   '("PHASE 6 — session picker (prefix arg)"
     "A completing-read picker should appear with sessions for THIS project."
     "First candidate is '*new session*'.  Under vertico+marginalia you see"
     "annotations (id / msg count / time-ago); under plain IDO they are hidden."
     "Pick one (or new), then proceed as Phase 5."))
  (let ((current-prefix-arg '(4)))
    (opencode-hyprland-popup-prompt '(4))))

(defun oc-hp-test-phase7-permission ()
  "Phase 7: prompt a tool that hits an ask rule; expect a y-or-n-p."
  (interactive)
  (oc-hp-test--banner
   '("PHASE 7 — permission y-or-n-p in the popup's own minibuffer"
     "PREP: make OpenCode ASK for a tool. Easiest sandboxed way: in a"
     "THROWAWAY project dir create ./opencode.json with an ask rule, e.g.:"
     "  { \"permission\": { \"edit\": \"ask\", \"bash\": \"ask\" } }"
     "and `cd' there before invoking the popup so that dir is the scope."
     "(We do NOT modify OpenCode's real config — this is an isolated test sandbox.)"
     "1. Open the popup from that dir."
     "2. Type a prompt that makes OpenCode edit a file, e.g.:"
     "     create a file ./touched.txt with contents 'hi'"
     "3. Press :w."
     "ACCEPTANCE:"
     "  * A yes/no prompt appears IN THE POPUP FRAME's own minibuffer."
     "  * y -> approve once (turn proceeds); n -> reject (turn aborts)."
     "  * C-u y would approve always (persisting the rule)."))
  (opencode-hyprland-popup-prompt))

(defun oc-hp-test-phase8-revert ()
  "Phase 8: have OpenCode write a file you have open; expect the buffer to revert."
  (interactive)
  (oc-hp-test--banner
   '("PHASE 8 — revert buffers touched by OpenCode"
     "PREP: turn OFF global-auto-revert-mode for this test so the PACKAGE's"
     "explicit revert is what refreshes the buffer:  (global-auto-revert-mode 0)"
     "1. Visit a scratch file you will let OpenCode overwrite:"
     "     C-x C-f /tmp/oc-hp-revert-target.txt RET  (make it empty, save)."
     "2. Leave that buffer open. From here invoke the popup."
     "3. Prompt:  overwrite /tmp/oc-hp-revert-target.txt with the text 'updated'"
     "   (approve the permission ask if a Phase 7 sandbox is active)."
     "4. Wait for the turn to finish (session.status idle)."
     "ACCEPTANCE:"
     "  * Your /tmp/oc-hp-revert-target.txt buffer now shows 'updated' WITHOUT"
     "    you touching it, and *Messages* logs 'OpenCode reverted 1 buffer(s): ...'."
     "  * Re-enable global-auto-revert-mode afterwards:  (global-auto-revert-mode 1)"))
  (opencode-hyprland-popup-prompt))

(defun oc-hp-test-phase9-two-turn ()
  "Phase 9: two turns; after turn 2 the buffer must read [q2]/divider/[a2]."
  (interactive)
  (oc-hp-test--banner
   '("PHASE 9 — follow-up prompt wipe (was: stacking [q1 a1 q2 a2])"
     "1. Open the popup; type turn-1 prompt:  say hi in one short sentence"
     "   Press :w; wait for the answer (phase 2)."
     "2. BELOW the answer, type a follow-up:  now say it in French"
     "   Press :w."
     "ACCEPTANCE (the Phase 9 fix):"
     "  * Before the second :w the buffer was [q1 / divider / a1 / q2]."
     "  * On the second :w, ONLY q2 is sent (the prior answer is not re-sent)."
     "  * The buffer wipes to [q2 / divider]; after the second answer it reads"
     "    [q2 / divider / a2] — NOT the stacked [q1 a1 q2 a2]."
     "  * OpenCode's session still holds both turns server-side."))
  (opencode-hyprland-popup-prompt))

(provide 'opencode-hyprland-popup-tests)
;;; opencode-hyprland-popup-tests.el ends here
