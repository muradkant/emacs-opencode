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
  "Return the git worktree root containing DIR, or nil."
  (let ((default-directory dir))
    (condition-case _err
        (let ((out (string-trim
                    (with-output-to-string
                      (let ((standard-output (current-buffer)))
                        (call-process "git" nil t nil
                                      "rev-parse" "--show-toplevel"))))))
          (unless (string-empty-p out) out))
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
            (let ((status (/ url-http-response-status 100)))
              (unless (or (= status 2) (= status 3))
                (error "HTTP %s %s: status %d"
                       method path url-http-response-status)))
            (let ((body (buffer-substring-no-properties (point) (point-max))))
              (if (string-empty-p (string-trim body))
                  nil
                (oc-hp-session--json-parse body))))
        (kill-buffer buf)))))

(defun oc-hp-session--json-encode (obj)
  "Encode OBJ to JSON as a UTF-8 string."
  (let ((json-object-type 'plist)
        (json-array-type  'list)
        (json-key-type    'keyword))
    (encode-coding-string (json-encode obj) 'utf-8)))

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

(defun oc-hp-session-create (&optional title parent-id directory)
  "Create a new session with optional TITLE and PARENT-ID, in DIRECTORY.
Returns the created session plist."
  (let ((body '()))
    (when title (setq body (plist-put body :title title)))
    (when parent-id (setq body (plist-put body :parentID parent-id)))
    (oc-hp-session--request "POST" "/session" body directory)))

(defun oc-hp-session-messages (session-id &optional directory)
  "Fetch the message history for SESSION-ID.  Returns a list of message plists."
  (or (oc-hp-session--request "GET"
                              (format "/session/%s/message" session-id)
                              nil directory)
      '()))

(defun oc-hp-session-prompt-async (session-id prompt &optional directory)
  "Send PROMPT to SESSION-ID via `prompt_async' (fire-and-forget, 204).
Returns non-nil on a successful response (no body expected)."
  (oc-hp-session--request "POST"
                          (format "/session/%s/prompt_async" session-id)
                          (list :prompt prompt) directory)
  t)

(defun oc-hp-session-abort (session-id &optional directory)
  "Abort the active prompt in SESSION-ID."
  (oc-hp-session--request "POST"
                          (format "/session/%s/abort" session-id)
                          nil directory))

(defun oc-hp-session-reply-permission (session-id permission-id allow
                                      &optional directory)
  "Reply to a permission ask: ALLOW (bool) for PERMISSION-ID in SESSION-ID.
Phase 7 calls this after a `y-or-n-p' in the popup's minibuffer."
  (oc-hp-session--request "POST"
                          (format "/session/%s/permissions/%s"
                                  session-id permission-id)
                          (list :allow (if allow t :json-false))
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
  "Return the updated time of SESSION as an Emacs time value, or nil."
  (let* ((time (plist-get session :time))
         (updated (or (and time (plist-get time :updated))
                      (plist-get session :updatedAt)
                      (plist-get session :updated))))
    (and updated (encode-time (parse-time-string updated)))))

(defun oc-hp-session-title (session)
  "Return SESSION's title, falling back to its id."
  (or (plist-get session :title)
      (plist-get session :slug)
      (plist-get session :id)
      "(untitled)"))

(provide 'opencode-hyprland-popup-session)
;;; opencode-hyprland-popup-session.el ends here