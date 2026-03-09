;;; madolt-dolt.el --- Dolt CLI wrapper layer  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1"))

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

;; Dolt CLI wrapper layer for madolt.  Provides functions to execute
;; dolt commands and parse their output.  Modeled on magit-git.el:
;; same abstraction pattern (executable + global args + output-parsing
;; helpers), different binary.
;;
;; This is the lowest layer of madolt — it has no dependency on
;; magit-section, transient, or with-editor.

;;; Code:

(eval-when-compile (require 'cl-lib))

;;;; Configuration

(defcustom madolt-dolt-executable "dolt"
  "The Dolt executable used by Madolt."
  :group 'madolt
  :type 'string)

(defcustom madolt-dolt-global-arguments nil
  "Global arguments prepended to every dolt invocation.
These are placed right after the executable itself and before
the dolt command."
  :group 'madolt
  :type '(repeat string))

;;;; Internal helpers

(defun madolt--flatten-args (args)
  "Flatten ARGS into a flat list of strings, removing nils."
  (let ((flat (flatten-tree args)))
    (delq nil (mapcar (lambda (a)
                        (and a (if (stringp a) a (format "%s" a))))
                      flat))))

(defconst madolt--ansi-escape-re
  "\033\\[[0-9;]*m"
  "Regexp matching ANSI SGR escape sequences.")

(defun madolt--strip-ansi (string)
  "Strip ANSI escape sequences from STRING."
  (if string
      (replace-regexp-in-string madolt--ansi-escape-re "" string)
    ""))

;;;; Core execution

(defun madolt--run (&rest args)
  "Execute dolt with ARGS synchronously.
Return a cons cell (EXIT-CODE . OUTPUT-STRING).
Global arguments from `madolt-dolt-global-arguments' are prepended.
Nil arguments are removed and nested lists are flattened."
  (let* ((args (madolt--flatten-args
                (append madolt-dolt-global-arguments args)))
         (process-environment (cons "NO_COLOR=1" process-environment)))
    (with-temp-buffer
      (let ((exit (apply #'call-process
                         madolt-dolt-executable nil t nil args)))
        (cons exit (buffer-string))))))

(defun madolt-dolt-string (&rest args)
  "Execute dolt with ARGS, returning the first line of output.
Return nil if exit code is non-zero or if there is no output."
  (let ((result (apply #'madolt--run args)))
    (and (zerop (car result))
         (not (string-empty-p (cdr result)))
         (car (split-string (cdr result) "\n" t)))))

(defun madolt-dolt-lines (&rest args)
  "Execute dolt with ARGS, returning output as a list of lines.
Empty lines are omitted."
  (let ((result (apply #'madolt--run args)))
    (split-string (cdr result) "\n" t)))

(defun madolt-dolt-json (&rest args)
  "Execute dolt with ARGS, returning parsed JSON output.
Return nil if the output cannot be parsed as JSON.
Uses `json-parse-string' with alist object type and list array type."
  (let ((result (apply #'madolt--run args)))
    (and (zerop (car result))
         (not (string-empty-p (cdr result)))
         (condition-case nil
             (json-parse-string (cdr result)
                                :object-type 'alist
                                :array-type 'list)
           (json-parse-error nil)))))

(defun madolt-dolt-insert (&rest args)
  "Execute dolt with ARGS, inserting output at point.
Return the exit code."
  (let ((result (apply #'madolt--run args)))
    (insert (cdr result))
    (car result)))

(defun madolt-dolt-exit-code (&rest args)
  "Execute dolt with ARGS, returning the exit code as an integer."
  (car (apply #'madolt--run args)))

(defun madolt-dolt-success-p (&rest args)
  "Execute dolt with ARGS, returning non-nil if exit code is 0."
  (zerop (car (apply #'madolt--run args))))

;;;; Database context

(defun madolt-database-dir (&optional directory)
  "Return the root directory of the Dolt database.
Search upward from DIRECTORY (or `default-directory') for a
directory containing a `.dolt/' subdirectory.
Return nil if not in a dolt database."
  (let ((dir (locate-dominating-file
              (or directory default-directory)
              (lambda (d) (file-directory-p (expand-file-name ".dolt" d))))))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun madolt-database-p (&optional directory)
  "Return non-nil if DIRECTORY is inside a Dolt database.
If DIRECTORY is nil, use `default-directory'."
  (not (null (madolt-database-dir directory))))

(defun madolt-current-branch ()
  "Return the name of the current Dolt branch as a string."
  (let ((branch (madolt-dolt-string "branch" "--show-current")))
    (and branch (string-trim branch))))

(defun madolt-remotes ()
  "Return an alist of (NAME . URL) for configured remotes.
Parses the output of `dolt remote -v'."
  (let ((lines (madolt-dolt-lines "remote" "-v"))
        (result nil))
    (dolist (line lines)
      (when (string-match "^\\(\\S-+\\)\\s-+\\(\\S-+\\)" line)
        (let ((name (match-string 1 line))
              (url (match-string 2 line)))
          (unless (assoc name result #'string=)
            (push (cons name url) result)))))
    (nreverse result)))

(defun madolt-remote-add (name url)
  "Add a remote with NAME pointing to URL."
  (madolt--run "remote" "add" name url))

(defun madolt-remote-remove (name)
  "Remove the remote named NAME."
  (madolt--run "remote" "remove" name))

;;;; Table queries

(defun madolt-table-names ()
  "Return a list of all table names in the current database."
  (let ((result (madolt-dolt-json "sql" "-q" "SHOW TABLES" "-r" "json")))
    (when result
      (let ((rows (alist-get 'rows result)))
        (mapcar (lambda (row)
                  ;; The key name varies: "Tables_in_<dbname>"
                  (cdr (car row)))
                rows)))))

;;;; Status queries

(defun madolt-status-tables ()
  "Parse `dolt status' and return an alist of change categories.
Return value is:
  ((staged    . ((TABLE . STATUS) ...))
   (unstaged  . ((TABLE . STATUS) ...))
   (untracked . ((TABLE . STATUS) ...)))
where STATUS is a string like \"modified\", \"new table\", \"renamed\",
\"deleted\"."
  (let ((output (cdr (madolt--run "status")))
        (staged nil)
        (unstaged nil)
        (untracked nil)
        (current-section nil))
    (dolist (line (split-string output "\n"))
      (cond
       ((string-match-p "^Changes to be committed:" line)
        (setq current-section 'staged))
       ((string-match-p "^Changes not staged for commit:" line)
        (setq current-section 'unstaged))
       ((string-match-p "^Untracked tables:" line)
        (setq current-section 'untracked))
       ;; Table entry lines are tab-indented: "\tstatus:  table_name"
       ((string-match "^\t\\([a-z ]+\\):\\s-+\\(\\S-+\\)" line)
        (let ((status (string-trim (match-string 1 line)))
              (table (match-string 2 line)))
          (pcase current-section
            ('staged    (push (cons table status) staged))
            ('unstaged  (push (cons table status) unstaged))
            ('untracked (push (cons table status) untracked)))))))
    `((staged    . ,(nreverse staged))
      (unstaged  . ,(nreverse unstaged))
      (untracked . ,(nreverse untracked)))))

;;;; Diff queries

(defun madolt-diff-json (&rest args)
  "Run `dolt diff' with JSON output and return parsed result.
ARGS are additional arguments passed to `dolt diff'."
  (apply #'madolt-dolt-json "diff" "-r" "json" args))

(defun madolt-diff-stat (&rest args)
  "Run `dolt diff --stat' and return the output string.
ARGS are additional arguments passed to `dolt diff'."
  (cdr (apply #'madolt--run "diff" "--stat" args)))

(defun madolt-diff-raw (&rest args)
  "Run `dolt diff' and return the raw tabular output string.
ARGS are additional arguments passed to `dolt diff'."
  (cdr (apply #'madolt--run "diff" args)))

;;;; Log queries

(defun madolt-log-entries (&optional n rev extra-args)
  "Return the last N commits as a list of plists.
Each plist has keys :hash :refs :date :author :message :parents.
N defaults to 10.  REV is the revision to show (branch name,
tag, or commit hash); when nil, dolt shows the current branch.
EXTRA-ARGS is a list of additional dolt log arguments
such as \"--merges\".
The :parents key holds a list of parent hash strings (from the
Merge: line); it is nil for non-merge commits."
  (let* ((args (append (list "log" "-n" (number-to-string (or n 10)))
                       (madolt--flatten-args extra-args)
                       (when rev (list rev))))
         (output (cdr (apply #'madolt--run args)))
         (clean-output (madolt--strip-ansi output))
         (entries nil)
         (current-hash nil)
         (current-refs nil)
         (current-author nil)
         (current-date nil)
         (current-parents nil)
         (current-message-lines nil)
         (in-message nil))
    (dolist (raw-line (split-string clean-output "\n"))
      ;; Strip --graph decoration (e.g. "* ", "| ", "|\ ") from
      ;; the start of each line so the parser sees clean output.
      (let ((line (replace-regexp-in-string
                   "^[|*/ \\\\]+ ?" "" raw-line)))
      (cond
       ;; Commit line: "commit HASH", "commit HASH (refs)", or
       ;; "commit HASH(refs)" (--graph omits the space before parens)
       ((string-match "^commit \\([a-z0-9]+\\)\\(?: ?(\\(.*\\))\\)?\\s-*$" line)
        ;; Save previous entry if any
        (when current-hash
          (push (list :hash current-hash
                      :refs current-refs
                      :date current-date
                      :author current-author
                      :parents current-parents
                      :message (string-trim
                                (mapconcat #'identity
                                           (nreverse current-message-lines)
                                           "\n")))
                entries))
        (setq current-hash (match-string 1 line))
        (setq current-refs (match-string 2 line))
        (setq current-author nil)
        (setq current-date nil)
        (setq current-parents nil)
        (setq current-message-lines nil)
        (setq in-message nil))
       ;; Merge line: "Merge: HASH1 HASH2"
       ((string-match "^Merge:\\s-+\\(.*\\)$" line)
        (setq current-parents
              (split-string (string-trim (match-string 1 line)))))
       ;; Author line
       ((string-match "^Author:\\s-+\\(.*\\)$" line)
        (setq current-author (string-trim (match-string 1 line))))
       ;; Date line
       ((string-match "^Date:\\s-+\\(.*\\)$" line)
        (setq current-date (string-trim (match-string 1 line)))
        ;; Message follows after the blank line after Date
        (setq in-message t))
       ;; Blank line between date and message
       ((and in-message (string-match-p "^\\s-*$" line)
             (null current-message-lines))
        ;; Skip the blank line separator
        nil)
       ;; Message lines (tab-indented)
       ((and in-message (string-match "^\t\\(.*\\)" line))
        (push (match-string 1 line) current-message-lines))
       ;; Blank line within/after message
       ((and in-message current-message-lines
             (string-match-p "^\\s-*$" line))
        ;; Could be multi-paragraph message; keep blank lines
         (push "" current-message-lines)))))
    ;; Don't forget the last entry
    (when current-hash
      (push (list :hash current-hash
                  :refs current-refs
                  :date current-date
                  :author current-author
                  :parents current-parents
                  :message (string-trim
                            (mapconcat #'identity
                                       (nreverse current-message-lines)
                                       "\n")))
            entries))
    (nreverse entries)))

;;;; Reflog queries

(defun madolt-reflog-entries (&optional ref all)
  "Return reflog entries as a list of plists.
Each plist has keys :hash :refs :message.
REF is an optional branch/tag name to filter (default: all refs
for current branch).  When ALL is non-nil, pass --all to show
hidden refs too.

Dolt reflog output format (one line per entry):
  HASH (refs) message"
  (let* ((args (append (list "reflog")
                       (when all (list "--all"))
                       (when ref (list ref))))
         (output (cdr (apply #'madolt--run args)))
         (clean (madolt--strip-ansi output))
         (entries nil))
    (dolist (line (split-string clean "\n" t))
      (when (string-match
             "^\\([a-z0-9]+\\)\\s-+(\\(.*?\\))\\s-+\\(.*\\)$"
             line)
        (push (list :hash (match-string 1 line)
                    :refs (match-string 2 line)
                    :message (string-trim (match-string 3 line)))
              entries)))
    (nreverse entries)))

;;;; Mutation operations

(defun madolt-add-tables (tables)
  "Stage TABLES for commit.
TABLES is a list of table name strings."
  (apply #'madolt--run "add" tables))

(defun madolt-add-all ()
  "Stage all changed tables for commit."
  (madolt--run "add" "."))

(defun madolt-reset-tables (tables)
  "Unstage TABLES.
TABLES is a list of table name strings."
  (apply #'madolt--run "reset" tables))

(defun madolt-reset-all ()
  "Unstage all staged tables."
  (madolt--run "reset"))

(defun madolt-checkout-table (table)
  "Discard working changes to TABLE."
  (madolt--run "checkout" table))

;;;; Branch operations

(defun madolt-branch-names ()
  "Return a list of branch names in the current database."
  (let ((lines (madolt-dolt-lines "branch")))
    (mapcar (lambda (line)
              (string-trim (replace-regexp-in-string "^\\*\\s-*" "" line)))
            lines)))

(defun madolt-branch-create (name &optional start-point)
  "Create a new branch NAME, optionally from START-POINT.
Does not switch to the new branch."
  (if start-point
      (madolt--run "branch" name start-point)
    (madolt--run "branch" name)))

(defun madolt-branch-checkout (name)
  "Switch to branch NAME."
  (madolt--run "checkout" name))

(defun madolt-branch-checkout-create (name &optional start-point)
  "Create and switch to a new branch NAME, optionally from START-POINT."
  (if start-point
      (madolt--run "checkout" "-b" name start-point)
    (madolt--run "checkout" "-b" name)))

(defun madolt-branch-delete (name &optional force)
  "Delete branch NAME.
When FORCE is non-nil, use -D (force delete)."
  (madolt--run "branch" (if force "-D" "-d") name))

(defun madolt-branch-rename (old-name new-name)
  "Rename branch OLD-NAME to NEW-NAME."
  (madolt--run "branch" "-m" old-name new-name))

;;;; Remote operations

(defun madolt-remote-names ()
  "Return a list of remote names."
  (mapcar #'car (madolt-remotes)))

(defun madolt-remote-branch-exists-p (remote branch)
  "Return non-nil if REMOTE has BRANCH.
Checks `dolt branch -a' output for remotes/REMOTE/BRANCH."
  (let ((ref (format "remotes/%s/%s" remote branch)))
    (seq-some (lambda (line)
                (string= (string-trim line) ref))
              (madolt-dolt-lines "branch" "-a"))))

;;;; Upstream tracking

(defun madolt-upstream-ref (&optional branch)
  "Return the upstream remote ref for BRANCH, or nil.
Dolt does not have git-style upstream tracking, so this uses the
convention of looking for origin/BRANCH.  If no remote named
\"origin\" exists, the first configured remote is tried.
BRANCH defaults to the current branch."
  (let* ((branch (or branch (madolt-current-branch)))
         (remotes (madolt-remote-names))
         (remote (if (member "origin" remotes)
                     "origin"
                   (car remotes))))
    (when (and remote branch
               (madolt-remote-branch-exists-p remote branch))
      (format "%s/%s" remote branch))))

(defun madolt-unpushed-commits (&optional upstream)
  "Return commits in HEAD that are not in UPSTREAM.
UPSTREAM defaults to the result of `madolt-upstream-ref'.
Returns a list of plists with keys :hash :refs :date :author :message,
or nil if there is no upstream or no unpushed commits."
  (let ((upstream (or upstream (madolt-upstream-ref))))
    (when upstream
      (madolt-log-entries 100 (format "%s..HEAD" upstream)))))

(defun madolt-unpulled-commits (&optional upstream)
  "Return commits in UPSTREAM that are not in HEAD.
UPSTREAM defaults to the result of `madolt-upstream-ref'.
Returns a list of plists with keys :hash :refs :date :author :message,
or nil if there is no upstream or no unpulled commits."
  (let ((upstream (or upstream (madolt-upstream-ref))))
    (when upstream
      (madolt-log-entries 100 (format "HEAD..%s" upstream)))))

;;;; Tag operations

(defun madolt-tag-names ()
  "Return a list of tag names in the current database."
  (mapcar #'string-trim (madolt-dolt-lines "tag")))

(defun madolt-tag-create (name &optional ref message)
  "Create a tag NAME, optionally at REF with MESSAGE.
When MESSAGE is non-nil, create an annotated tag."
  (let ((args (list "tag")))
    (when message
      (setq args (append args (list "-m" message))))
    (setq args (append args (list name)))
    (when ref
      (setq args (append args (list ref))))
    (apply #'madolt--run args)))

(defun madolt-tag-delete (name)
  "Delete tag NAME."
  (madolt--run "tag" "-d" name))

(provide 'madolt-dolt)
;;; madolt-dolt.el ends here
