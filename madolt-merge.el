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

(defun madolt-merge-command (branch &optional args)
  "Merge BRANCH into the current branch.
ARGS are additional arguments from the transient."
  (interactive
   (list (completing-read
          (format "Merge into %s: " (madolt-current-branch))
          (remove (madolt-current-branch) (madolt-all-ref-names))
          nil nil)
         (transient-args 'madolt-merge)))
  (let* ((msg-arg (and (not (member "--squash" args))
                       (not (member "--no-commit" args))
                       (read-string "Merge message (empty for default): ")))
         (all-args (append args
                          (when (and msg-arg (not (string-empty-p msg-arg)))
                            (list "-m" msg-arg))
                          (list branch)))
         (result (apply #'madolt-call-dolt "merge" all-args)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Merged %s into %s" branch (madolt-current-branch))
      (message "Merge failed: %s" (string-trim (cdr result))))))

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
