;;; oc-hp-phase10-test.el --- unit test for Phase 10 buffer pool  -*- lexical-binding: t; -*-

;; Verifies (no server, no quota):
;;   * oc-hp-popup--ensure-buffer reuses the SAME live buffer for a given
;;     session-id across calls (re-open is instant — brief §3.9).
;;   * Distinct session-ids get DISTINCT buffers that coexist in the pool
;;     (so a picker swap leaves the original session's buffer
;;     buried-but-alive, ready to re-open).
;;   * oc-hp-popup-quit buries (not kills) — the buffer stays in the pool.
;;   * C-c o session choice: no project sessions -> create immediately;
;;     existing project sessions -> ask via picker; prefix -> force new.
;;   * Existing-session picker choices survive stripped text properties.
;;   * Model picker choices survive stripped text properties.
;;   * Cold-opening an existing session hydrates the latest prompt/answer.
;;   * The package-owned global mode binds C-c o / C-c h.

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup)

(defvar oc-hp-p10--res nil)
(defun oc-hp-p10--ok (label got want)
  (let ((pass (equal got want)))
    (push (format "[%s] %s" (if pass "PASS" "FAIL") label) oc-hp-p10--res)
    (unless pass (push (format "    got=%S want=%S" got want) oc-hp-p10--res))
    pass))

(defun oc-hp-p10--test-session-and-model-choice ()
  "Check the C-c o session/model choice policy without touching a real server."
  (let ((picker-called nil)
        listed)
    (cl-letf (((symbol-function 'oc-hp-popup--ensure-backend)
               #'ignore)
              ((symbol-function 'oc-hp-session-list)
               (lambda (_dir)
                 (setq listed t)
                 nil))
              ((symbol-function 'oc-hp-picker-select)
               (lambda (&rest _)
                 (setq picker-called t)
                 (list :id "ses_should_not_pick"))))
      (oc-hp-p10--ok "choice: empty project requests new session"
                     (oc-hp-popup--choose-session "/tmp") '(:new t))
      (oc-hp-p10--ok "choice: empty project skips picker"
                     picker-called nil)
      (oc-hp-p10--ok "choice: empty project lists sessions"
                     listed t)))
  (let (picker-sessions)
    (cl-letf (((symbol-function 'oc-hp-popup--ensure-backend)
               #'ignore)
              ((symbol-function 'oc-hp-session-list)
               (lambda (_dir)
                 (list (list :id "ses_existing"))))
              ((symbol-function 'oc-hp-picker-select)
               (lambda (sessions _dir)
                 (setq picker-sessions sessions)
                 (car sessions))))
      (oc-hp-p10--ok "choice: existing project uses picker"
                     (plist-get (oc-hp-popup--choose-session "/tmp") :id)
                     "ses_existing")
      (oc-hp-p10--ok "choice: picker receives project sessions"
                     (mapcar (lambda (s) (plist-get s :id)) picker-sessions)
                     '("ses_existing"))))
  (let* ((target (list :id "ses_target" :title "Repeated title"))
         (sessions (list (list :id "ses_other" :title "Repeated title")
                         target))
         (choice (substring-no-properties
                  (oc-hp-picker--candidate-label target))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) choice)))
      (oc-hp-p10--ok "picker: propertyless existing choice resolves by id"
                     (oc-hp-picker-select sessions "/tmp")
                     target)))
  (let (listed picker-called)
    (cl-letf (((symbol-function 'oc-hp-popup--ensure-backend)
               #'ignore)
              ((symbol-function 'oc-hp-session-list)
               (lambda (&rest _)
                 (setq listed t)
                 nil))
              ((symbol-function 'oc-hp-picker-select)
               (lambda (&rest _)
                 (setq picker-called t)
                 nil)))
      (oc-hp-p10--ok "choice: prefix requests new session"
                     (oc-hp-popup--choose-session "/tmp" t) '(:new t))
      (oc-hp-p10--ok "choice: prefix skips session list"
                     listed nil)
      (oc-hp-p10--ok "choice: prefix skips picker"
                     picker-called nil)))
  (let* ((model (list :providerID "opencode" :modelID "mimo-v2.5-free"
                      :id "mimo-v2.5-free" :name "MiMo V2.5 Free"))
         (choice (substring-no-properties
                  (oc-hp-picker--model-candidate-label model))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) choice)))
      (oc-hp-p10--ok "model picker: propertyless choice resolves by key"
                     (oc-hp-picker-select-model (list model))
                     model)))
  (let* ((model (list :providerID "opencode" :modelID "mimo-v2.5-free"
                      :id "mimo-v2.5-free"))
         captured-model)
    (cl-letf (((symbol-function 'oc-hp-session-create)
               (lambda (_title _parent _dir model-arg)
                 (setq captured-model model-arg)
                 (list :id "ses_new"))))
      (oc-hp-p10--ok "choice: new session created after model selection"
                     (oc-hp-popup--session-id-for-selection
                      "/tmp" '(:new t) model)
                     "ses_new")
      (oc-hp-p10--ok "choice: selected model used for create"
                     captured-model model)))
  (let (captured-body)
    (cl-letf (((symbol-function 'oc-hp-session--request)
               (lambda (_method _path body _dir)
                 (setq captured-body body)
                 nil)))
      (oc-hp-session-prompt-async
       "ses_model" "hello" "/tmp"
       (list :providerID "opencode" :modelID "mimo-v2.5-free"))
      (oc-hp-p10--ok "prompt_async: selected model included"
                     (plist-get captured-body :model)
                     '(:providerID "opencode" :modelID "mimo-v2.5-free")))))

(defun oc-hp-p10--test-history-hydration ()
  "Check cold existing-session buffers render the latest OpenCode turn."
  (let* ((messages
          (list
           (list :info (list :id "msg_user_1" :role "user")
                 :parts (list (list :type "text" :text "old prompt")))
           (list :info (list :id "msg_assistant_1" :role "assistant"
                             :parentID "msg_user_1")
                 :parts (list (list :type "text" :text "old answer")))
           (list :info (list :id "msg_user_2" :role "user")
                 :parts (list (list :type "text"
                                    :text (concat "old prompt\n\n"
                                                  oc-hp-display-divider
                                                  "\nold answer\n\n\n"
                                                  "latest prompt"))))
           (list :info (list :id "msg_assistant_2" :role "assistant"
                             :parentID "msg_user_2")
                 :parts (list (list :type "reasoning" :text "hidden")
                              (list :type "text" :text "latest answer")))))
         (turn (oc-hp-popup--last-turn messages)))
    (oc-hp-p10--ok "hydrate: latest prompt selected"
                   (plist-get turn :prompt)
                   "latest prompt")
    (oc-hp-p10--ok "hydrate: latest assistant answer selected"
                   (plist-get turn :answer)
                   "latest answer")
    (let ((buf (get-buffer-create "*opencode-prompt<ses_hydrate>*")))
      (unwind-protect
          (with-current-buffer buf
            (opencode-hyprland-popup-mode)
            (erase-buffer)
            (setq-local oc-hp-popup-session-id "ses_hydrate"
                        oc-hp-popup-directory "/tmp"
                        oc-hp-popup-phase 0)
            (cl-letf (((symbol-function 'oc-hp-session-messages)
                       (lambda (_sid _dir) messages)))
              (oc-hp-p10--ok "hydrate: renders history"
                             (oc-hp-popup--hydrate-buffer "ses_hydrate" "/tmp")
                             t))
            (oc-hp-p10--ok "hydrate: phase is answer-placed"
                           oc-hp-popup-phase 2)
            (oc-hp-p10--ok "hydrate: buffer has prompt and answer"
                           (and (string-match-p "latest prompt" (buffer-string))
                                (string-match-p "latest answer" (buffer-string))
                                t)
                           t))
        (kill-buffer buf)))))

(defun oc-hp-p10--test-keymaps ()
  "Check package-owned keymaps without relying on user init."
  (let ((opencode-hyprland-popup-global-mode nil))
    (opencode-hyprland-popup-global-mode 1)
    (unwind-protect
        (progn
          (oc-hp-p10--ok "global mode: C-c o opens prompt"
                         (key-binding (kbd "C-c o"))
                         #'opencode-hyprland-popup-prompt)
          (oc-hp-p10--ok "global mode: C-c h toggles frame"
                         (key-binding (kbd "C-c h"))
                         #'opencode-hyprland-popup-toggle-frame))
      (opencode-hyprland-popup-global-mode -1)))
  (oc-hp-p10--ok "popup mode: C-c h toggles frame"
                 (lookup-key opencode-hyprland-popup-mode-map (kbd "C-c h"))
                 #'opencode-hyprland-popup-toggle-frame))

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
                            t) t)))
    (oc-hp-p10--test-session-and-model-choice)
    (oc-hp-p10--test-history-hydration)
    (oc-hp-p10--test-keymaps))
  (let ((lines (nreverse oc-hp-p10--res)))
    (dolist (l lines) (message "P10 %s" l))
    (let ((fails (seq-filter (lambda (s) (string-prefix-p "[FAIL]" s)) lines)))
      (message "P10 RESULT: %d checks, %s" (length lines)
               (if fails (format "%d FAILED" (length fails)) "ALL PASS")))))

(provide 'oc-hp-phase10-test)
