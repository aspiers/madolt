;;; madolt-reset.el --- Reset commands for Madolt  -*- lexical-binding:t -*-

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

;; Reset transient menu and reset commands for madolt.
;;
;; Provides:
;; - Soft reset: moves HEAD to a revision without changing working set
;; - Hard reset: resets working set, staging, and HEAD to a revision
;; - Mixed reset (default): unstages all tables (equivalent to dolt reset .)

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

;;;; Transient menu

;;;###autoload (autoload 'madolt-reset "madolt-reset" nil t)
(transient-define-prefix madolt-reset ()
  "Reset HEAD to a specified state."
  ["Reset"
   ("s" "Soft"  madolt-reset-soft-command)
   ("h" "Hard"  madolt-reset-hard-command)
   ("m" "Mixed" madolt-reset-mixed-command)])

;;;; Interactive commands

(defun madolt-reset-soft-command (revision)
  "Soft reset HEAD to REVISION.
Moves HEAD without changing the working set or staging area."
  (interactive
   (list (madolt-reset--read-revision "Soft reset to")))
  (let ((result (madolt-call-dolt "reset" "--soft" revision)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Soft reset to %s" revision)
      (message "Reset failed: %s" (string-trim (cdr result))))))

(defun madolt-reset-hard-command (revision)
  "Hard reset to REVISION.
Resets HEAD, staging area, and working set.  Uncommitted changes
are permanently lost."
  (interactive
   (list (madolt-reset--read-revision "Hard reset to")))
  (unless (yes-or-no-p
           (format "Hard reset to %s? All uncommitted changes will be lost. "
                   revision))
    (user-error "Aborted"))
  (let ((result (madolt-call-dolt "reset" "--hard" revision)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Hard reset to %s" revision)
      (message "Reset failed: %s" (string-trim (cdr result))))))

(defun madolt-reset-mixed-command ()
  "Mixed reset: unstage all staged tables.
Equivalent to `dolt reset .' — resets staging area to HEAD
without changing the working set."
  (interactive)
  (let ((result (madolt-call-dolt "reset" ".")))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Reset staging area")
      (message "Reset failed: %s" (string-trim (cdr result))))))

;;;; Helpers

(defun madolt-reset--read-revision (prompt)
  "Read a revision (branch or commit) with PROMPT."
  (completing-read (concat prompt ": ")
                   (madolt-branch-names)
                   nil nil nil nil "HEAD"))

(provide 'madolt-reset)
;;; madolt-reset.el ends here
