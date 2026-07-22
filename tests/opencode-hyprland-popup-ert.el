;;; opencode-hyprland-popup-ert.el --- Contract regression tests  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'opencode-hyprland-popup)

(defmacro oc-hp-test--with-popup (session-id &rest body)
  "Evaluate BODY in a fresh streaming popup for SESSION-ID."
  (declare (indent 1))
  `(let ((buf (get-buffer-create (format "*opencode-prompt<%s>*" ,session-id))))
     (unwind-protect
         (with-current-buffer buf
           (opencode-hyprland-popup-mode)
           (let ((inhibit-read-only t)) (erase-buffer) (insert "prompt"))
           (setq-local oc-hp-popup-session-id ,session-id
                       oc-hp-popup-directory "/tmp"
                       oc-hp-popup-phase 0)
           (oc-hp-display--on-send)
           ,@body)
       (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest oc-hp-display-uses-value-equality-for-part-ids ()
  (oc-hp-test--with-popup "ses_equal"
    (let ((first-id (string ?p ?1))
          (delta-id (string ?p ?1)))
      (should-not (eq first-id delta-id))
      (oc-hp-display--on-part-updated
       (list :type "message.part.updated"
             :properties (list :sessionID "ses_equal"
                               :part (list :id first-id :type "text" :text ""))))
      (oc-hp-display--on-part-delta
       (list :type "message.part.delta"
             :properties (list :sessionID "ses_equal" :partID delta-id
                               :field "text" :delta "hello")))
      (should (equal (plist-get (car oc-hp-display--parts) :text) "hello"))
      (should (string-match-p "hello" (buffer-string))))))

(ert-deftest oc-hp-display-preserves-order-and-updates-tools-in-place ()
  (oc-hp-test--with-popup "ses_order"
    (dolist (part (list (list :id "a" :type "text" :text "one")
                        (list :id "b" :type "text" :text "two")
                        (list :id "tool" :type "tool" :tool "write"
                              :state (list :status "pending" :input nil))))
      (oc-hp-display--on-part-updated
       (list :type "message.part.updated"
             :properties (list :sessionID "ses_order" :part part))))
    (oc-hp-display--on-part-updated
     (list :type "message.part.updated"
           :properties
           (list :sessionID "ses_order"
                 :part (list :id "tool" :type "tool" :tool "write"
                             :state (list :status "completed"
                                          :input (list :filePath "x"))))))
    (should (equal (mapcar (lambda (part) (plist-get part :id))
                           oc-hp-display--parts)
                   '("a" "b" "tool")))
    (should (string-match-p "filePath=x" (buffer-string)))
    (oc-hp-display--finalize (current-buffer))
    (should (string-match-p "one\n\ntwo" (buffer-string)))))

(ert-deftest oc-hp-display-reports-session-errors ()
  (oc-hp-test--with-popup "ses_error"
    (oc-hp-display--handle-error
     (list :type "session.error"
           :properties (list :sessionID "ses_error"
                             :error (list :message "model unavailable"))))
    (oc-hp-display--handle-status
     (list :type "session.status"
           :properties (list :sessionID "ses_error"
                             :status (list :type "idle"))))
    (should (equal oc-hp-popup-phase 2))
    (should-not buffer-read-only)
    (should (string-match-p "OpenCode error: model unavailable"
                            (buffer-string)))))

(ert-deftest oc-hp-send-restores-buffer-after-request-failure ()
  (let ((buf (get-buffer-create "*opencode-prompt<ses_send_failure>*")))
    (unwind-protect
        (with-current-buffer buf
          (opencode-hyprland-popup-mode)
          (insert "retry me")
          (setq-local oc-hp-popup-session-id "ses_send_failure"
                      oc-hp-popup-directory "/tmp"
                      oc-hp-popup-phase 0)
          (cl-letf (((symbol-function 'oc-hp-popup--ensure-backend) #'ignore)
                    ((symbol-function 'oc-hp-session-prompt-async)
                     (lambda (&rest _) (error "injected failure"))))
            (oc-hp-popup-send))
          (should (equal (buffer-string) "retry me"))
          (should (equal oc-hp-popup-phase 0))
          (should-not buffer-read-only))
      (kill-buffer buf))))

(ert-deftest oc-hp-revert-is-per-session-and-preserves-unsaved-edits ()
  (let* ((dir (file-name-as-directory (make-temp-file "oc-hp-revert-" t)))
         (safe-file (expand-file-name "safe.txt" dir))
         (dirty-file (expand-file-name "dirty.txt" dir))
         safe-buf dirty-buf)
    (unwind-protect
        (progn
          (write-region "old" nil safe-file nil 'silent)
          (write-region "old" nil dirty-file nil 'silent)
          (setq safe-buf (find-file-noselect safe-file)
                dirty-buf (find-file-noselect dirty-file))
          (with-current-buffer dirty-buf (goto-char (point-max)) (insert " local"))
          (write-region "new" nil safe-file nil 'silent)
          (write-region "new" nil dirty-file nil 'silent)
          (clrhash oc-hp-revert--touched)
          (dolist (file (list safe-file dirty-file))
            (oc-hp-revert--on-part
             (list :type "message.part.updated" :directory dir
                   :properties
                   (list :sessionID "ses_files"
                         :part (list :sessionID "ses_files" :type "tool"
                                     :tool "write"
                                     :state (list :status "completed"
                                                  :input (list :filePath file)))))))
          (oc-hp-revert--on-status
           (list :type "session.status"
                 :properties (list :sessionID "ses_other"
                                   :status (list :type "idle"))))
          (should (equal (with-current-buffer safe-buf (buffer-string)) "old"))
          (oc-hp-revert--on-status
           (list :type "session.status"
                 :properties (list :sessionID "ses_files"
                                   :status (list :type "idle"))))
          (should (equal (with-current-buffer safe-buf (buffer-string)) "new"))
          (should (equal (with-current-buffer dirty-buf (buffer-string))
                         "old local")))
      (dolist (buf (list safe-buf dirty-buf))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest oc-hp-server-abnormal-exit-clears-port-and-restarts ()
  (let ((oc-hp-server--port 43210)
        (oc-hp-server--managed-p t)
        (oc-hp-server-auto-restart t)
        scheduled)
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'oc-hp-server--schedule-restart)
               (lambda () (setq scheduled t))))
      (oc-hp-server--process-sentinel 'fake "exited abnormally with code 1\n"))
    (should (eq oc-hp-server--status 'error))
    (should-not oc-hp-server--port)
    (should scheduled)))

(ert-deftest oc-hp-permission-offers-explicit-always-choice ()
  (let (reply)
    (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?a))
              ((symbol-function 'oc-hp-session-reply-permission)
               (lambda (sid rid answer directory)
                 (setq reply (list sid rid answer directory)))))
      (oc-hp-permission--raise-ask "ses" "perm" "edit" '("file") nil "/tmp"))
    (should (equal reply '("ses" "perm" "always" "/tmp")))))

(ert-deftest oc-hp-hyprland-selects-new-same-title-client ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'oc-hp-popup--hyprland-clients)
               (lambda ()
                 (setq calls (1+ calls))
                 (if (= calls 1)
                     (list (list :title "OpenCode Prompt" :address "0xold"))
                   (list (list :title "OpenCode Prompt" :address "0xold")
                         (list :title "OpenCode Prompt" :address "0xnew"))))))
      (should (equal (oc-hp-popup--hyprland-new-address
                      "OpenCode Prompt" '("0xold"))
                     "0xnew")))))

(ert-deftest oc-hp-session-percent-encodes-directory-header ()
  (let (captured)
    (cl-letf (((symbol-function 'oc-hp-server-url) (lambda (&rest _) "http://test"))
              ((symbol-function 'oc-hp-server-auth-headers) (lambda () nil))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (setq captured url-request-extra-headers)
                 (let ((buf (generate-new-buffer " *oc-hp-http-test*")))
                   (with-current-buffer buf
                     (insert "\n{}")
                     (setq-local url-http-end-of-headers 1
                                 url-http-response-status 200))
                   buf))))
      (oc-hp-session--request "GET" "/session" nil "/tmp/a b"))
    (should (equal (cdr (assoc "x-opencode-directory" captured))
                   "%2Ftmp%2Fa%20b"))))

(provide 'opencode-hyprland-popup-ert)
;;; opencode-hyprland-popup-ert.el ends here
