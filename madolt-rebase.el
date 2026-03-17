;;; madolt-rebase.el --- Rebase commands for Madolt  -*- lexical-binding:t -*-

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

;; Rebase transient menu and rebase commands for madolt.
;;
;; Provides rebase onto another branch, continue/abort an in-progress
;; rebase, and common flags via the `dolt rebase' CLI command.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

(declare-function madolt-branch-or-commit-at-point "madolt-mode" ())

;;;; Transient menu

;;;###autoload (autoload 'madolt-rebase "madolt-rebase" nil t)
(transient-define-prefix madolt-rebase ()
  "Rebase the current branch."
  ["Arguments"
   :if-not madolt-rebase-in-progress-p
   ("-i" "Interactive"          "--interactive")
   ("-e" "Empty commits: keep"  "--empty=keep")]
  [:if-not madolt-rebase-in-progress-p
   :description (lambda ()
                  (format (propertize "Rebase %s onto" 'face 'transient-heading)
                          (propertize (or (madolt-current-branch) "HEAD")
                                      'face 'madolt-branch-local)))
   ("e" "elsewhere"  madolt-rebase-elsewhere)]
  ["Rebase"
   :if-not madolt-rebase-in-progress-p
   ("i" "interactively"  madolt-rebase-interactive)]
  ["Actions"
   :if madolt-rebase-in-progress-p
   ("r" "Continue"     madolt-rebase-continue-command)
   ("s" "Skip"         madolt-rebase-skip-command)
   ("a" "Abort"        madolt-rebase-abort-command)])

;;;; Interactive commands

(defun madolt-rebase-elsewhere (upstream &optional args)
  "Rebase current branch onto UPSTREAM.
UPSTREAM can be a branch name or commit hash.
ARGS are additional arguments from the transient."
  (interactive
   (let* ((current (madolt-current-branch))
          (at-point (madolt-branch-or-commit-at-point))
          (default (and at-point
                        (not (equal at-point current))
                        at-point)))
     (list (completing-read
            (format "Rebase %s onto%s: " current
                    (if default (format " (default %s)" default) ""))
            (append (remove current (madolt-branch-names))
                    (madolt-all-ref-names))
            nil nil nil nil default)
           (transient-args 'madolt-rebase))))
  (when (string-empty-p upstream)
    (user-error "Must specify an upstream branch"))
  (let ((result (apply #'madolt-call-dolt "rebase" (append args (list upstream)))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebased %s onto %s" (madolt-current-branch) upstream)
      (message "Rebase failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-interactive (upstream &optional _args)
  "Start an interactive rebase of current branch onto UPSTREAM.
Uses the SQL DOLT_REBASE procedure to create a rebase plan in the
dolt_rebase system table.  The plan can then be edited via SQL and
applied with `dolt rebase --continue'.
_ARGS are accepted for transient compatibility but unused since
interactive rebase uses SQL directly."
  (interactive
   (let* ((current (madolt-current-branch))
          (at-point (madolt-branch-or-commit-at-point))
          (default (and at-point
                        (not (equal at-point current))
                        at-point)))
     (list (if default
               ;; Use the commit/branch at point without prompting
               default
             (completing-read
              (format "Rebase %s onto interactively: " current)
              (append (remove current (madolt-branch-names))
                      (madolt-all-ref-names))
              nil nil nil nil nil))
           (transient-args 'madolt-rebase))))
  (when (string-empty-p upstream)
    (user-error "Must specify an upstream branch"))
  ;; Use SQL DOLT_REBASE because the CLI interactive rebase requires
  ;; $EDITOR which Dolt v1.82.x doesn't support properly.
  (let* ((branch (madolt-current-branch))
         (query (format "CALL DOLT_REBASE('-i', '%s')"
                        (replace-regexp-in-string "'" "''" upstream)))
         (result (madolt-call-dolt "sql" "-q" query)))
    (if (zerop (car result))
        (progn
          (madolt-refresh)
          (message "Interactive rebase started on dolt_rebase_%s; edit the plan in dolt_rebase table, then r r to continue"
                   branch))
      (madolt-refresh)
      (message "Rebase failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-continue-command ()
  "Continue a rebase after resolving conflicts or adjusting the plan.
Tries SQL DOLT_REBASE first (for SQL-initiated rebases), then
falls back to CLI."
  (interactive)
  (let* ((branch (madolt-current-branch))
         (sql-rebase (and branch
                         (member (concat "dolt_rebase_" branch)
                                 (madolt-branch-names))))
         (result (if sql-rebase
                     (madolt-call-dolt "sql" "-q"
                                       "CALL DOLT_REBASE('--continue')")
                   (madolt-call-dolt "rebase" "--continue"))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebase continued successfully")
      (message "Continue failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-skip-command ()
  "Skip the current commit in a rebase."
  (interactive)
  ;; Dolt doesn't have --skip; drop the current commit from the
  ;; rebase plan via SQL update, then continue.
  (let ((result (madolt-call-dolt "sql" "-q"
                                  "UPDATE dolt_rebase SET action = 'drop' WHERE rebase_order = (SELECT MIN(rebase_order) FROM dolt_rebase WHERE action = 'pick')")))
    (if (zerop (car result))
        (madolt-rebase-continue-command)
      (message "Skip failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-abort-command ()
  "Abort the current rebase.
Tries SQL DOLT_REBASE first (for SQL-initiated rebases), then
falls back to CLI."
  (interactive)
  (let* ((branch (madolt-current-branch))
         (sql-rebase (and branch
                         (member (concat "dolt_rebase_" branch)
                                 (madolt-branch-names))))
         (result (if sql-rebase
                     (madolt-call-dolt "sql" "-q"
                                       "CALL DOLT_REBASE('--abort')")
                   (madolt-call-dolt "rebase" "--abort"))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebase aborted")
      (message "Abort failed: %s" (string-trim (cdr result))))))

(provide 'madolt-rebase)
;;; madolt-rebase.el ends here
