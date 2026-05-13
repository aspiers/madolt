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
        ;; Parse CSV output: header is "hash,fast_forward,conflicts,message"
        ;; followed by a data row like "abc123,0,0,merge successful".
        ;; Extract the conflicts column value to detect real conflicts,
        ;; and return the message column (not raw CSV) to avoid
        ;; downstream false positives from the "conflicts" header word.
        (let* ((lines (and output (split-string output "\n" t)))
               (data-line (cadr lines))
               (fields (and data-line (split-string data-line ",")))
               (conflicts-val (and fields (nth 2 fields)))
               (has-conflicts (and conflicts-val
                                   (not (string= "0" (string-trim conflicts-val)))))
               ;; Message is everything after the 3rd comma (may contain commas)
               (msg (when data-line
                      (let ((pos 0))
                        (dotimes (_ 3)
                          (when pos
                            (setq pos (string-search "," data-line pos))
                            (when pos (cl-incf pos))))
                        (if pos
                            (substring data-line pos)
                          "")))))
          (if has-conflicts
              (cons 1 (format "Merge conflict with %s" branch))
            (cons 0 (or msg output ""))))))))

(defun madolt-merge--do-merge (message args)
  "Execute `dolt merge' with MESSAGE and ARGS.
ARGS should already include the branch to merge.
MESSAGE may be nil to use dolt's auto-generated message.
Returns a plist (:failure FAILURE :head-changed BOOL :conflicts LIST
:staged LIST :merge-in-progress BOOL) so callers can make decisions
without redundant CLI calls."
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
    (let* ((head-changed (not (equal head-before head-after)))
           (failure
            (cond
             ((not (zerop (car result)))
              output)
             ((string-match-p "\\(conflict\\|error\\|rolled back\\)" output)
              output)
             ;; Skip HEAD check for --squash/--no-commit (they don't change HEAD)
             ((and (not head-changed)
                   (not (member "--squash" flags))
                   (not (member "--no-commit" flags)))
              "HEAD unchanged (merge may have failed silently)"))))
      (madolt-refresh)
      ;; Collect post-refresh state once for both our messages and the caller.
      ;; Use a single madolt-status-tables call after refresh rather than
      ;; the multiple redundant calls that previously caused multi-second hangs.
      (let ((status (madolt-status-tables))
            merge-in-progress)
        (let ((conflicts (alist-get 'conflicts status))
              (staged (alist-get 'staged status)))
          ;; Only check merge-in-progress if we'll actually need it:
          ;; when there's no failure and no conflicts and HEAD didn't change.
          ;; Inline the check rather than calling madolt-merge-in-progress-p,
          ;; which would redundantly re-fetch status tables and raw status.
          (when (and (not failure) (not conflicts) (not head-changed))
            (let ((raw-output (cdr (madolt--run "status"))))
              (setq merge-in-progress
                    (and raw-output
                         (or (string-match-p "You have unmerged tables"
                                             raw-output)
                             (string-match-p "still merging"
                                             raw-output))))))
          (if failure
              (progn
                ;; Log to process buffer and display it
                (madolt--process-insert-section
                 (list "merge" branch) 1 failure)
                (madolt-process-buffer)
                (message "Merge failed: %s"
                         (truncate-string-to-width failure 80 nil nil "...")))
            (if (and (member "--no-commit" flags)
                     (not head-changed))
                ;; --no-commit stopped before creating the merge commit
                (message "Merge of %s staged (commit pending)" branch)
              (message "Merged %s into %s" branch
                       (madolt-current-branch))))
          (list :failure failure
                :head-changed head-changed
                :conflicts conflicts
                :staged staged
                :merge-in-progress merge-in-progress))))))

(defun madolt-merge--do-commit (message _args)
  "Commit a pending merge with MESSAGE.
Ignores _ARGS since the merge is already staged.
Used as the finish function for the merge commit buffer."
  ;; Save to message history
  (ring-insert madolt-commit--message-ring message)
  (madolt-run-dolt "commit" "-m" message))

(defun madolt-merge-command (branch &optional args)
  "Merge BRANCH into the current branch.
ARGS are additional arguments from the transient.
With --squash or --no-commit, runs the merge directly.
Otherwise, runs merge with --no-commit first, then opens a
commit message buffer (like magit) for non-fast-forward merges."
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
         (needs-buffer (not (or (member "--squash" args)
                                (member "--no-commit" args)))))
    (if (not needs-buffer)
        ;; --squash or --no-commit: run directly, no message needed
        (madolt-merge--do-merge nil merge-args)
      ;; Normal merge: run with --no-commit, then open buffer if needed.
      ;; --no-commit has no effect on fast-forward merges (they just
      ;; complete immediately), so the buffer only opens for real merges.
      (let* ((no-commit-args (cons "--no-commit" merge-args))
             (merge-result (madolt-merge--do-merge nil no-commit-args)))
        ;; Use the result from do-merge instead of re-querying.
        (when (and (not (plist-get merge-result :head-changed))
                   ;; HEAD didn't change — could be a pending merge
                   ;; (non-FF stopped by --no-commit) or a failure.
                   ;; Only open the buffer if we're pending a commit
                   ;; with no unresolved conflicts.
                   (not (plist-get merge-result :failure))
                   (not (plist-get merge-result :conflicts))
                   (or (plist-get merge-result :merge-in-progress)
                       (plist-get merge-result :staged)))
          (madolt-commit--setup-buffer
           (format "Merge %s into %s" branch current)
           nil nil
           #'madolt-merge--do-commit
           #'madolt-merge--buffer-name))))))

(defun madolt-merge-continue-command ()
  "Continue the current merge after resolving conflicts.
Stages all tables with `dolt add .' and opens a commit message
buffer.  If there are still unresolved conflicts, reports an error.
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
  ;; Open commit buffer for the merge message
  (madolt-commit--setup-buffer
   (format "Merge into %s" (madolt-current-branch))
   nil nil
   #'madolt-merge--do-commit
   #'madolt-merge--buffer-name))

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
