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
  ["Rebase"
   :if-not madolt-rebase-in-progress-p
   ("r" "Rebase onto"  madolt-rebase-command)]
  ["Actions"
   :if madolt-rebase-in-progress-p
   ("c" "Continue"     madolt-rebase-continue-command)
   ("a" "Abort"        madolt-rebase-abort-command)])

;;;; Interactive commands

(defun madolt-rebase-command (upstream &optional args)
  "Rebase current branch onto UPSTREAM.
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
            (remove current (madolt-branch-names))
            nil t nil nil default)
           (transient-args 'madolt-rebase))))
  (when (string-empty-p upstream)
    (user-error "Must specify an upstream branch"))
  (let ((result (apply #'madolt-call-dolt "rebase" (append args (list upstream)))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebased %s onto %s" (madolt-current-branch) upstream)
      (message "Rebase failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-continue-command ()
  "Continue a rebase after resolving conflicts or adjusting the plan."
  (interactive)
  (let ((result (madolt-call-dolt "rebase" "--continue")))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebase continued successfully")
      (message "Continue failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-abort-command ()
  "Abort the current rebase."
  (interactive)
  (let ((result (madolt-call-dolt "rebase" "--abort")))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebase aborted")
      (message "Abort failed: %s" (string-trim (cdr result))))))

(provide 'madolt-rebase)
;;; madolt-rebase.el ends here
