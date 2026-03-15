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
          ;; Combine SET and MERGE into one batch to avoid SET producing
          ;; no output (which causes the query to time out waiting for
          ;; output that never comes in mysql batch mode).
          (let* ((sql-args (list (format "'%s'" branch)))
                 (_ (dolist (flag flags)
                      (push (format "'%s'" flag) sql-args)))
                 (_ (when message
                      (push "'-m'" sql-args)
                      (push (format "'%s'" message) sql-args)))
                 (sql (format "CALL DOLT_MERGE(%s)"
                              (mapconcat #'identity
                                         (nreverse sql-args) ", ")))
                 (full-sql (concat "SET @@autocommit = 0;\n" sql))
                 ;; Merge can be slow on large databases
                 (rows (funcall query-fn full-sql 60))
                 (output (mapconcat
                          (lambda (row) (string-join row "\t"))
                          rows "\n"))
                 ;; DOLT_MERGE returns: hash, fast_forward, conflicts, message
                 ;; The hash column may be empty and trimmed by the parser,
                 ;; so detect conflicts by checking for "conflict" in any
                 ;; column value, or a non-zero numeric conflicts column.
                 (conflict-msg
                  (and rows
                       (let ((row (car rows)))
                         (or
                          ;; Check for "conflict" keyword in message column
                          (cl-some (lambda (col)
                                     (and (string-match-p "conflict" col)
                                          col))
                                   row)
                          ;; Check for numeric conflicts > 0
                          (cl-some (lambda (col)
                                     (and (string-match-p "\\`[0-9]+\\'" col)
                                          (> (string-to-number col) 0)
                                          (format "%s conflict(s)" col)))
                                   row))))))
            (if conflict-msg
                ;; Report conflict; disconnect to reset session state
                ;; (DOLT_MERGE('--abort') can be very slow on large databases,
                ;; so we just disconnect instead, which rolls back the transaction)
                (progn
                  (when (fboundp 'madolt-connection-disconnect)
                    (funcall 'madolt-connection-disconnect))
                  (cons 1 (format "Merge conflict with %s: %s"
                                  branch conflict-msg)))
              ;; Commit and re-enable autocommit.
              ;; COMMIT/SET produce no output in batch mode, so combine
              ;; with a SELECT to get detectable output.
              (funcall query-fn
                       "COMMIT; SET @@autocommit = 1; SELECT 'ok'" 30)
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
   (list (completing-read
          (format "Merge into %s: " (madolt-current-branch))
          (remove (madolt-current-branch) (madolt-all-ref-names))
          nil nil)
         (transient-args 'madolt-merge)))
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
