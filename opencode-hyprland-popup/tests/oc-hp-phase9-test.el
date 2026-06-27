;;; oc-hp-phase9-test.el --- Unit test for Phase 9 follow-up wipe logic  -*- lexical-binding: t; -*-

;; Exercises ONLY the deterministic parts of Phase 9 (no server, no quota):
;;   * oc-hp-display--finalize sets oc-hp-popup-answer-end at the end of the
;;     finalized answer region.
;;   * oc-hp-popup--current-prompt-text in phase 2 returns ONLY the text
;;     typed after that marker (prompt2), trimmed.
;;   * The simulated oc-hp-popup-send follow-up path wipes the buffer to
;;     [prompt2] before re-opening the divider.
;;
;; Run:  emacs --batch -L /tmp/ocpkg -L <evil> -l <this-file> -f oc-hp-phase9-run

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup)            ; pulls display + the rest

(defvar oc-hp-phase9--results nil)
(defun oc-hp-phase9--ok (label got want)
  (let ((pass (equal got want)))
    (push (format "[%s] %s" (if pass "PASS" "FAIL") label) oc-hp-phase9--results)
    (unless pass
      (push (format "    got=%S want=%S" got want) oc-hp-phase9--results))
    pass))

(defun oc-hp-phase9--simulate-turn1 ()
  "Simulate Phase 5 finalizing after the user sent prompt1."
  ;; Stand up a popup buffer WITHOUT a frame (batch-safe).
  (let ((buf (get-buffer-create "*opencode-prompt<ses_test>*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'opencode-hyprland-popup-mode)
        (opencode-hyprland-popup-mode))
      (setq-local oc-hp-popup-session-id "ses_test"
                  oc-hp-popup-directory "/tmp"
                  oc-hp-popup-phase 0)
      (erase-buffer)
      (insert "What is 1+1?")
      ;; Mimic oc-hp-display--on-send (divider + ephemeral region open).
      (oc-hp-display--on-send)
      ;; Simulate the streamed "text" part arriving.
      (let ((part (list :type "text" :id "p1" :text "2")))
        (oc-hp-display--on-part-updated
         (list :type "message.part.updated"
               :properties (list :sessionID "ses_test" :part part :time 0))))
      ;; Mimic session.status idle -> finalize.
      (oc-hp-display--handle-status
       (list :type "session.status"
             :properties (list :sessionID "ses_test"
                               :status (list :type "idle"))))))
  (let ((buf (get-buffer "*opencode-prompt<ses_test>*")))
    (with-current-buffer buf
      (let ((endp (and (markerp oc-hp-popup-answer-end)
                       (marker-position oc-hp-popup-answer-end))))
        (oc-hp-phase9--ok "T1: phase == 2 after idle" oc-hp-popup-phase 2)
        (oc-hp-phase9--ok "T1: answer-end marker set" (and endp t) t)
        (oc-hp-phase9--ok "T1: answer present in buffer"
                          (and (string-match-p "2" (buffer-string)) t) t)))))

(defun oc-hp-phase9--test-follow-up-extraction ()
  "User types prompt2 below the finished answer; current-prompt-text = prompt2."
  (let ((buf (get-buffer "*opencode-prompt<ses_test>*")))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "now multiply that by 3")        ; this is prompt2
      (let ((got (oc-hp-popup--current-prompt-text)))
        (oc-hp-phase9--ok "T2: follow-up extracts only prompt2"
                          got "now multiply that by 3")))
    ;; Now simulate the Phase 9 wipe-to-[prompt2] the send path performs.
    (with-current-buffer buf
      (let* ((follow-up-p (eq oc-hp-popup-phase 2))
             (prompt (string-trim-right (oc-hp-popup--current-prompt-text))))
        (oc-hp-phase9--ok "T3: follow-up-p flagged" follow-up-p t)
        (when follow-up-p
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert prompt)
            (setq-local oc-hp-popup-phase 0)))
        (oc-hp-phase9--ok "T3: buffer wiped to [prompt2]"
                          (buffer-string) "now multiply that by 3")
        (oc-hp-phase9--ok "T3: phase reset to 0" oc-hp-popup-phase 0)))))

(defun oc-hp-phase9--test-first-turn-whole-buffer ()
  "First turn (phase 0): current-prompt-text = whole buffer."
  (let ((buf (get-buffer-create "*opencode-prompt<ses_first>*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'opencode-hyprland-popup-mode)
        (opencode-hyprland-popup-mode))
      (setq-local oc-hp-popup-session-id "ses_first"
                  oc-hp-popup-directory "/tmp"
                  oc-hp-popup-phase 0)
      (erase-buffer)
      (insert "hello world")
      (let ((got (oc-hp-popup--current-prompt-text)))
        (oc-hp-phase9--ok "T4: first turn returns whole buffer"
                          got "hello world")))))

(defun oc-hp-phase9--test-phase1-guard ()
  "phase 1 (streaming) must refuse send; current-prompt-text = whole buffer."
  (let ((buf (get-buffer-create "*opencode-prompt<ses_busy>*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'opencode-hyprland-popup-mode)
        (opencode-hyprland-popup-mode))
      (setq-local oc-hp-popup-session-id "ses_busy"
                  oc-hp-popup-directory "/tmp"
                  oc-hp-popup-phase 1)
      (erase-buffer)
      (insert "queued text")
      ;; Guard fires before any HTTP / send side effects.
      (let ((refused
             (condition-case _err
                 (oc-hp-popup-send)
               (user-error t)
               (error nil))))
        (oc-hp-phase9--ok "T5: phase 1 send refused" refused t)))))

(defun oc-hp-phase9--test-user-parts-not-rendered ()
  "The display must not render the submitted user prompt as assistant text."
  (let ((buf (get-buffer-create "*opencode-prompt<ses_role>*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'opencode-hyprland-popup-mode)
        (opencode-hyprland-popup-mode))
      (setq-local oc-hp-popup-session-id "ses_role"
                  oc-hp-popup-directory "/tmp"
                  oc-hp-popup-phase 0)
      (erase-buffer)
      (insert "What model is this?")
      (clrhash oc-hp-display--message-role-by-id)
      (cl-letf (((symbol-function 'oc-hp-session-messages)
                 (lambda (&rest _)
                   (list
                    (list :info (list :id "msg_user" :role "user"))
                    (list :info (list :id "msg_assistant"
                                      :role "assistant"))))))
        (oc-hp-display--on-send)
        (oc-hp-display--on-part-updated
         (list :type "message.part.updated"
               :properties
               (list :sessionID "ses_role"
                     :part (list :id "prt_user"
                                 :messageID "msg_user"
                                 :sessionID "ses_role"
                                 :type "text"
                                 :text "What model is this?"))))
        (oc-hp-phase9--ok "T6: user text part ignored"
                          oc-hp-display--text-by-part nil)
        (oc-hp-phase9--ok "T6: no prompt echo under assistant divider"
                          (string-match-p
                           "What model is this?"
                           (buffer-substring-no-properties
                            oc-hp-display--eph-start (point-max)))
                          nil)
        (oc-hp-display--on-part-updated
         (list :type "message.part.updated"
               :properties
               (list :sessionID "ses_role"
                     :part (list :id "prt_assistant"
                                 :messageID "msg_assistant"
                                 :sessionID "ses_role"
                                 :type "text"
                                 :text "Real answer"))))
        (oc-hp-phase9--ok "T6: assistant text part rendered"
                          (and (string-match-p "Real answer" (buffer-string))
                               t)
                          t)))))

(defun oc-hp-phase9-run ()
  "Run the Phase 9 unit tests and print the summary."
  (setq oc-hp-phase9--results nil)
  ;; display handlers install themselves on the SSE hooks globally; harmless
  ;; here since no SSE process runs.
  (oc-hp-phase9--simulate-turn1)
  (oc-hp-phase9--test-follow-up-extraction)
  (oc-hp-phase9--test-first-turn-whole-buffer)
  (oc-hp-phase9--test-phase1-guard)
  (oc-hp-phase9--test-user-parts-not-rendered)
  (let ((lines (nreverse oc-hp-phase9--results)))
    (dolist (l lines) (message "PHASE9 %s" l))
    (let ((fails (seq-filter (lambda (s) (string-prefix-p "[FAIL]" s)) lines)))
      (message "PHASE9 RESULT: %d checks, %s" (length lines)
               (if fails (format "%d FAILED" (length fails)) "ALL PASS")))))

(provide 'oc-hp-phase9-test)
