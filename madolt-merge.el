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

;;;; Transient menu

;;;###autoload (autoload 'madolt-merge "madolt-merge" nil t)
(transient-define-prefix madolt-merge ()
  "Merge branches."
  ["Arguments"
   ("-n" "No fast-forward"  "--no-ff")
   ("-f" "Fast-forward only" "--ff-only")
   ("-s" "Squash"           "--squash")
   ("-c" "No commit"        "--no-commit")]
  ["Merge"
   ("m" "Merge"             madolt-merge-command)
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
  (condition-case err
      (when (and (fboundp 'madolt-connection-ensure)
                 (funcall 'madolt-connection-ensure))
        (let ((query-fn (symbol-function 'madolt-connection-query)))
          ;; Disable autocommit so conflicts don't cause rollback
          (funcall query-fn "SET @@autocommit = 0")
          (let* ((sql-args (list (format "'%s'" branch)))
                 (_ (dolist (flag flags)
                      (push (format "'%s'" flag) sql-args)))
                 (_ (when message
                      (push "'-m'" sql-args)
                      (push (format "'%s'" message) sql-args)))
                 (sql (format "CALL DOLT_MERGE(%s)"
                              (mapconcat #'identity
                                         (nreverse sql-args) ", ")))
                 ;; Merge can be very slow for large databases
                 (rows (funcall query-fn sql 300))
                 (output (mapconcat
                          (lambda (row) (string-join row "\t"))
                          rows "\n"))
                 ;; DOLT_MERGE returns: hash, fast_forward, conflicts, message
                 ;; But column count varies; detect conflicts by checking
                 ;; for "conflict" in any column value
                 (has-conflicts
                  (and rows
                       (cl-some (lambda (col)
                                  (string-match-p "conflict" col))
                                (car rows)))))
            (if has-conflicts
                ;; Abort the merge and report conflict
                (progn
                  (funcall query-fn "CALL DOLT_MERGE('--abort')" 60)
                  (funcall query-fn "SET @@autocommit = 1" 10)
                  (cons 1 (format "Merge conflict: %s"
                                  (string-join (car rows) " "))))
              ;; Commit and re-enable autocommit
              (funcall query-fn "COMMIT" 30)
              (funcall query-fn "SET @@autocommit = 1" 10)
              (cons 0 (concat output "\n"))))))
    (error
     (when (fboundp 'madolt-connection-disconnect)
       (funcall 'madolt-connection-disconnect))
     (when (fboundp 'madolt-connection--log)
       (funcall 'madolt-connection--log
                "SQL merge failed; trying CLI"
                (format "DOLT_MERGE: %s" (error-message-string err))))
     nil)))

(defun madolt-merge--do-merge (message args)
  "Execute `dolt merge' with MESSAGE and ARGS.
ARGS should already include the branch to merge."
  (let* ((head-before (madolt-dolt-string "log" "-n" "1" "--oneline"))
         ;; Extract the branch name (last non-flag arg)
         (branch (car (last (cl-remove-if
                             (lambda (a) (string-prefix-p "-" a))
                             args))))
         (flags (cl-remove-if-not
                 (lambda (a) (string-prefix-p "-" a))
                 args))
         ;; Try SQL first (with autocommit handling), fall back to CLI
         (result (or (and (bound-and-true-p madolt-use-sql-server)
                          (madolt-merge--via-sql branch message flags))
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
            ;; Log to process buffer so `$` shows the error
            (madolt--process-insert-section
             (list "merge" branch) 1 failure)
            (user-error "Merge failed: %s" failure))
        (message "Merged %s into %s" branch
                 (madolt-current-branch))))))

(defun madolt-merge-command (branch &optional args)
  "Merge BRANCH into the current branch.
ARGS are additional arguments from the transient.
Opens a buffer to edit the merge commit message, unless
--squash or --no-commit is set."
  (interactive
   (list (completing-read
          (format "Merge into %s: " (madolt-current-branch))
          (remove (madolt-current-branch) (madolt-all-ref-names))
          nil nil)
         (transient-args 'madolt-merge)))
  (let ((current (madolt-current-branch))
        (merge-args (append args (list branch))))
    (if (or (member "--squash" args)
            (member "--no-commit" args))
        ;; No commit message needed
        (madolt-merge--do-merge nil merge-args)
      ;; Open buffer for merge message editing
      (madolt-commit--setup-buffer
       (format "Merge %s into %s" branch current)
       merge-args
       nil
       #'madolt-merge--do-merge
       #'madolt-merge--buffer-name))))

(defun madolt-merge-abort-command ()
  "Abort the current merge."
  (interactive)
  (let ((result (madolt-call-dolt "merge" "--abort")))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Merge aborted")
      (message "Abort failed: %s" (string-trim (cdr result))))))

(provide 'madolt-merge)
;;; madolt-merge.el ends here
