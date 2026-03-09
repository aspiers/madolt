;;; madolt-stash.el --- Stash commands for Madolt  -*- lexical-binding:t -*-

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

;; Stash transient menu and stash commands for madolt.
;;
;; Provides create, pop, drop, clear, and list stash operations
;; via the `dolt stash' CLI command.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

;;;; Transient menu

;;;###autoload (autoload 'madolt-stash "madolt-stash" nil t)
(transient-define-prefix madolt-stash ()
  "Stash uncommitted changes."
  ["Arguments"
   ("-u" "Include untracked" "--include-untracked")
   ("-a" "All (including ignored)" "--all")]
  ["Stash"
   ("z" "Stash"     madolt-stash-create-command)
   ("p" "Pop"       madolt-stash-pop-command)
   ("k" "Drop"      madolt-stash-drop-command)
   ("x" "Clear all" madolt-stash-clear-command)
   ("l" "List"      madolt-stash-list-command)])

;;;; Interactive commands

(defun madolt-stash-create-command (&optional args)
  "Stash current changes.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-stash)))
  (let ((result (apply #'madolt-call-dolt "stash" args)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Stashed changes")
      (message "Stash failed: %s" (string-trim (cdr result))))))

(defun madolt-stash-pop-command (&optional stash-ref)
  "Pop the most recent stash, or STASH-REF if specified."
  (interactive
   (list (let ((input (read-string "Pop stash (default 0): ")))
           (if (string-empty-p input) "0" input))))
  (let ((result (madolt-call-dolt "stash" "pop" (or stash-ref "0"))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Popped stash %s" (or stash-ref "0"))
      (message "Pop failed: %s" (string-trim (cdr result))))))

(defun madolt-stash-drop-command (&optional stash-ref)
  "Drop stash STASH-REF after confirmation."
  (interactive
   (list (let ((input (read-string "Drop stash (default 0): ")))
           (if (string-empty-p input) "0" input))))
  (let ((ref (or stash-ref "0")))
    (when (yes-or-no-p (format "Drop stash %s? " ref))
      (let ((result (madolt-call-dolt "stash" "drop" ref)))
        (madolt-refresh)
        (if (zerop (car result))
            (message "Dropped stash %s" ref)
          (message "Drop failed: %s" (string-trim (cdr result))))))))

(defun madolt-stash-clear-command ()
  "Clear all stashes after confirmation."
  (interactive)
  (when (yes-or-no-p "Clear ALL stashes? ")
    (let ((result (madolt-call-dolt "stash" "clear")))
      (madolt-refresh)
      (if (zerop (car result))
          (message "All stashes cleared")
        (message "Clear failed: %s" (string-trim (cdr result)))))))

(defun madolt-stash-list-command ()
  "List all stashes in the message area."
  (interactive)
  (let ((lines (madolt-dolt-lines "stash" "list")))
    (if (null lines)
        (message "No stashes")
      (message "%s" (string-join lines "\n")))))

(provide 'madolt-stash)
;;; madolt-stash.el ends here
