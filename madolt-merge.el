;;; madolt-merge.el --- Merge commands for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (transient "0.7"))

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

;; Merge transient menu and merge commands for madolt.
;;
;; Provides merge into current branch, abort merge, and common
;; merge flags via the `dolt merge' CLI command.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)
(require 'madolt-commit)

(declare-function madolt-branch-or-commit-at-point "madolt-mode" ())

;;;; Transient menu

;;;###autoload (autoload 'madolt-merge "madolt-merge" nil t)
(transient-define-prefix madolt-merge ()
  "Merge branches."
  ["Arguments"
   :if-not madolt-merge-in-progress-p
   ("-n" "No fast-forward"  "--no-ff")
   ("-f" "Fast-forward only" "--ff-only")
   ("-s" "Squash"           "--squash")
   ("-c" "No commit"        "--no-commit")]
  ["Merge"
   :if-not madolt-merge-in-progress-p
   ("m" "Merge"             madolt-merge-command)]
  ["Actions"
   :if madolt-merge-in-progress-p
   ("m" "Continue"          madolt-merge-continue-command)
   ("a" "Abort"             madolt-merge-abort-command)])

;;;; Interactive commands

(defun madolt-merge--buffer-name ()
  "Return the merge message buffer name for the current database."
  (let ((db (file-name-nondirectory
             (directory-file-name (or (madolt-database-dir) "")))))
    (format "madolt-merge: %s" db)))

(defun madolt-merge--via-sql (branch message flags)
  "Execute merge of BRANCH via SQL with autocommit disabled.
MESSAGE is the commit message (or nil).  FLAGS is a list of flags
like \"--no-ff\".  Returns (EXIT-CODE . OUTPUT) like `madolt-call-dolt'.
Disables autocommit before the merge to allow conflict resolution,
then re-enables it after."
  ;; Use `dolt sql -q' instead of the persistent connection because:
  ;; (a) The persistent batch-mode connection can't reliably parse
  ;;     multi-statement output (SET + CALL DOLT_MERGE).
  ;; (b) With dolt_allow_commit_conflicts=1, conflict state persists
  ;;     on disk so the resolution workflow works after disconnect.
  ;; (c) `dolt merge' CLI refuses to run when a SQL server is active,
  ;;     but `dolt sql -q' works.
  (when (madolt-sql-server-info)
    (let* ((sql-args (list (format "'%s'" branch)))
           (_ (dolist (flag flags)
                (push (format "'%s'" flag) sql-args)))
           (_ (when message
                (push "'-m'" sql-args)
                (push (format "'%s'" message) sql-args)))
           (sql (format "SET @@dolt_allow_commit_conflicts = 1; CALL DOLT_MERGE(%s)"
                        (mapconcat #'identity
                                   (nreverse sql-args) ", ")))
           (result (madolt--run-cli (list "sql" "-q" sql "-r" "csv")))
           (output (cdr result)))
      ;; Disconnect to reset session state after merge
      (when (fboundp 'madolt-connection-disconnect)
        (madolt-connection-disconnect))
      (if (not (zerop (car result)))
          ;; dolt sql -q failed (shouldn't happen with allow_commit_conflicts)
          nil
        ;; Check output for conflicts
        (if (and output (string-match-p "conflict" output))
            (cons 1 (format "Merge conflict with %s" branch))
          (cons 0 (or output "")))))))

(defun madolt-merge--do-merge (message args)
  "Execute `dolt merge' with MESSAGE and ARGS.
ARGS should already include the branch to merge.
MESSAGE may be nil to use dolt's auto-generated message."
  (let* ((head-before (madolt-dolt-string "log" "-n" "1" "--oneline"))
         ;; Extract the branch name (last non-flag arg)
         (branch (car (last (cl-remove-if
                             (lambda (a) (string-prefix-p "-" a))
                             args))))
         (flags (cl-remove-if-not
                 (lambda (a) (string-prefix-p "-" a))
                 args))
         ;; Try SQL first (with autocommit handling), fall back to CLI
         (sql-result (and (bound-and-true-p madolt-use-sql-server)
                          (madolt-merge--via-sql branch message flags)))
         (result (or sql-result
                     (let ((all-args
                            (append
                             (when (and message
                                        (not (string-empty-p message)))
                               (list "-m" message))
                             args)))
                       (apply #'madolt-call-dolt "merge" all-args))))
         (output (madolt--clean-output (cdr result)))
         (head-after (madolt-dolt-string "log" "-n" "1" "--oneline")))
    ;; Reset SQL connection after merge to avoid stale session state
    (when (fboundp 'madolt-connection-disconnect)
      (madolt-connection-disconnect))
    (let ((failure
           (cond
            ((not (zerop (car result)))
             output)
            ((string-match-p "\\(conflict\\|error\\|rolled back\\)" output)
             output)
            ;; Skip HEAD check for --squash/--no-commit (they don't change HEAD)
            ((and (equal head-before head-after)
                  (not (member "--squash" flags))
                  (not (member "--no-commit" flags)))
             "HEAD unchanged (merge may have failed silently)"))))
      (madolt-refresh)
      (if failure
          (progn
            ;; Log to process buffer and display it
            (madolt--process-insert-section
             (list "merge" branch) 1 failure)
            (madolt-process-buffer)
            (message "Merge failed: %s"
                     (truncate-string-to-width failure 80 nil nil "...")))
        (message "Merged %s into %s" branch
                 (madolt-current-branch))))))

(defun madolt-merge-command (branch &optional args)
  "Merge BRANCH into the current branch.
ARGS are additional arguments from the transient.
Runs the merge first; on success, opens a buffer for the merge
commit message (like magit).  With --squash or --no-commit,
skips the message buffer."
  (interactive
   (let* ((current (madolt-current-branch))
          (at-point (madolt-branch-or-commit-at-point))
          (default (and at-point
                        (not (equal at-point current))
                        at-point)))
     (list (completing-read
            (format "Merge into %s%s: " current
                    (if default (format " (default %s)" default) ""))
            (remove current (madolt-all-ref-names))
            nil nil nil nil default)
           (transient-args 'madolt-merge))))
  (let* ((current (madolt-current-branch))
         (merge-args (append args (list branch)))
         (needs-message (not (or (member "--squash" args)
                                 (member "--no-commit" args)))))
    ;; Run the merge with a default message first
    (madolt-merge--do-merge
     (if needs-message
         (format "Merge %s into %s" current branch)
       nil)
     merge-args)))

(defun madolt-merge-continue-command ()
  "Continue the current merge after resolving conflicts.
Stages all tables with `dolt add .' and commits.  If there are
still unresolved conflicts, reports an error.
When the merge was started via SQL, finalizes the SQL transaction."
  (interactive)
  (unless (madolt-merge-in-progress-p)
    (user-error "No merge in progress"))
  ;; Check for remaining conflicts
  (let ((conflicts (alist-get 'conflicts (madolt-status-tables))))
    (when conflicts
      (user-error "Cannot continue: %d table(s) still have conflicts: %s"
                  (length conflicts)
                  (mapconcat #'car conflicts ", "))))
  ;; Stage all resolved tables
  (let ((add-result (madolt-call-dolt "add" ".")))
    (unless (zerop (car add-result))
      (user-error "Failed to stage: %s" (string-trim (cdr add-result)))))
  ;; Commit the merge
  (let* ((msg (read-string "Merge commit message: "
                           (format "Merge into %s" (madolt-current-branch))))
         (result (madolt-call-dolt "commit" "-m" msg)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Merge committed: %s" msg)
      (message "Commit failed: %s" (string-trim (cdr result))))))

(defun madolt-merge-abort-command ()
  "Abort the current merge.
Uses `dolt sql -q' when a SQL server is running, since
`dolt merge --abort' CLI refuses to run alongside a server."
  (interactive)
  (let ((result (if (madolt-sql-server-info)
                    (madolt--run-cli
                     (list "sql" "-q" "CALL DOLT_MERGE('--abort')"))
                  (madolt-call-dolt "merge" "--abort"))))
    ;; Disconnect SQL to reset session state after abort
    (when (fboundp 'madolt-connection-disconnect)
      (madolt-connection-disconnect))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Merge aborted")
      (message "Abort failed: %s" (string-trim (cdr result))))))

(provide 'madolt-merge)
;;; madolt-merge.el ends here
