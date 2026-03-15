;;; madolt-cherry-pick.el --- Cherry-pick and revert for Madolt  -*- lexical-binding:t -*-

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

;; Cherry-pick and revert transient menus for madolt.
;;
;; Follows magit key conventions:
;;   A = cherry-pick, V = revert
;;
;; Uses `dolt cherry-pick' and `dolt revert' CLI commands.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

(declare-function madolt-commit-at-point "madolt-mode" ())

;;;; Cherry-pick transient

;;;###autoload (autoload 'madolt-cherry-pick "madolt-cherry-pick" nil t)
(transient-define-prefix madolt-cherry-pick ()
  "Apply changes from existing commits."
  ["Arguments"
   ("-e" "Allow empty" "--allow-empty")]
  ["Cherry-pick"
   ("A" "Cherry-pick"  madolt-cherry-pick-command)
   ("a" "Abort"        madolt-cherry-pick-abort-command)])

(defun madolt-cherry-pick-command (commit &optional args)
  "Cherry-pick COMMIT onto the current branch.
ARGS are additional arguments from the transient."
  (interactive
   (let ((default (madolt-commit-at-point)))
     (list (completing-read
            (format "Cherry-pick commit%s: "
                    (if default (format " (default %s)" default) ""))
            (madolt-all-ref-names) nil nil nil nil default)
           (transient-args 'madolt-cherry-pick))))
  (when (string-empty-p commit)
    (user-error "Commit must not be empty"))
  (let ((result (apply #'madolt-call-dolt "cherry-pick" commit args)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Cherry-picked %s" commit)
      (message "Cherry-pick failed: %s" (string-trim (cdr result))))))

(defun madolt-cherry-pick-abort-command ()
  "Abort the current cherry-pick."
  (interactive)
  (let ((result (madolt-call-dolt "cherry-pick" "--abort")))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Cherry-pick aborted")
      (message "Abort failed: %s" (string-trim (cdr result))))))

;;;; Revert transient

;;;###autoload (autoload 'madolt-revert "madolt-cherry-pick" nil t)
(transient-define-prefix madolt-revert ()
  "Revert the changes from existing commits."
  ["Revert"
   ("V" "Revert"  madolt-revert-command)])

(defun madolt-revert-command (commit)
  "Revert the change from COMMIT."
  (interactive
   (let ((default (madolt-commit-at-point)))
     (list (completing-read
            (format "Revert commit%s: "
                    (if default (format " (default %s)" default) ""))
            (madolt-all-ref-names) nil nil nil nil default))))
  (when (string-empty-p commit)
    (user-error "Commit must not be empty"))
  (let ((result (madolt-call-dolt "revert" commit)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Reverted %s" commit)
      (message "Revert failed: %s" (string-trim (cdr result))))))

(provide 'madolt-cherry-pick)
;;; madolt-cherry-pick.el ends here
