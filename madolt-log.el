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
  '((t :inherit magit-log-date))
  "Face for dates in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-author
  '((t :inherit magit-log-author))
  "Face for author names in the log buffer."
  :group 'madolt-faces)

(defface madolt-log-graph
  '((t :inherit magit-log-graph))
  "Face for the graph part of the log output."
  :group 'madolt-faces)

;;;; Ref label formatting

(defun madolt-format-ref-labels (refs-string &optional remote-names)
  "Format REFS-STRING with per-ref-type faces, like `magit-format-ref-labels'.
REFS-STRING is the raw decoration from `dolt log', e.g.
\"HEAD -> main, tag: v1.0, origin/main\".  Returns a propertized
string of space-separated ref labels (no parentheses), where each
ref is individually styled using the corresponding madolt face
\(which inherits from the matching magit face).

REMOTE-NAMES is an optional list of configured remote names
\(e.g. (\"origin\" \"upstream\")).  When provided, a ref containing
\"/\" is classified as remote only if its first path component
matches a known remote; otherwise it is treated as a local branch
\(e.g. \"feature/foo\").  When nil, all refs containing \"/\" are
assumed to be local branches (safe default for repos without
remotes)."
  (let ((head-target nil)
        (tags nil)
        (branches nil)
        (remotes nil)
        (parts (split-string refs-string ", " t)))
    (dolist (part parts)
      (cond
       ;; "HEAD -> branchname" -- HEAD pointing to current branch.
       ;; Like magit, show just the branch name with the current-branch
       ;; face (boxed); no @ prefix since the face is sufficient.
       ((string-match "\\`HEAD -> \\(.+\\)\\'" part)
        (setq head-target
              (propertize (match-string 1 part)
                          'font-lock-face 'madolt-branch-current)))
       ;; "HEAD" alone (detached)
       ((string-equal part "HEAD")
        (setq head-target (propertize "@" 'font-lock-face 'madolt-head)))
       ;; "tag: tagname"
       ((string-match "\\`tag: \\(.+\\)\\'" part)
        (push (propertize (match-string 1 part)
                          'font-lock-face 'madolt-tag)
              tags))
       ;; Remote tracking branch: "remotename/branch" where remotename
       ;; matches a known remote.  Without remote-names, branches like
       ;; "feature/foo" are correctly treated as local.
       ((and remote-names
             (string-match "\\`\\([^/]+\\)/" part)
             (member (match-string 1 part) remote-names))
        (push (propertize part 'font-lock-face 'madolt-branch-remote)
              remotes))
       ;; Local branch (including branches with "/" like "feature/foo")
       (t
        (push (propertize part 'font-lock-face 'madolt-branch-local)
              branches))))
    ;; Assemble in magit's order: head, tags, local branches, remotes
    (let ((all (append (when head-target (list head-target))
                       (nreverse tags)
                       (nreverse branches)
                       (nreverse remotes))))
      (string-join all " "))))

;;;; Margin configuration

(defcustom madolt-log-margin '(t age 36 t 16)
  "Format of the margin in log buffers.

The value is a list of the form (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH):

  INIT         Whether to show the margin initially (boolean).
  STYLE        How to format the date: `age' (\"3 days\"),
               `age-abbreviated' (\"3d\"), or a `format-time-string'
               format string (e.g. \"%Y-%m-%d %H:%M\").
  WIDTH        Total width of the right margin in columns.
  AUTHOR       Whether to show the author name (boolean).
  AUTHOR-WIDTH Maximum width for author names."
  :group 'madolt
  :type '(list (boolean :tag "Show margin initially")
               (choice  :tag "Date style"
                        (const  :tag "Relative age"              age)
                        (const  :tag "Relative age (abbreviated)" age-abbreviated)
                        (string :tag "Date format string"        "%Y-%m-%d %H:%M "))
               (integer :tag "Margin width")
               (boolean :tag "Show author name")
               (integer :tag "Author name width")))

;; Keep old defcustoms as obsolete aliases for backward compatibility.
(defcustom madolt-log-margin-width 36
  "Width of the right margin in log buffers.
Includes space for author name and date."
  :group 'madolt
  :type 'integer)
(make-obsolete-variable 'madolt-log-margin-width
                        'madolt-log-margin "0.3.0")

(defcustom madolt-log-author-width 16
  "Maximum width for author names in the log margin.
Names longer than this are truncated with an ellipsis."
  :group 'madolt
  :type 'integer)
(make-obsolete-variable 'madolt-log-author-width
                        'madolt-log-margin "0.3.0")

;; Set up right margin when log mode buffers are displayed.
(add-hook 'madolt-log-mode-hook
          (lambda ()
            (add-hook 'window-configuration-change-hook
                      #'madolt-log--set-window-margins nil t)))

;;;; Buffer-local variables

(defvar-local madolt-log--margin-config nil
  "Buffer-local copy of `madolt-log-margin' for this log buffer.
A list (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH) that the margin
toggle/cycle commands mutate.  Initialized from `madolt-log-margin'
when the buffer is first set up.")

(defvar-local madolt-log--rev nil
  "The revision being shown in this log buffer.")

(defvar-local madolt-log--args nil
  "Additional arguments for dolt log in this buffer.")

(defvar-local madolt-log--limit 25
  "Number of commits to show in the log buffer.")

(defvar-local madolt-revision--hash nil
  "The commit hash being shown in a revision buffer.")

(defvar madolt-log--remote-names nil
  "List of remote names for the current refresh cycle.
Bound dynamically during log/revision buffer refresh so that
`madolt-format-ref-labels' can distinguish remote tracking
branches (e.g. \"origin/main\") from local branches with slashes
\(e.g. \"feature/foo\").")

;;;; Transient menus

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

;;;; Log refresh transient (L)

;; Like magit-log-refresh: change the arguments of the current log
;; buffer and refresh it in-place, without re-selecting a branch.

;;;###autoload (autoload 'madolt-log-refresh "madolt-log" nil t)
(transient-define-prefix madolt-log-refresh ()
  "Change the arguments used for the log(s) in the current buffer."
  :value #'madolt-log-refresh--current-args
  ["Arguments"
   ("-n" "Limit count" "-n"
    :class transient-option
    :reader transient-read-number-N+)
   ("-s" "Show stat"   "--stat")
   ("-m" "Merges only" "--merges")
   ("-g" "Graph"       "--graph")]
  [["Refresh"
    ("g" "buffer"                   madolt-log-refresh-apply)
    ("s" "buffer and set defaults"  madolt-log-refresh-set)
    ("w" "buffer and save defaults" madolt-log-refresh-save)]
   ["Margin"
    (madolt-toggle-margin)
    (madolt-cycle-margin-style)
    (madolt-toggle-margin-details)]]
  (interactive)
  (cond
   ;; In a log buffer — refresh the current buffer's args.
   ((derived-mode-p 'madolt-log-mode)
    (transient-setup 'madolt-log-refresh))
   ;; Not in a log buffer — try to find one to refresh.
   (t
    (if-let ((log-buf (madolt-log-refresh--find-log-buffer)))
        (with-current-buffer log-buf
          (transient-setup 'madolt-log-refresh))
      (user-error "No log buffer to refresh; use `l' to open one")))))

(defun madolt-log-refresh--current-args ()
  "Return the current log buffer's arguments for the transient."
  (when (derived-mode-p 'madolt-log-mode)
    (let ((args (copy-sequence (or madolt-log--args nil))))
      ;; Include the -n limit in the transient value so the user
      ;; can see and adjust it.
      (when (and madolt-log--limit
                 (not (cl-some (lambda (a) (string-prefix-p "-n" a)) args)))
        (push (format "-n%d" madolt-log--limit) args))
      args)))

(defun madolt-log-refresh--find-log-buffer ()
  "Find a visible madolt-log-mode buffer in the current frame."
  (cl-some (lambda (w)
             (with-current-buffer (window-buffer w)
               (when (derived-mode-p 'madolt-log-mode)
                 (current-buffer))))
           (window-list)))

(defun madolt-log-refresh-apply (&optional args)
  "Apply the transient ARGS to the current log buffer and refresh.
When called from the transient, uses the transient arguments."
  (interactive (list (transient-args 'madolt-log-refresh)))
  (madolt-log-refresh--apply-args args))

(defun madolt-log-refresh-set (&optional args)
  "Apply ARGS, refresh, and set as the default for this session.
The defaults persist until Emacs is restarted."
  (interactive (list (transient-args 'madolt-log-refresh)))
  (transient-set)
  (madolt-log-refresh--apply-args args))

(defun madolt-log-refresh-save (&optional args)
  "Apply ARGS, refresh, and save as the persistent default.
The defaults persist across Emacs sessions."
  (interactive (list (transient-args 'madolt-log-refresh)))
  (transient-save)
  (madolt-log-refresh--apply-args args))

(defun madolt-log-refresh--apply-args (args)
  "Apply ARGS to the current log buffer and refresh it.
Extracts the -n limit from ARGS and sets `madolt-log--limit',
then stores the remaining args in `madolt-log--args'."
  (unless (derived-mode-p 'madolt-log-mode)
    (user-error "Not in a log buffer"))
  (let ((limit (madolt-log--extract-limit args)))
    (when limit
      (setq madolt-log--limit limit)))
  (setq madolt-log--args (madolt-log--filter-log-args args))
  (madolt-refresh))

;;;; Margin transient suffixes

(defun madolt-log--ensure-margin-config ()
  "Ensure `madolt-log--margin-config' is initialized for this buffer.
Copies from `madolt-log-margin' if not yet set."
  (unless madolt-log--margin-config
    (setq madolt-log--margin-config (copy-sequence madolt-log-margin))))

(transient-define-suffix madolt-toggle-margin ()
  "Show or hide the right margin in the current log buffer."
  :description "Toggle visibility"
  :key "L"
  :transient t
  (interactive)
  (unless (derived-mode-p 'madolt-log-mode)
    (user-error "Not in a log buffer"))
  (madolt-log--ensure-margin-config)
  (setcar madolt-log--margin-config
          (not (car madolt-log--margin-config)))
  (madolt-log--apply-margin-config))

(transient-define-suffix madolt-cycle-margin-style ()
  "Cycle the date style used in the right margin.
Cycles through: age (\"3 days\") -> age-abbreviated (\"3d\")
-> absolute date -> age."
  :description "Cycle style"
  :key "l"
  :transient t
  (interactive)
  (unless (derived-mode-p 'madolt-log-mode)
    (user-error "Not in a log buffer"))
  (madolt-log--ensure-margin-config)
  (setf (cadr madolt-log--margin-config)
        (pcase (cadr madolt-log--margin-config)
          ('age 'age-abbreviated)
          ('age-abbreviated "%Y-%m-%d %H:%M ")
          (_ 'age)))
  (madolt-log--apply-margin-config))

(transient-define-suffix madolt-toggle-margin-details ()
  "Show or hide the author name in the right margin."
  :description "Toggle details"
  :key "d"
  :transient t
  (interactive)
  (unless (derived-mode-p 'madolt-log-mode)
    (user-error "Not in a log buffer"))
  (madolt-log--ensure-margin-config)
  (setf (nth 3 madolt-log--margin-config)
        (not (nth 3 madolt-log--margin-config)))
  (madolt-log--apply-margin-config))

(defun madolt-log--apply-margin-config ()
  "Apply the current margin config and refresh the buffer.
Recalculates the margin width and refreshes the display."
  (madolt-log--setup-margins)
  (madolt-refresh))

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
  ;; Auto-enable --graph for multi-branch views (like magit)
  (unless (member "--graph" args)
    (push "--graph" args))
  (madolt-log--show "--all" args))

;;;; Log display

(defun madolt-log--show (rev args)
  "Show log for REV with ARGS in a log buffer.
Always refreshes the buffer to show current data."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (limit (or (madolt-log--extract-limit args) 25))
         (db-name (file-name-nondirectory
                   (directory-file-name db-dir)))
         (buf-name (format "madolt-log: %s %s" db-name (or rev "HEAD")))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-log-mode)
        (madolt-log-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-log--rev rev)
      (setq madolt-log--args args)
      (setq madolt-log--limit limit)
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
  (let* ((rev (unless (string= madolt-log--rev "--all")
                madolt-log--rev))
         (madolt-log--remote-names (madolt-remote-names))
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
the commit section.
When :graph-post is non-nil, junction lines are inserted after
the commit section (e.g. \"|\\\\\" after a merge commit)."
  (let* ((hash (plist-get entry :hash))
         (refs (plist-get entry :refs))
         (date (plist-get entry :date))
         (author (plist-get entry :author))
         (message (plist-get entry :message))
         (graph (plist-get entry :graph))
         (graph-pre (plist-get entry :graph-pre))
         (graph-post (plist-get entry :graph-post))
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
              (concat " " (madolt-format-ref-labels
                           refs madolt-log--remote-names))
            "")
         " "
         (or message "")
         "\n"))
      (madolt-log--insert-margin author date)
      ;; Washer for TAB expansion: show structured diff
      (magit-insert-section-body
        (madolt-log--insert-commit-diff hash)))
    ;; Insert graph junction lines after the commit (e.g. "|\" after merge)
    (when graph-post
      (dolist (junction graph-post)
        (insert (propertize junction 'font-lock-face 'madolt-log-graph)
                "\n")))))

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

(defun madolt-log--format-date (date-string &optional style)
  "Format DATE-STRING according to STYLE.
STYLE can be:
  `age'              -- relative age like \"3 days\" (default)
  `age-abbreviated'  -- abbreviated like \"3d\"
  a string           -- passed to `format-time-string'"
  (when date-string
    (let ((time (ignore-errors (date-to-time date-string)))
          (style (or style 'age)))
      (if time
          (cond
           ((stringp style)
            (format-time-string style (float-time time)))
           ((eq style 'age-abbreviated)
            (pcase-let ((`(,cnt ,unit)
                         (madolt-log--relative-age (float-time time))))
              ;; Use first character of unit: "3d", "2h", "1Y"
              (format "%d%c" cnt (aref unit 0))))
           (t ; 'age or fallback
            (pcase-let ((`(,cnt ,unit)
                         (madolt-log--relative-age (float-time time))))
              (format "%d %s" cnt unit))))
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
Respects the margin config in `madolt-log--margin-config':
INIT controls visibility, STYLE controls date format, AUTHOR
controls whether the author name is shown."
  (madolt-log--ensure-margin-config)
  (pcase-let ((`(,init ,style ,width ,show-author ,author-width)
               madolt-log--margin-config))
    (when init
      (let* ((short-author (or (madolt-log--short-author author) ""))
             (short-date (or (madolt-log--format-date date style) ""))
             (margin-text
              (if show-author
                  (let* ((truncated-author
                          (truncate-string-to-width
                           short-author author-width nil nil t))
                         (padded-author
                          (truncate-string-to-width
                           truncated-author author-width nil ?\s))
                         (date-width (length short-date))
                         (gap (max 1 (- width author-width date-width))))
                    (concat
                     (propertize padded-author
                                'font-lock-face 'madolt-log-author)
                     (make-string gap ?\s)
                     (propertize short-date
                                'font-lock-face 'madolt-log-date)))
                ;; No author — just the date, right-aligned
                (let* ((date-width (length short-date))
                       (gap (max 0 (- width date-width))))
                  (concat
                   (make-string gap ?\s)
                   (propertize short-date
                               'font-lock-face 'madolt-log-date))))))
        (save-excursion
          (forward-line -1)
          (let ((o (make-overlay (1+ (point)) (line-end-position) nil t)))
            (overlay-put o 'evaporate t)
            (overlay-put
             o 'before-string
             (propertize "o" 'display
                         (list (list 'margin 'right-margin)
                               margin-text)))))))))

(defun madolt-log--margin-effective-width ()
  "Return the effective right margin width.
Returns 0 when the margin is hidden, otherwise the configured width."
  (madolt-log--ensure-margin-config)
  (if (car madolt-log--margin-config)
      (nth 2 madolt-log--margin-config)
    0))

(defun madolt-log--setup-margins ()
  "Set the right margin width for the current log buffer."
  (let ((width (madolt-log--margin-effective-width)))
    (dolist (window (get-buffer-window-list nil nil 0))
      (set-window-margins window
                          (car (window-margins window))
                          width))))

(defun madolt-log--set-window-margins (&optional window)
  "Ensure WINDOW has the right margin set for log display."
  (when (or window (setq window (get-buffer-window)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'madolt-log-mode)
        (let ((width (madolt-log--margin-effective-width)))
          (set-window-margins window
                              (car (window-margins window))
                              width))))))

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

(defun madolt-show-commit (hash &optional noselect)
  "Show commit HASH in a revision buffer.
If a buffer already exists for this commit, switch to it without
refreshing.  Use \\`g' to refresh manually.

When NOSELECT is non-nil, display the buffer in another window
without selecting it."
  (interactive
   (list (oref (magit-current-section) value)))
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
(buf-name (format "madolt-revision: %s %s"
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
    (if noselect
        (display-buffer buffer '(nil (inhibit-same-window . t)))
      (madolt-display-buffer buffer))
    buffer))

;;;; Show-or-scroll (SPC / DEL)

(defun madolt--revision-buffer-for-hash (hash)
  "Return the revision buffer displaying HASH, or nil.
Only returns a buffer that is visible in the current frame."
  (let* ((db-dir (madolt-database-dir))
         (buf-name (and db-dir
(format "madolt-revision: %s %s"
                                 (file-name-nondirectory
                                  (directory-file-name db-dir))
                                 (substring hash 0 (min 8 (length hash)))))))
    (when buf-name
      (let ((buf (get-buffer buf-name)))
        (and buf (get-buffer-window buf) buf)))))

(defun madolt-diff-show-or-scroll-up ()
  "Show the commit at point, or scroll its revision buffer up.
On a commit section, if the revision buffer is already visible in
the frame, scroll it up (forward) by one page.  Otherwise show
the commit in another window without selecting it.

Mimics `magit-diff-show-or-scroll-up'."
  (interactive)
  (madolt-diff-show-or-scroll #'scroll-up))

(defun madolt-diff-show-or-scroll-down ()
  "Show the commit at point, or scroll its revision buffer down.
On a commit section, if the revision buffer is already visible in
the frame, scroll it down (backward) by one page.  Otherwise show
the commit in another window without selecting it.

Mimics `magit-diff-show-or-scroll-down'."
  (interactive)
  (madolt-diff-show-or-scroll #'scroll-down))

(defun madolt-diff-show-or-scroll (fn)
  "Show or scroll the revision for the commit at point.
FN is the scroll function (`scroll-up' or `scroll-down').
If the commit's revision buffer is already visible in the frame,
scroll it with FN.  At buffer boundaries, wrap around.
Otherwise, show the commit in another window without selecting."
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'commit))
      (user-error "No commit at point"))
    (let* ((hash (oref section value))
           (buf (madolt--revision-buffer-for-hash hash)))
      (if buf
          ;; Already visible — scroll it
          (with-selected-window (get-buffer-window buf)
            (condition-case nil
                (funcall fn)
              (error
               (pcase fn
                 ('scroll-up   (goto-char (point-min)))
                 ('scroll-down (goto-char (point-max)))))))
        ;; Not visible — show without selecting
        (madolt-show-commit hash t)))))

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
         (madolt-log--remote-names (madolt-remote-names))
         (entry (madolt-log--find-entry hash))
         (parents (plist-get entry :parents))
         (parent (or (car parents)
                     (madolt-log--parent-hash hash))))
    (magit-insert-section (revision)
      ;; Commit metadata header — refs before hash, like magit
      (when-let ((refs (and entry (plist-get entry :refs))))
        (insert (madolt-format-ref-labels
                 refs madolt-log--remote-names)
                " "))
      (insert (propertize hash 'font-lock-face 'madolt-hash) "\n")
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
