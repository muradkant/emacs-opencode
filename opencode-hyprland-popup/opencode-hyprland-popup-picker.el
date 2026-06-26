;;; opencode-hyprland-popup-picker.el --- Session picker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 6 of opencode-hyprland-popup: a sessions picker presented when
;; the user invokes `opencode-hyprland-popup-prompt' with a prefix arg
;; (brief §3.6).  Built on `completing-read' so it works under every
;; completion UI (plain / IDO / vertico / ivy / helm).  A
;; completion-metadata `:annotation-function' supplies
;; title/time-ago/message-count so vertico+marginalia users see them
;; richly; under plain IDO the annotations simply don't render (the
;; brief's expectation was "portable across all").  Decision §12.4 keeps
;; the metadata path; the user uses plain IDO today.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup-session)

(defgroup oc-hp-picker nil
  "Sessions picker for opencode-hyprland-popup."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-picker-")

(defcustom oc-hp-picker-new-candidate-label "*new session*"
  "Label placed first in the picker; choosing it creates a fresh session."
  :type 'string
  :group 'oc-hp-picker)

(defface oc-hp-picker-annotation-face
  '((t :inherit font-lock-comment-face))
  "Face for picker annotations (time-ago, msg count)."
  :group 'oc-hp-picker)

(defun oc-hp-picker-select (sessions &optional directory)
  "Let the user pick a session from SESSIONS (a list of session plists).
DIRECTORY is the project scope; used when the user picks the
`*new session*' candidate to create the new session in that scope.
Returns either:
  - a session plist (chosen existing), or
  - a freshly-created session plist (when the new-session candidate is picked),
  - nil (the user aborted with C-g / empty selection)."
  (let* ((candidates (oc-hp-picker--build-candidates sessions))
         (metadata (oc-hp-picker--metadata sessions))
         (choice
          (completing-read
           "OpenCode session: "
           (lambda (string pred action)
             (cond
              ((eq action 'metadata) metadata)
              (t (complete-with-action
                  action candidates string pred))))
           nil t)))
    (cond
     ((null choice) nil)
     ((string-empty-p choice) nil)
     ((string= choice oc-hp-picker-new-candidate-label)
      (oc-hp-session-create nil nil directory))
     (t (let ((session (get-text-property 0 'oc-hp-session choice)))
          (or session
              (cl-find-if
               (lambda (s) (equal (plist-get s :id) choice))
               sessions)))))))

(defun oc-hp-picker--build-candidates (sessions)
  "Return the candidate strings for SESSIONS, with the new-session entry first."
  (let ((new oc-hp-picker-new-candidate-label))
    (cons new
          (mapcar (lambda (s)
                    (propertize (or (oc-hp-session-title s)
                                    (plist-get s :id))
                                'oc-hp-session s))
                  sessions))))

(defvar oc-hp-picker--known-sessions nil
  "Bound to SESSIONS for the duration of a picker call, so the
annotation function can consult them.")

(defun oc-hp-picker--metadata (_sessions)
  "Return completion-metadata including the annotation function."
  (list :annotation-function
        (lambda (cand)
          (cond
           ((string= cand oc-hp-picker-new-candidate-label)
            (propertize "  start a fresh session (no prior context)"
                        'face 'oc-hp-picker-annotation-face))
           (t (let ((s (get-text-property 0 'oc-hp-session cand)))
                (when s
                  (let ((id (plist-get s :id))
                        (msg-count (oc-hp-picker--message-count s))
                        (time-ago (oc-hp-picker--time-ago s)))
                    (propertize
                     (format "  %s  ·  %s msgs  ·  %s"
                             id msg-count time-ago)
                     'face 'oc-hp-picker-annotation-face)))))))
        :category 'oc-hp-session))

(defun oc-hp-picker--message-count (session)
  "Return the number of messages in SESSION, or '-' if unknown.
OpenCode 1.17.11 doesn't expose a count on /session, so we return '-'
unless a count appears on the session plist (e.g. a richer future API)."
  (let ((n (or (plist-get session :messages)
               (plist-get session :messageCount)
               (plist-get session :message-count))))
    (cond
     ((null n) "-")
     ((numberp n) n)
     ((listp n) (length n))
     (t "-"))))

(defun oc-hp-picker--time-ago (session)
  "Return a human time-ago string for SESSION."
  (let ((then (oc-hp-session--updated-time session)))
    (cond
     ((null then) "—")
     (t
      (let* ((now (float-time))
             (delta (max 0 (- now then)))
             (sec (floor delta)))
        (cond
         ((< sec 60) "just now")
         ((< sec 3600) (format "%dm ago" (/ sec 60)))
         ((< sec 86400) (format "%dh ago" (/ sec 3600)))
         (t (format "%dd ago" (/ sec 86400)))))))))

(provide 'opencode-hyprland-popup-picker)
;;; opencode-hyprland-popup-picker.el ends here