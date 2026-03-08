;;; madolt-log.el --- Commit log viewer for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Commit log viewer for madolt.  Displays commit history in a
;; navigable, section-based buffer.  Each commit is a collapsible
;; section; TAB shows --stat output inline, RET shows the full commit
;; with diff in a revision buffer.

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'magit-section)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-mode)

;; Forward declaration — madolt-diff provides the diff rendering
;; for revision buffers.
(declare-function madolt-diff--refresh-structured "madolt-diff" ())
(declare-function madolt-diff--insert-table-diff "madolt-diff" (table-data))

;;;; Faces

(defface madolt-log-date
  '((t :inherit shadow))
  "Face for dates in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-author
  '((t :foreground "cyan3"))
  "Face for author names in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-refs
  '((t :weight bold :foreground "green3"))
  "Face for ref annotations in the log buffer."
  :group 'madolt-faces)

;;;; Buffer-local variables

(defvar-local madolt-log--rev nil
  "The revision being shown in this log buffer.")

(defvar-local madolt-log--args nil
  "Additional arguments for dolt log in this buffer.")

(defvar-local madolt-log--limit 25
  "Number of commits to show in the log buffer.")

(defvar-local madolt-revision--hash nil
  "The commit hash being shown in a revision buffer.")

;;;; Transient menu

;;;###autoload (autoload 'madolt-log "madolt-log" nil t)
(transient-define-prefix madolt-log ()
  "Show log."
  ["Arguments"
   ("-n" "Limit count" "-n"
    :class transient-option
    :reader transient-read-number-N+)
   ("-s" "Show stat"   "--stat")
   ("-m" "Merges only" "--merges")]
  ["Log"
   ("l" "Current branch" madolt-log-current)
   ("o" "Other branch"   madolt-log-other)
   ("h" "HEAD"           madolt-log-head)])

;;;; Log commands

(defun madolt-log-current (&optional args)
  "Show log for the current branch.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-log)))
  (madolt-log--show (madolt-current-branch) args))

(defun madolt-log-other (branch &optional args)
  "Show log for BRANCH.
ARGS are additional arguments from the transient."
  (interactive
   (list (completing-read "Branch: " (madolt--branch-names))
         (transient-args 'madolt-log)))
  (madolt-log--show branch args))

(defun madolt-log-head (&optional args)
  "Show log for HEAD.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-log)))
  (madolt-log--show "HEAD" args))

;;;; Log display

(defun madolt-log--show (rev args)
  "Show log for REV with ARGS in a log buffer."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (limit (madolt-log--extract-limit args))
         (buf-name (madolt--buffer-name 'madolt-log-mode db-dir))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-log-mode)
        (madolt-log-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-log--rev rev)
      (setq madolt-log--args args)
      (setq madolt-log--limit (or limit 25))
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

(defun madolt-log--extract-limit (args)
  "Extract the -n limit value from ARGS.
Return nil if not found."
  (cl-loop for arg in args
           when (string-match "^-n\\([0-9]+\\)$" arg)
           return (string-to-number (match-string 1 arg))
           when (string-match "^-n$" arg)
           ;; Next arg is the number — not easily extractable here,
           ;; transient usually folds them: "-n25"
           return nil))

;;;; Refresh

(defun madolt-log--filter-log-args (args)
  "Return ARGS with the -n limit removed.
The limit is handled separately via `madolt-log--limit'."
  (let ((result nil)
        (skip-next nil))
    (dolist (arg args)
      (cond
       (skip-next (setq skip-next nil))
       ((string-match "^-n[0-9]+$" arg)) ; -n25 form — skip
       ((string= arg "-n") (setq skip-next t)) ; -n 25 form — skip both
       (t (push arg result))))
    (nreverse result)))

(defun madolt-log-refresh-buffer ()
  "Refresh the log buffer by inserting commit sections."
  (let ((entries (madolt-log-entries
                  madolt-log--limit
                  madolt-log--rev
                  (madolt-log--filter-log-args madolt-log--args))))
    (magit-insert-section (log)
      (magit-insert-heading
        (propertize (format "Commits on %s:" (or madolt-log--rev "HEAD"))
                    'font-lock-face 'magit-section-heading))
      (if (null entries)
          (insert (propertize "  (no commits)\n" 'font-lock-face 'shadow))
        (dolist (entry entries)
          (madolt-log--insert-commit-section entry)))
      (insert "\n"))))

(defun madolt-log--insert-commit-section (entry)
  "Insert a commit section for ENTRY.
ENTRY is a plist with keys :hash :refs :date :author :message."
  (let* ((hash (plist-get entry :hash))
         (refs (plist-get entry :refs))
         (date (plist-get entry :date))
         (author (plist-get entry :author))
         (message (plist-get entry :message))
         (short-hash (substring hash 0 (min 8 (length hash)))))
    (magit-insert-section (commit hash t)
      (magit-insert-heading
        (concat
         (propertize short-hash 'font-lock-face 'madolt-hash)
         (if refs
             (concat " " (propertize (format "(%s)" refs)
                                     'font-lock-face 'madolt-log-refs))
           "")
         "  "
         (propertize (or (madolt-log--format-date date) "")
                     'font-lock-face 'madolt-log-date)
         "  "
         (propertize (or (madolt-log--short-author author) "")
                     'font-lock-face 'madolt-log-author)
         "  "
         (or message "")
         "\n"))
      ;; Washer for TAB expansion: show --stat
      (magit-insert-section-body
        (madolt-log--insert-commit-stat hash)))))

(defun madolt-log--format-date (date-string)
  "Format DATE-STRING for the log display.
Extract just the date portion (YYYY-MM-DD) if possible."
  (if (and date-string (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" date-string))
      (match-string 1 date-string)
    ;; Try to extract from dolt's date format: "Mon Jan 02 15:04:05 -0700 2006"
    (if (and date-string
             (string-match "\\([A-Z][a-z]\\{2\\}\\) \\([A-Z][a-z]\\{2\\}\\) \\([0-9]+\\) .* \\([0-9]\\{4\\}\\)" date-string))
        (format "%s-%s-%s"
                (match-string 4 date-string)
                (match-string 2 date-string)
                (match-string 3 date-string))
      date-string)))

(defun madolt-log--short-author (author)
  "Return a shortened version of AUTHOR.
Strip email address if present."
  (if (and author (string-match "\\(.*?\\)\\s-*<" author))
      (string-trim (match-string 1 author))
    author))

;;;; Commit stat expansion

(defun madolt-log--insert-commit-stat (hash)
  "Insert --stat output for commit HASH."
  (let* ((parent-hash (madolt-log--parent-hash hash))
         (stat (if parent-hash
                   (madolt-diff-stat parent-hash hash)
                 ;; First commit — diff against empty
                 (madolt-diff-stat hash))))
    (if (and stat (not (string-empty-p (string-trim stat))))
        (progn
          (dolist (line (split-string stat "\n" t))
            (insert "    " line "\n")))
      (insert "    (no stat available)\n"))))

(defun madolt-log--parent-hash (hash)
  "Return the parent commit hash of HASH, or nil if none."
  (let* ((result (madolt--run "log" "--oneline" "--parents" "-n" "1" hash))
         (output (and (zerop (car result))
                      (madolt--strip-ansi (cdr result))))
         (line (and output (car (split-string output "\n" t)))))
    ;; Format: "HASH PARENT_HASH (refs) message" or "HASH (refs) message"
    ;; The hash is 32 chars; parent (if present) is next 32 chars
    (when (and line (> (length line) 33))
      (let ((rest (substring line 33)))
        (when (string-match "^\\([a-z0-9]\\{32\\}\\)" rest)
          (match-string 1 rest))))))

;;;; Show commit (RET handler)

(defun madolt-show-commit (hash)
  "Show commit HASH in a revision buffer."
  (interactive
   (list (oref (magit-current-section) value)))
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (format "*madolt-revision: %s %s*"
                           (file-name-nondirectory
                            (directory-file-name db-dir))
                           (substring hash 0 (min 8 (length hash)))))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-revision-mode)
        (madolt-revision-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-revision--hash hash)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

;;;; Revision mode

(define-derived-mode madolt-revision-mode madolt-diff-mode "Madolt Rev"
  "Mode for showing a single commit's details and diff.")

(defun madolt-revision-refresh-buffer ()
  "Refresh the revision buffer."
  (let* ((hash madolt-revision--hash)
         (entry (madolt-log--find-entry hash))
         (parent (madolt-log--parent-hash hash)))
    (magit-insert-section (revision)
      ;; Commit metadata
      (insert (propertize "commit " 'font-lock-face 'bold)
              (propertize hash 'font-lock-face 'madolt-hash))
      (when-let ((refs (and entry (plist-get entry :refs))))
        (insert " " (propertize (format "(%s)" refs)
                                'font-lock-face 'madolt-log-refs)))
      (insert "\n")
      (when entry
        (insert (propertize "Author: " 'font-lock-face 'bold)
                (propertize (or (plist-get entry :author) "unknown")
                            'font-lock-face 'madolt-log-author)
                "\n")
        (insert (propertize "Date:   " 'font-lock-face 'bold)
                (propertize (or (plist-get entry :date) "unknown")
                            'font-lock-face 'madolt-log-date)
                "\n\n")
        (insert "    " (or (plist-get entry :message) "") "\n\n"))
      ;; Diff
      (let* ((diff-args (if parent
                            (list parent hash)
                          (list hash)))
             (json (apply #'madolt-diff-json diff-args))
             (tables (and json (alist-get 'tables json))))
        (if tables
            (dolist (tbl tables)
              (madolt-diff--insert-table-diff tbl))
          (insert (propertize "(no changes)\n"
                              'font-lock-face 'shadow)))))))

(defun madolt-log--find-entry (hash)
  "Find and return the log entry plist for HASH.
Queries dolt log directly for HASH so it works regardless of
which branch the commit belongs to."
  (car (madolt-log-entries 1 hash)))

;;;; Branch name completion

(defun madolt--branch-names ()
  "Return a list of branch names in the current database."
  (let ((lines (madolt-dolt-lines "branch")))
    (mapcar (lambda (line)
              (string-trim (replace-regexp-in-string "^\\*\\s-*" "" line)))
            lines)))

(provide 'madolt-log)
;;; madolt-log.el ends here
