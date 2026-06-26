;;; opencode-hyprland-popup-revert.el --- Revert buffers touched by OpenCode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 muradkant
;; SPDX-License-Identifier: MIT

;; Author: muradkant
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Phase 8 of opencode-hyprland-popup.  When OpenCode's write/edit/patch
;; or bash tools modify files on disk, Emacs buffers visiting those
;; files won't auto-refresh unless `global-auto-revert-mode' is on (which
;; we recommend — RESEARCH §6 decision §12.5).
;;
;; We collect candidate file paths from `tool' parts as they stream in
;; (part.type == "tool", part.tool in {write,edit,apply_patch,read,
;; str_replace,bash,...}, paths pulled from part.input), and after the
;; turn finalizes (session.status idle) we revert every live buffer
;; whose `buffer-file-name' matches a touched path.
;;
;; This is defensive: if `global-auto-revert-mode' is on, the explicit
;; revert is a harmless no-op (the file's already current); if it's off,
;; this is the only way the user sees the change without a manual revert.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-hyprland-popup-sse)
(require 'opencode-hyprland-popup-display)

(defgroup oc-hp-revert nil
  "Revert buffers touched by OpenCode."
  :group 'opencode-hyprland-popup
  :prefix "oc-hp-revert-")

(defcustom oc-hp-revert-mode t
  "When non-nil, revert buffers visiting files touched by OpenCode after each turn."
  :type 'boolean
  :group 'oc-hp-revert)

(defcustom oc-hp-revert-tool-allowlist
  '("write" "edit" "apply_patch" "str_replace" "str_replace_editor"
    "read" "bash" "multi_edit" "patch" "remove")
  "Tool names (lowercase strings) whose `input' paths we harvest for revert.
Default is broad; trim if you only care about mutating tools."
  :type '(repeat string)
  :group 'oc-hp-revert)

(defcustom oc-hp-revert-bash-grep-paths t
  "When non-nil, also scan bash command strings for paths in the working dir.
Heuristic — bash tools pass a command, not a file path.  Off by default
would skip bash (safer for noisy commands)."
  :type 'boolean
  :group 'oc-hp-revert)

(defvar oc-hp-revert--touched (make-hash-table :test 'equal)
  "Per-process hash of touched absolute file paths (value=t).")
(defvar oc-hp-revert--handlers-attached nil)

(defun oc-hp-revert-attach ()
  "Register Phase 8's SSE handlers (idempotent)."
  (unless oc-hp-revert--handlers-attached
    (add-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-revert--on-part)
    (add-hook 'oc-hp-sse-session-status-hook #'oc-hp-revert--on-status)
    (setq oc-hp-revert--handlers-attached t)))

(defun oc-hp-revert-detach ()
  "Unregister (used by tests / unload)."
  (remove-hook 'oc-hp-sse-message-part-updated-hook #'oc-hp-revert--on-part)
  (remove-hook 'oc-hp-sse-session-status-hook #'oc-hp-revert--on-status)
  (setq oc-hp-revert--handlers-attached nil))

(defun oc-hp-revert--on-part (event)
  "Harvest touched paths from a `tool' part in EVENT."
  (when oc-hp-revert-mode
    (let* ((props (plist-get event :properties))
           (part (plist-get props :part)))
      (when (and (listp part)
                 (equal (plist-get part :type) "tool"))
        (let ((tool (plist-get part :tool))
              (input (plist-get part :input))
              (directory (plist-get (plist-get event :directory)
                                    :directory)))  ; envelope's directory
          (when (member tool oc-hp-revert-tool-allowlist)
            (dolist (path (oc-hp-revert--extract-paths tool input directory))
              (puthash path t oc-hp-revert--touched))))))))

(defun oc-hp-revert--extract-paths (tool input directory)
  "Return a list of absolute file paths OpenCode touched via TOOL with INPUT.
DIRECTORY is the project root; used to resolve relative paths."
  (let ((dir (or directory default-directory))
        (paths nil))
    (cl-labels
        ((abs (p)
              (when (and (stringp p) (not (string-empty-p p)))
                (expand-file-name p dir)))
         (add (p) (let ((a (abs p))) (when a (push a paths)))))
      (pcase tool
        ((or "write" "edit" "multi_edit" "patch" "remove" "apply_patch"
             "str_replace" "str_replace_editor")
         (let ((fp (or (plist-get input :filePath)
                       (plist-get input :file_path)
                       (plist-get input :path)
                       (plist-get input :file))))
           (when fp (add fp)))
         (let ((fpaths (or (plist-get input :filePaths)
                           (plist-get input :files))))
           (when (listp fpaths)
             (dolist (f fpaths) (add (if (listp f) (or (plist-get f :path) (plist-get f :filePath)) f))))))
        ("read" (let ((fp (or (plist-get input :filePath)
                              (plist-get input :path))))
                  (when fp (add fp))))
        ("bash"
         (when oc-hp-revert-bash-grep-paths
           (let ((cmd (or (plist-get input :command)
                          (plist-get input :cmd))))
             (when (stringp cmd)
               (dolist (m (oc-hp-revert--shell-looks-like-file cmd))
                 (add m))))))
        (_ nil)))
    (delete-dups paths)))

(defun oc-hp-revert--shell-looks-like-file (cmd)
  "Heuristic: extract plausible file path tokens from shell command string CMD.
Catches obvious `cat foo.txt', `sed -i ... file', `> file', `>> file', etc.
Conservative — false positives are harmless (revert no-ops), false negatives
mean a file isn't auto-reverted (user can revert manually)."
  (let (out)
    ;; redirect targets
    (when (string-match "\\(?:>>?\\|1?>>\\|2>>\\)\\s-*\\([^;&| \t\n]+\\)" cmd)
      (push (match-string 1 cmd) out))
    (dolist (tok (split-string cmd "[ \t\n;&|]+" t))
      (let ((trimmed (string-trim tok "\"'`")))
        (when (and (not (string-empty-p trimmed))
                   (string-match-p "\\." trimmed)
                   (not (string-match-p "\\`-" trimmed))
                   (file-exists-p (expand-file-name trimmed default-directory)))
          (push trimmed out))))
    (delete-dups out)))

(defun oc-hp-revert--on-status (event)
  "When the turn goes idle, revert visiting buffers for touched files."
  (when oc-hp-revert-mode
    (let* ((props (plist-get event :properties))
           (status (plist-get props :status))
           (type (and (listp status) (plist-get status :type))))
      (when (equal type "idle")
        (oc-hp-revert--flush)))))

(defun oc-hp-revert--flush ()
  "Revert every live buffer visiting a path in `oc-hp-revert--touched'.
Clears the hash after flushing."
  (when (> (hash-table-count oc-hp-revert--touched) 0)
    (let (reverted-files)
      (dolist (buf (buffer-list))
        (when (buffer-live-p buf)
          (let* ((file (buffer-file-name buf))
                 (abs (and file (expand-file-name file))))
            (when (and abs (gethash abs oc-hp-revert--touched))
              (with-current-buffer buf
                (if (fboundp 'revert-buffer-quick)
                    (revert-buffer-quick :ignore-auto)
                  (let ((autosave? (buffer-modified-p)))
                    (revert-buffer :ignore-auto (not autosave?) :preserve-modes)))
                (push abs reverted-files))))))      ; close with-current-buffer, when-abs, let*, when-buffer-live, dolist
      (clrhash oc-hp-revert--touched)
      (when reverted-files
        (message "OpenCode reverted %d buffer(s): %s"
                 (length reverted-files)
                 (mapconcat #'identity reverted-files ", "))))))

(provide 'opencode-hyprland-popup-revert)
;;; opencode-hyprland-popup-revert.el ends here