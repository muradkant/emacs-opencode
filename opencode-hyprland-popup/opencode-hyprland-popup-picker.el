;;; opencode-hyprland-popup-picker.el --- Session picker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 6 of opencode-hyprland-popup: a sessions picker presented when
;; the current OpenCode project already has sessions.  Built on
;; `completing-read' so it works under every completion UI (plain / IDO /
;; vertico / ivy / helm).  A
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
  "Label placed first in the picker; choosing it requests a fresh session."
  :type 'string
  :group 'oc-hp-picker)

(defface oc-hp-picker-annotation-face
  '((t :inherit font-lock-comment-face))
  "Face for picker annotations (time-ago, msg count)."
  :group 'oc-hp-picker)

(defun oc-hp-picker-select (sessions &optional directory)
  "Let the user pick a session from SESSIONS (a list of session plists).
DIRECTORY is accepted for API symmetry with older callers.
Returns either:
  - a session plist (chosen existing), or
  - `(:new t)' when the new-session candidate is picked,
  - nil (the user aborted with C-g / empty selection)."
  (ignore directory)
  (let* ((candidates (oc-hp-picker--build-candidates sessions))
         (metadata (oc-hp-picker--metadata sessions))
         (choice
          (completing-read
           "OpenCode session: "
           (oc-hp-picker--completion-table candidates metadata)
           nil t)))
    (cond
     ((null choice) nil)
     ((string-empty-p choice) nil)
     ((string= choice oc-hp-picker-new-candidate-label)
      (list :new t))
     (t (let ((session (get-text-property 0 'oc-hp-session choice))
              (id (oc-hp-picker--session-id-from-choice choice)))
          (or session
              (cl-find-if
               (lambda (s)
                 (equal (plist-get s :id) id))
               sessions)))))))

(defun oc-hp-picker--build-candidates (sessions)
  "Return the candidate strings for SESSIONS, with the new-session entry first."
  (let ((new oc-hp-picker-new-candidate-label))
    (cons new
          (mapcar (lambda (s)
                    (propertize (oc-hp-picker--candidate-label s)
                                'oc-hp-session s))
                  sessions))))

(defun oc-hp-picker--candidate-label (session)
  "Return the stable, unique completion label for SESSION."
  (let ((id (plist-get session :id)))
    (if id
        (format "%s  (%s)" (oc-hp-session-title session) id)
      (oc-hp-session-title session))))

(defun oc-hp-picker--session-id-from-choice (choice)
  "Return the OpenCode session id encoded in CHOICE, or CHOICE itself."
  (cond
   ((and (stringp choice)
         (string-match "(\\(ses_[^)]+\\))\\'" choice))
    (match-string 1 choice))
   (t choice)))

(defun oc-hp-picker--completion-table (candidates metadata)
  "Return a substring-friendly completion table for CANDIDATES."
  (lambda (string pred action)
    (cond
     ((eq action 'metadata) metadata)
     ((eq action 'lambda) (member string candidates))
     ((eq action t)
      (let ((matches (oc-hp-picker--matching-candidates candidates string pred)))
        (all-completions "" matches pred)))
     (t
      (let ((matches (oc-hp-picker--matching-candidates candidates string pred)))
        (cond
         ((null matches) nil)
         ((= (length matches) 1) (car matches))
         (t string)))))))

(defun oc-hp-picker--matching-candidates (candidates string pred)
  "Return CANDIDATES matching STRING by substring.
The active completion UI still controls presentation; this table supplies
already-filtered candidates so typing narrows by provider/model/name."
  (let ((needle (downcase (or string ""))))
    (cl-remove-if-not
     (lambda (candidate)
       (and (or (null pred) (funcall pred candidate))
            (or (string-empty-p needle)
                (string-match-p (regexp-quote needle)
                                (downcase candidate)))))
     candidates)))

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

(defun oc-hp-picker-select-model (models &optional default-model)
  "Let the user pick one model from MODELS.
MODELS is a list of model plists from `oc-hp-session-models'.  Returns a
model plist, or nil if the user aborts."
  (let* ((candidates (oc-hp-picker--build-model-candidates models))
         (metadata (oc-hp-picker--model-metadata))
         (default-label (and default-model
                             (oc-hp-picker--model-label-for-key
                              candidates
                              (oc-hp-picker--model-key default-model))))
         (choice
          (completing-read
           "OpenCode model: "
           (oc-hp-picker--completion-table candidates metadata)
           nil t nil nil default-label)))
    (cond
     ((null choice) nil)
     ((string-empty-p choice) nil)
     (t (let ((model (get-text-property 0 'oc-hp-model choice))
              (key (oc-hp-picker--model-key-from-choice choice)))
          (or model
              (cl-find-if
               (lambda (m)
                 (equal (oc-hp-picker--model-key m) key))
               models)))))))

(defun oc-hp-picker--build-model-candidates (models)
  "Return completion candidates for MODELS."
  (mapcar (lambda (model)
            (propertize (oc-hp-picker--model-candidate-label model)
                        'oc-hp-model model))
          models))

(defun oc-hp-picker--model-candidate-label (model)
  "Return the stable, searchable completion label for MODEL."
  (let ((key (oc-hp-picker--model-key model))
        (name (plist-get model :name)))
    (if (and name (not (string= name key)))
        (format "%s  -  %s" key name)
      key)))

(defun oc-hp-picker--model-key (model)
  "Return MODEL's provider/model key."
  (cond
   ((stringp model) model)
   ((consp model)
    (format "%s/%s"
            (plist-get model :providerID)
            (or (plist-get model :modelID)
                (plist-get model :id))))
   (t "")))

(defun oc-hp-picker--model-key-from-choice (choice)
  "Return provider/model encoded at the start of CHOICE."
  (cond
   ((and (stringp choice)
         (string-match "\\`\\([^[:space:]]+/[^[:space:]]+\\)" choice))
    (match-string 1 choice))
   (t choice)))

(defun oc-hp-picker--model-label-for-key (candidates key)
  "Return the candidate in CANDIDATES whose model key is KEY."
  (cl-find-if (lambda (candidate)
                (equal (oc-hp-picker--model-key-from-choice candidate)
                       key))
              candidates))

(defun oc-hp-picker--model-metadata ()
  "Return completion metadata for model candidates."
  (list :annotation-function
        (lambda (cand)
          (let ((model (get-text-property 0 'oc-hp-model cand)))
            (when model
              (let ((provider (plist-get model :providerName))
                    (context (plist-get (plist-get model :limit) :context))
                    (output (plist-get (plist-get model :limit) :output))
                    (cost (plist-get model :cost)))
                (propertize
                 (format "  %s%s%s"
                         (or provider "")
                         (if context
                             (format "  ·  ctx %s" context)
                           "")
                         (if (and cost
                                  (equal (plist-get cost :input) 0)
                                  (equal (plist-get cost :output) 0))
                             "  ·  free"
                           (if output (format "  ·  out %s" output) "")))
                 'face 'oc-hp-picker-annotation-face)))))
        :category 'oc-hp-model))

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
