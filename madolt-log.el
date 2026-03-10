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

;; Forward declarations — madolt-diff provides the diff rendering
;; for revision buffers; madolt-reflog provides reflog commands.
(declare-function madolt-diff--refresh-structured "madolt-diff" ())
(declare-function madolt-diff--insert-table-diff "madolt-diff" (table-data))
(declare-function madolt-reflog-current "madolt-reflog" ())
(declare-function madolt-reflog-other "madolt-reflog" (ref))

;;;; Faces

(defface madolt-log-date
  '((((class color) (background light))
     :foreground "grey30" :slant normal :weight normal)
    (((class color) (background dark))
     :foreground "grey80" :slant normal :weight normal))
  "Face for dates in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-author
  '((((class color) (background light))
     :foreground "firebrick" :slant normal :weight normal)
    (((class color) (background dark))
     :foreground "tomato" :slant normal :weight normal))
  "Face for author names in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-refs
  '((t :weight bold :foreground "green3"))
  "Face for ref annotations in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-graph
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background dark))  :foreground "grey80"))
  "Face for the graph part of the log output.
Inherits styling from `magit-log-graph'."
  :group 'madolt-faces)

;;;; Margin configuration

(defcustom madolt-log-margin-width 36
  "Width of the right margin in log buffers.
Includes space for author name and date."
  :group 'madolt
  :type 'integer)

(defcustom madolt-log-author-width 16
  "Maximum width for author names in the log margin.
Names longer than this are truncated with an ellipsis."
  :group 'madolt
  :type 'integer)

;; Set up right margin when log mode buffers are displayed.
(add-hook 'madolt-log-mode-hook
          (lambda ()
            (add-hook 'window-configuration-change-hook
                      #'madolt-log--set-window-margins nil t)))

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
   ("-m" "Merges only" "--merges")
   ("-g" "Graph"       "--graph")]
  ["Log"
   ("l" "Current branch" madolt-log-current)
   ("o" "Other branch"   madolt-log-other)
   ("h" "HEAD"           madolt-log-head)
   ("a" "All branches"   madolt-log-all)]
  ["Reflog"
   ("O" "Current branch" madolt-reflog-current)
   ("p" "Other ref"      madolt-reflog-other)])

;;;; Row limit expansion

(defun madolt-log-double-limit ()
  "Double the number of log entries shown and refresh."
  (interactive)
  (setq madolt-log--limit (* madolt-log--limit 2))
  (madolt-refresh))

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
   (list (completing-read "Branch: " (madolt-branch-names))
         (transient-args 'madolt-log)))
  (madolt-log--show branch args))

(defun madolt-log-head (&optional args)
  "Show log for HEAD.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-log)))
  (madolt-log--show "HEAD" args))

(defun madolt-log-all (&optional args)
  "Show log for all branches.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-log)))
  (unless (member "--all" args)
    (push "--all" args))
  (madolt-log--show "--all" args))

;;;; Log display

(defun madolt-log--show (rev args)
  "Show log for REV with ARGS in a log buffer.
If a buffer already exists with the same parameters, switch to it
without refreshing.  Use \\`g' to refresh manually."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (limit (or (madolt-log--extract-limit args) 25))
         (db-name (file-name-nondirectory
                   (directory-file-name db-dir)))
         (buf-name (format "*madolt-log: %s %s*" db-name (or rev "HEAD")))
         (existing (get-buffer buf-name))
         (buffer (or existing (generate-new-buffer buf-name)))
         (same-params (and existing
                           (with-current-buffer existing
                             (and (derived-mode-p 'madolt-log-mode)
                                  (equal madolt-log--rev rev)
                                  (equal madolt-log--args args)
                                  (equal madolt-log--limit limit))))))
    (unless same-params
      (with-current-buffer buffer
        (unless (derived-mode-p 'madolt-log-mode)
          (madolt-log-mode))
        (setq default-directory db-dir)
        (setq madolt-buffer-database-dir db-dir)
        (setq madolt-log--rev rev)
        (setq madolt-log--args args)
        (setq madolt-log--limit limit)
        (madolt-refresh)))
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
  (let* ((rev (unless (string= madolt-log--rev "--all")
                madolt-log--rev))
         (entries (madolt-log-entries
                   madolt-log--limit
                   rev
                   (madolt-log--filter-log-args madolt-log--args))))
    (magit-insert-section (log)
      (magit-insert-heading
        (if (string= madolt-log--rev "--all")
            "Commits on all branches:"
          (format "Commits on %s:" (or madolt-log--rev "HEAD"))))
      (if (null entries)
          (insert (propertize "  (no commits)\n" 'font-lock-face 'shadow))
        (dolist (entry entries)
          (madolt-log--insert-commit-section entry))
        ;; Show-more button when we hit the limit
        (when (= (length entries) madolt-log--limit)
          (madolt-insert-show-more-button
           (length entries) nil
           'madolt-mode-map 'madolt-log-double-limit)))
      (insert "\n")))
  (madolt-log--setup-margins))

(defun madolt-log--insert-commit-section (entry)
  "Insert a commit section for ENTRY.
ENTRY is a plist with keys :hash :refs :date :author :message.
When :graph is non-nil, graph decoration is prepended to the line.
When :graph-pre is non-nil, junction lines are inserted before
the commit section."
  (let* ((hash (plist-get entry :hash))
         (refs (plist-get entry :refs))
         (date (plist-get entry :date))
         (author (plist-get entry :author))
         (message (plist-get entry :message))
         (graph (plist-get entry :graph))
         (graph-pre (plist-get entry :graph-pre))
         (short-hash (substring hash 0 (min 8 (length hash)))))
    ;; Insert graph junction lines before the commit (e.g. "|\" or "|/")
    (when graph-pre
      (dolist (junction graph-pre)
        (insert (propertize junction 'font-lock-face 'madolt-log-graph)
                "\n")))
    (magit-insert-section (commit hash t)
      (magit-insert-heading
        (concat
         (when graph
           (propertize (concat graph " ")
                       'font-lock-face 'madolt-log-graph))
         (propertize short-hash 'font-lock-face 'madolt-hash)
         (if refs
             (concat " " (propertize (format "(%s)" refs)
                                     'font-lock-face 'madolt-log-refs))
           "")
         " "
         (or message "")
         "\n"))
      (madolt-log--insert-margin author date)
      ;; Washer for TAB expansion: show structured diff
      (magit-insert-section-body
        (madolt-log--insert-commit-diff hash)))))

(defconst madolt-log--age-spec
  `((?Y "year"   "years"   ,(round (* 60 60 24 365.2425)))
    (?M "month"  "months"  ,(round (* 60 60 24 30.436875)))
    (?w "week"   "weeks"   ,(* 60 60 24 7))
    (?d "day"    "days"    ,(* 60 60 24))
    (?h "hour"   "hours"   ,(* 60 60))
    (?m "minute" "minutes" 60)
    (?s "second" "seconds" 1))
  "Time units for relative age formatting.
Same as magit's `magit--age-spec'.")

(defun madolt-log--relative-age (date)
  "Format DATE (epoch seconds) as a relative age.
Returns a list (COUNT UNIT) like (3 \"hours\").
Reimplements the algorithm from magit's `magit--age' to avoid
pulling in `magit-margin' (which triggers the full magit
dependency chain and breaks batch tests)."
  (named-let calc ((age (abs (- (float-time) date)))
                   (spec madolt-log--age-spec))
    (pcase-let* ((`((,_char ,unit ,units ,weight) . ,rest) spec)
                 (cnt (round (/ age weight 1.0))))
      (if (or (not rest)
              (>= (/ age weight) 1))
          (list cnt (if (= cnt 1) unit units))
        (calc age rest)))))

(defun madolt-log--format-date (date-string)
  "Format DATE-STRING as a relative age like magit.
Returns strings like \"2 hours\", \"3 days\", \"1 year\"."
  (when date-string
    (let ((time (ignore-errors (date-to-time date-string))))
      (if time
          (pcase-let ((`(,cnt ,unit)
                       (madolt-log--relative-age (float-time time))))
            (format "%d %s" cnt unit))
        date-string))))

(defun madolt-log--short-author (author)
  "Return a shortened version of AUTHOR.
Strip email address if present."
  (if (and author (string-match "\\(.*?\\)\\s-*<" author))
      (string-trim (match-string 1 author))
    author))

;;;; Right margin

(defun madolt-log--insert-margin (author date)
  "Insert a right-margin overlay with AUTHOR and DATE on the heading line.
The author is left-aligned and truncated to `madolt-log-author-width'.
The date is right-aligned within `madolt-log-margin-width'."
  (let* ((short-author (or (madolt-log--short-author author) ""))
         (short-date (or (madolt-log--format-date date) ""))
         (truncated-author (truncate-string-to-width
                            short-author madolt-log-author-width nil nil t))
         ;; Pad author to fixed width for column alignment
         (padded-author (truncate-string-to-width
                         truncated-author madolt-log-author-width nil ?\s))
         ;; Right-align date: pad with spaces between author and date
         (date-width (length short-date))
         (gap (max 1 (- madolt-log-margin-width
                       madolt-log-author-width
                       date-width)))
         (margin-text (concat
                       (propertize padded-author
                                  'font-lock-face 'madolt-log-author)
                       (make-string gap ?\s)
                       (propertize short-date
                                  'font-lock-face 'madolt-log-date))))
    (save-excursion
      (forward-line -1)
      (let ((o (make-overlay (1+ (point)) (line-end-position) nil t)))
        (overlay-put o 'evaporate t)
        (overlay-put
         o 'before-string
         (propertize "o" 'display
                     (list (list 'margin 'right-margin)
                           margin-text)))))))

(defun madolt-log--setup-margins ()
  "Set the right margin width for the current log buffer."
  (dolist (window (get-buffer-window-list nil nil 0))
    (set-window-margins window
                        (car (window-margins window))
                        madolt-log-margin-width)))

(defun madolt-log--set-window-margins (&optional window)
  "Ensure WINDOW has the right margin set for log display."
  (when (or window (setq window (get-buffer-window)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'madolt-log-mode)
        (set-window-margins window
                            (car (window-margins window))
                            madolt-log-margin-width)))))

;;;; Commit diff expansion

(defun madolt-log--insert-commit-diff (hash)
  "Insert structured table diffs for commit HASH.
Shows per-table row-level diffs, matching the status buffer style."
  (let* ((parent-hash (madolt-log--parent-hash hash))
         (diff-args (if parent-hash
                        (list parent-hash hash)
                      (list hash)))
         (json (apply #'madolt-diff-json diff-args))
         (tables (and json (alist-get 'tables json))))
    (if tables
        (dolist (tbl tables)
          (madolt-diff--insert-table-diff tbl))
      (insert "    (no changes)\n"))))

(defun madolt-log--parent-hash (hash)
  "Return the first parent commit hash of HASH, or nil if none.
Uses `madolt-log--find-entry' which calls `madolt-log-entries'
with --parents, so the parent hashes are parsed from the commit
line rather than requiring a separate CLI call."
  (car (plist-get (madolt-log--find-entry hash) :parents)))

;;;; Show commit (RET handler)

(defun madolt-show-commit (hash)
  "Show commit HASH in a revision buffer.
If a buffer already exists for this commit, switch to it without
refreshing.  Use \\`g' to refresh manually."
  (interactive
   (list (oref (magit-current-section) value)))
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (format "*madolt-revision: %s %s*"
                           (file-name-nondirectory
                            (directory-file-name db-dir))
                           (substring hash 0 (min 8 (length hash)))))
         (existing (get-buffer buf-name))
         (buffer (or existing (generate-new-buffer buf-name))))
    (unless existing
      (with-current-buffer buffer
        (madolt-revision-mode)
        (setq default-directory db-dir)
        (setq madolt-buffer-database-dir db-dir)
        (setq madolt-revision--hash hash)
        (madolt-refresh)))
    (madolt-display-buffer buffer)
    buffer))

;;;; Revision mode

(define-derived-mode madolt-revision-mode madolt-diff-mode "Madolt Rev"
  "Mode for showing a single commit's details and diff."
  ;; Default to level 2: table-diff sections expanded showing
  ;; row-diff/schema-diff headings, but row-diff bodies hidden.
  (setq-local magit-section-initial-visibility-alist
              '((table-diff . show)
                (row-diff . hide))))

(defun madolt-revision-refresh-buffer ()
  "Refresh the revision buffer."
  (let* ((hash madolt-revision--hash)
         (entry (madolt-log--find-entry hash))
         (parents (plist-get entry :parents))
         (parent (or (car parents)
                     (madolt-log--parent-hash hash))))
    (magit-insert-section (revision)
      ;; Commit metadata header
      (insert (propertize "commit " 'font-lock-face 'bold)
              (propertize hash 'font-lock-face 'madolt-hash))
      (when-let ((refs (and entry (plist-get entry :refs))))
        (insert " " (propertize (format "(%s)" refs)
                                'font-lock-face 'madolt-log-refs)))
      (insert "\n")
      ;; Parent/Merge line — use the first available parent source
      (let ((all-parents (or parents (and parent (list parent)))))
        (cond
         ((cdr all-parents)
          ;; Multi-parent: merge commit
          (insert (propertize "Merge:  " 'font-lock-face 'bold)
                  (mapconcat
                   (lambda (p)
                     (propertize (substring p 0 (min 8 (length p)))
                                 'font-lock-face 'madolt-hash))
                   all-parents " ")
                  "\n"))
         ((car all-parents)
          ;; Single parent: normal commit
          (insert (propertize "Parent: " 'font-lock-face 'bold)
                  (propertize (substring (car all-parents) 0
                                         (min 8 (length (car all-parents))))
                              'font-lock-face 'madolt-hash)
                  "\n"))))
      (when entry
        (insert (propertize "Author: " 'font-lock-face 'bold)
                (propertize (or (plist-get entry :author) "unknown")
                            'font-lock-face 'madolt-log-author)
                "\n")
        (insert (propertize "Date:   " 'font-lock-face 'bold)
                (propertize (or (plist-get entry :date) "unknown")
                            'font-lock-face 'madolt-log-date)
                "\n\n")
        ;; Full commit message (may be multi-line)
        (let ((message (or (plist-get entry :message) "")))
          (dolist (line (split-string message "\n"))
            (insert "    " line "\n"))
          (insert "\n")))
      ;; Diff with stat summary
      (let* ((diff-args (if parent
                            (list parent hash)
                          (list hash)))
             (json (apply #'madolt-diff-json diff-args))
             (tables (and json (alist-get 'tables json))))
        (if tables
            (progn
              ;; Stat summary
              (madolt-revision--insert-stat-summary tables)
              ;; Detailed diff
              (dolist (tbl tables)
                (madolt-diff--insert-table-diff tbl)))
          (insert (propertize "(no changes)\n"
                              'font-lock-face 'shadow)))))))

(defun madolt-revision--insert-stat-summary (tables)
  "Insert a compact diff stat summary for TABLES.
TABLES is the `tables' list from JSON diff output."
  (let* ((stats (madolt-diff--compute-stats tables))
         (n (length stats))
         (total-added (apply #'+ (mapcar (lambda (s) (plist-get s :added)) stats)))
         (total-deleted (apply #'+ (mapcar (lambda (s) (plist-get s :deleted)) stats)))
         (total-modified (apply #'+ (mapcar (lambda (s) (plist-get s :modified)) stats))))
    ;; Per-table stat lines
    (dolist (stat stats)
      (let* ((name (plist-get stat :name))
             (added (plist-get stat :added))
             (deleted (plist-get stat :deleted))
             (modified (plist-get stat :modified))
             (schema (plist-get stat :schema-changed))
             (parts nil))
        (when (> added 0)
          (push (propertize (format "%d+" added) 'font-lock-face 'madolt-diff-added) parts))
        (when (> deleted 0)
          (push (propertize (format "%d-" deleted) 'font-lock-face 'madolt-diff-removed) parts))
        (when (> modified 0)
          (push (propertize (format "%d~" modified) 'font-lock-face 'madolt-diff-changed-cell) parts))
        (when schema
          (push (propertize "schema" 'font-lock-face 'madolt-diff-schema) parts))
        ;; If no data/schema changes (e.g. table added with rows counted as adds)
        ;; show "added" or similar
        (when (and (null parts) (= 0 added) (= 0 deleted) (= 0 modified) (not schema))
          (push (propertize "changed" 'font-lock-face 'shadow) parts))
        (insert " " (propertize name 'font-lock-face 'madolt-diff-table-heading)
                " | " (string-join (nreverse parts) " ") "\n")))
    ;; Summary line
    (insert (propertize
             (format " %d %s changed, %d added(+), %d deleted(-), %d modified(~)\n"
                     n (if (= n 1) "table" "tables")
                     total-added total-deleted total-modified)
             'font-lock-face 'shadow))
    (insert "\n")))

(defun madolt-log--find-entry (hash)
  "Find and return the log entry plist for HASH.
Queries dolt log directly for HASH so it works regardless of
which branch the commit belongs to."
  (car (madolt-log-entries 1 hash)))

;; Branch name completion moved to madolt-dolt.el as `madolt-branch-names'.
(define-obsolete-function-alias 'madolt--branch-names
  #'madolt-branch-names "0.2.0"
  "Use `madolt-branch-names' from madolt-dolt.el instead.")

(provide 'madolt-log)
;;; madolt-log.el ends here
