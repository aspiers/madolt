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

(defun madolt-merge--do-merge (message args)
  "Execute `dolt merge' with MESSAGE and ARGS.
ARGS should already include the branch to merge."
  (let* ((head-before (madolt-dolt-string "log" "-n" "1" "--oneline"))
         (all-args (if (and message (not (string-empty-p message)))
                       (append (list "-m" message) args)
                     args))
         (result (apply #'madolt-call-dolt "merge" all-args))
         (output (madolt--clean-output (cdr result)))
         ;; Extract the branch name (last non-flag arg)
         (branch (car (last (cl-remove-if
                             (lambda (a) (string-prefix-p "-" a))
                             args))))
         (head-after (madolt-dolt-string "log" "-n" "1" "--oneline")))
    ;; Reset SQL connection after merge to avoid stale session state
    ;; (DOLT_MERGE can leave the connection in a bad state on conflict)
    (when (fboundp 'madolt-connection-disconnect)
      (madolt-connection-disconnect))
    (madolt-refresh)
    ;; Message after refresh so it's not overwritten by "Refreshing...done"
    (cond
     ;; Non-zero exit code (CLI failure)
     ((not (zerop (car result)))
      (message "Merge failed: %s" output))
     ;; SQL path: error or conflict in output text
     ((string-match-p "\\(conflict\\|error\\|rolled back\\)" output)
      (message "Merge failed: %s" output))
     ;; HEAD didn't change — merge silently did nothing
     ((equal head-before head-after)
      (message "Merge failed: HEAD unchanged (possible conflict with autocommit)"))
     (t
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
