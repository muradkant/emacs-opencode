;;; opencode-hyprland-popup-session.el --- OpenCode session HTTP API  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 3 of opencode-hyprland-popup: thin synchronous HTTP wrappers
;; over the OpenCode server's session endpoints, plus the per-request
;; project-directory resolution that scopes sessions.
;;
;; Endpoints used (brief §4):
;;   GET    /session                       — list sessions
;;   POST   /session                       — create session
;;   GET    /session/:id                   — session info
;;   GET    /session/:id/message           — message history
;;   POST   /session/:id/prompt_async      — fire-and-forget prompt (204)
;;   POST   /session/:id/permissions/:pid — reply to a permission ask (Ph 7)
;;   GET    /config/providers              — configured providers + models
;;
;; Sessions are scoped to a project directory.  OpenCode's native scope is
;; the git worktree root (brief §3.6 / §4); per-request override is the
;; `x-opencode-directory' HTTP header.  We resolve the directory once when
;; a popup is invoked (from the source buffer's location) via
;; `oc-hp-session-find-directory' and thread it through every request, so
;; a single long-lived server can serve multiple projects (decision §12.1:
;; the user git-inits each project dir, making worktree-root scope correct).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'json)
(require 'opencode-hyprland-popup-server)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)            ; bound in url-http response buffers

(defgroup oc-hp-session nil
  "OpenCode session HTTP API for opencode-hyprland-popup."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-session-")

(defcustom oc-hp-session-directory nil
  "If non-nil, force this directory as the OpenCode project scope.
When nil (default), the scope is resolved per invocation from the
calling buffer's location via `git rev-parse --show-toplevel' (the
OpenCode-native rule).  Set this only if you want all popups to share
one fixed project regardless of where they're invoked."
  :type '(choice (const :tag "Auto (git worktree root)" nil)
                 (directory :tag "Fixed directory"))
  :group 'oc-hp-session)

;;; --- Directory resolution ---

(defun oc-hp-session-find-directory (&optional dir)
  "Return the OpenCode project directory for DIR (or `default-directory').
Resolution order:
  1. `oc-hp-session-directory' if non-nil;
  2. `git rev-parse --show-toplevel' of DIR if it's inside a git repo;
  3. DIR itself (no git) — same as OpenCode's fallback when not in a repo."
  (let ((dir (expand-file-name (or dir default-directory))))
    (cond
     (oc-hp-session-directory (expand-file-name oc-hp-session-directory))
     ((oc-hp-session--git-toplevel dir))
     (t (directory-file-name dir)))))

(defun oc-hp-session--git-toplevel (dir)
  "Return the git worktree root containing DIR, or nil.
Uses a dedicated temp buffer for `call-process' output rather than
`with-output-to-string' + an inner `let ((standard-output (current-buffer)))'
— that latter pattern returns nil on Emacs 30 (the inner `let' rebinds
standard-output to the *current* buffer, but `with-output-to-string' has
already switched to a fresh output buffer, so `call-process' writes to the
wrong place and we capture nothing).  Verified live by reproducing three
variants; only the dedicated-buffer form returns the toplevel correctly."
  (let ((default-directory dir))
    (condition-case _err
        (let* ((buf (generate-new-buffer " *oc-hp-git*"))
               (status (call-process "git" nil buf nil
                                      "rev-parse" "--show-toplevel"))
               (out (with-current-buffer buf
                      (string-trim
                       (buffer-substring-no-properties
                        (point-min) (point-max))))))
          (kill-buffer buf)
          (when (and (equal status 0) (not (string-empty-p out)))
            out))
      (error nil))))

;;; --- Sync HTTP core ---

(defun oc-hp-session--request (method path &optional body directory)
  "Perform METHOD on PATH of the OpenCode server; return the parsed body.
BODY is a plist to be JSON-encoded as the request body (or nil).
DIRECTORY is the project scope, sent as the `x-opencode-directory' header
when non-nil.  Returns the parsed plist response, or the raw string if not
JSON.  Signals on HTTP/network error."
  (let* ((url (concat (oc-hp-server-url) path))
         (headers (append (oc-hp-server-auth-headers)
                          (when directory
                            `(("x-opencode-directory" . ,directory))))))
    (when body
      (setq headers (cons '("Content-Type" . "application/json") headers)))
    (let* ((url-request-method method)
           (url-request-extra-headers headers)
           (url-request-data
            (and body (oc-hp-session--json-encode body)))
           (buf (url-retrieve-synchronously url t nil 10)))
      (unless buf (error "HTTP %s %s: no response" method path))
      (unwind-protect
          (with-current-buffer buf
            (goto-char url-http-end-of-headers)
            (let ((status (/ (or url-http-response-status 0) 100)))
              (unless (or (= status 2) (= status 3))
                (let ((err-body (buffer-substring-no-properties
                                 (point) (point-max))))
                  (error "HTTP %s %s: status %d body=%s"
                         method path url-http-response-status
                         (substring err-body 0 (min 400 (length err-body)))))))
            (let ((body (buffer-substring-no-properties (point) (point-max))))
              (if (string-empty-p (string-trim body))
                  nil
                (oc-hp-session--json-parse body))))
        (kill-buffer buf)))))

(defun oc-hp-session--json-encode (obj)
  "Encode OBJ (a plist, possibly nested with plists inside lists) to JSON.
Uses alists internally because `json-encode' mis-detects nested plists
inside arrays — `((:type \"text\" :text \"hi\"))' would be encoded as
an OBJECT rather than an ARRAY of objects (verified live against
OpenCode 1.17.11 — prompt_async returned 400 with
`Expected array, got {\"type\":[\"text\",\"text\",...]}`)."
  (encode-coding-string
   (let ((json-object-type 'alist)
         (json-array-type  'list)
         (json-key-type    'symbol))
     (json-encode (oc-hp-session--plist->alist obj)))
   'utf-8))

(defun oc-hp-session--plist->alist (obj)
  "Recursively convert OBJ's plists to alists (keys become symbols).
Atoms and alists are preserved.  Lists whose elements are plists or
objects have each element converted."
  (cond
   ((and (consp obj) (keywordp (car obj)))
    ;; a plist — convert to alist
    (let (out)
      (while (and (consp obj) (keywordp (car obj)))
        (push (cons (intern (substring (symbol-name (car obj)) 1))
                    (oc-hp-session--plist->alist (cadr obj)))
              out)
        (setq obj (cddr obj)))
      (nreverse out)))
   ((consp obj)
    (mapcar #'oc-hp-session--plist->alist obj))
   (t obj)))

(defun oc-hp-session--json-parse (string)
  "Parse STRING into a plist; fall back to the raw string if not JSON."
  (let ((json-object-type 'plist)
        (json-array-type  'list)
        (json-key-type    'keyword)
        (json-null        nil))
    (condition-case _err
        (json-read-from-string string)
      (error string))))

;;; --- Session CRUD ---

(defun oc-hp-session-list (&optional directory)
  "List sessions scoped to DIRECTORY.  Returns a list of session plists."
  (let ((dir (or directory (oc-hp-session-find-directory))))
    (or (oc-hp-session--request "GET" "/session" nil dir)
        '())))

(defun oc-hp-session-get (session-id &optional directory)
  "Fetch one session by SESSION-ID."
  (oc-hp-session--request "GET" (format "/session/%s" session-id)
                          nil directory))

(defun oc-hp-session-create (&optional title parent-id directory model)
  "Create a new session with optional TITLE, PARENT-ID, DIRECTORY, and MODEL.
MODEL may be a string of the form \"provider/model\" or a plist with
`:providerID' and `:id' keys.
Returns the created session plist."
  (let ((body '()))
    (when title (setq body (plist-put body :title title)))
    (when parent-id (setq body (plist-put body :parentID parent-id)))
    (when model (setq body (plist-put body :model
                                      (oc-hp-session--model-spec model))))
    (oc-hp-session--request "POST" "/session" body directory)))

(defun oc-hp-session--model-spec (model)
  "Return MODEL as an OpenCode session-create model plist."
  (cond
   ((and (consp model)
         (plist-get model :providerID)
         (or (plist-get model :id)
             (plist-get model :modelID)))
    (list :providerID (plist-get model :providerID)
          :id (or (plist-get model :id)
                  (plist-get model :modelID))))
   ((stringp model)
    (if (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" model)
        (list :providerID (match-string 1 model)
              :id (match-string 2 model))
      (list :id model)))
   (t (error "Unsupported OpenCode model spec: %S" model))))

(defun oc-hp-session--prompt-model-spec (model)
  "Return MODEL as an OpenCode prompt model plist."
  (cond
   ((and (consp model)
         (plist-get model :providerID)
         (or (plist-get model :modelID)
             (plist-get model :id)))
    (list :providerID (plist-get model :providerID)
          :modelID (or (plist-get model :modelID)
                       (plist-get model :id))))
   ((stringp model)
    (if (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" model)
        (list :providerID (match-string 1 model)
              :modelID (match-string 2 model))
      (error "Prompt model must be provider/model: %S" model)))
   (t (error "Unsupported OpenCode prompt model spec: %S" model))))

(defun oc-hp-session-config-providers (&optional directory)
  "Return configured OpenCode providers for DIRECTORY."
  (plist-get (oc-hp-session--request "GET" "/config/providers" nil directory)
             :providers))

(defun oc-hp-session-models (&optional directory)
  "Return configured OpenCode models for DIRECTORY as a list of plists.
This uses OpenCode's own provider/config API, so custom providers and
machine-local credentials are reflected without hardcoding model names."
  (let ((providers (oc-hp-session-config-providers directory))
        models)
    (dolist (provider providers)
      (let ((provider-id (plist-get provider :id))
            (provider-name (plist-get provider :name))
            (entries (plist-get provider :models)))
        (while (consp entries)
          (let ((model (copy-sequence (cadr entries))))
            (setq model (plist-put model :providerID
                                   (or (plist-get model :providerID)
                                       provider-id)))
            (setq model (plist-put model :modelID
                                   (or (plist-get model :modelID)
                                       (plist-get model :id)
                                       (substring (symbol-name (car entries)) 1))))
            (setq model (plist-put model :id
                                   (or (plist-get model :id)
                                       (plist-get model :modelID))))
            (setq model (plist-put model :providerName provider-name))
            (push model models))
          (setq entries (cddr entries)))))
    (sort models
          (lambda (a b)
            (let ((pa (plist-get a :providerID))
                  (pb (plist-get b :providerID)))
              (cond
               ((and (string-prefix-p "opencode" pa)
                     (not (string-prefix-p "opencode" pb))) t)
               ((and (not (string-prefix-p "opencode" pa))
                     (string-prefix-p "opencode" pb)) nil)
               ((not (string= pa pb)) (string< pa pb))
               (t (string< (oc-hp-session-model-key a)
                           (oc-hp-session-model-key b)))))))))

(defun oc-hp-session-model-key (model)
  "Return MODEL as provider/model."
  (format "%s/%s"
          (plist-get model :providerID)
          (or (plist-get model :modelID)
              (plist-get model :id))))

(defun oc-hp-session-messages (session-id &optional directory)
  "Fetch the message history for SESSION-ID.  Returns a list of message plists."
  (or (oc-hp-session--request "GET"
                              (format "/session/%s/message" session-id)
                              nil directory)
      '()))

(defun oc-hp-session-prompt-async (session-id prompt &optional directory model variant)
  "Send PROMPT (a string) to SESSION-ID as a new turn via `prompt_async'.
Body shape verified against OpenCode v1.17.11 source:
`{parts:[{type:\"text\", text:<prompt>}]}' (RESEARCH §13.1).
Returns non-nil on 204.  No body returned."
  (let ((body (list :parts (list (list :type "text" :text prompt)))))
    (when model
      (setq body (plist-put body :model
                            (oc-hp-session--prompt-model-spec model))))
    (when variant
      (setq body (plist-put body :variant variant)))
    (oc-hp-session--request "POST"
                            (format "/session/%s/prompt_async" session-id)
                            body
                            directory))
  t)

(defun oc-hp-session-abort (session-id &optional directory)
  "Abort the active prompt in SESSION-ID."
  (oc-hp-session--request "POST"
                          (format "/session/%s/abort" session-id)
                          nil directory))

(defun oc-hp-session-reply-permission (session-id permission-id response
                                      &optional directory)
  "Reply to a permission ask: RESPONSE for PERMISSION-ID in SESSION-ID.
RESPONSE is one of the strings `once', `always', `reject' (the
PermissionV1.Reply literals — RESEARCH §13.2).  Phase 7 calls this after
a `y-or-n-p' in the popup's minibuffer, defaulting `once' on yes and
`reject' on no."
  (oc-hp-session--request "POST"
                          (format "/session/%s/permissions/%s"
                                  session-id permission-id)
                          (list :response response)
                          directory)
  t)

;;; --- Session helpers ---

(defun oc-hp-session-most-recent (sessions)
  "Return the most-recently-updated session of SESSIONS, or nil."
  (cl-reduce
   (lambda (a b)
     (let ((ta (oc-hp-session--updated-time a))
           (tb (oc-hp-session--updated-time b)))
       (if (and ta (or (null tb) (time-less-p tb ta))) a b)))
   sessions
   :initial-value nil))

(defun oc-hp-session--updated-time (session)
  "Return the updated time of SESSION as seconds since epoch (float), or nil.
Handles OpenCode's `time.updated' shapes observed live in 1.17.11:
epoch *milliseconds* (a large number), epoch seconds, or an ISO-8601 string."
  (let* ((time (plist-get session :time))
         (updated (or (and time (plist-get time :updated))
                      (plist-get session :updatedAt)
                      (plist-get session :updated))))
    (cond
     ((null updated) nil)
     ((numberp updated)
      ;; heuristic: > year 2001 in ms => milliseconds
      (if (> updated 1000000000000) (/ updated 1000.0) (float updated)))
     ((stringp updated)
      (condition-case nil
          (float-time (encode-time (parse-time-string updated)))
        (error nil)))
     (t nil))))

(defun oc-hp-session-title (session)
  "Return SESSION's title, falling back to its id."
  (or (plist-get session :title)
      (plist-get session :slug)
      (plist-get session :id)
      "(untitled)"))

(defun oc-hp-session--status-type (status-event)
  "From a `session.status' event plist, return status.type (a string) or nil."
  (let ((status (plist-get (plist-get status-event :properties) :status)))
    (and (listp status) (plist-get status :type))))

(defun oc-hp-session--touched-files-from-step-ended (step-event)
  "Return the list of touched relative paths from a `session.next.step.ended'.
Per RESEARCH §13.4: the event's `properties.files' is the
server-authoritative list of files changed during the step.  Returns nil
if no files were touched."
  (let ((props (plist-get step-event :properties)))
    (append (plist-get props :files) nil)))

(provide 'opencode-hyprland-popup-session)
;;; opencode-hyprland-popup-session.el ends here
