;;; madolt-branch.el --- Branch commands for Madolt  -*- lexical-binding:t -*-

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

;; Branch transient menu and branch commands for madolt.
;;
;; Provides create, checkout, delete, and rename operations via the
;; `dolt branch' and `dolt checkout' CLI commands.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

(declare-function madolt-branch-at-point "madolt-mode" ())
(declare-function madolt-branch-or-commit-at-point "madolt-mode" ())

;;;; Transient menu

;;;###autoload (autoload 'madolt-branch "madolt-branch" nil t)
(transient-define-prefix madolt-branch ()
  "Manage Dolt branches."
  ["Branch"
   ("b" "Checkout"              madolt-branch-checkout-command)
   ("c" "Create & checkout"     madolt-branch-checkout-create-command)
   ("n" "Create (no checkout)"  madolt-branch-create-command)
   ("k" "Delete"                madolt-branch-delete-command)
   ("m" "Rename"                madolt-branch-rename-command)])

;;;; Interactive commands

(defun madolt-branch-checkout-command (branch)
  "Switch to BRANCH."
  (interactive
   (list (completing-read "Checkout branch: " (madolt-branch-names)
                          nil t nil nil
                          (or (madolt-branch-at-point)
                              (madolt-current-branch)))))
  (madolt-run-dolt "checkout" branch)
  (message "Switched to branch %s" branch))

(defun madolt-branch-checkout-create-command (name &optional start-point)
  "Create and switch to a new branch NAME.
Optional START-POINT specifies the starting commit or branch."
  (interactive
   (let ((default (madolt-branch-or-commit-at-point)))
     (list (read-string "Create and checkout branch: ")
           (let ((start (read-string
                         (format "Starting point%s: "
                                 (if default
                                     (format " (default %s)" default)
                                   " (default HEAD)"))
                         nil nil (or default "HEAD"))))
             (and (not (string-empty-p start))
                  (not (equal start "HEAD"))
                  start)))))
  (if start-point
      (madolt-run-dolt "checkout" "-b" name start-point)
    (madolt-run-dolt "checkout" "-b" name))
  (message "Switched to new branch %s" name))

(defun madolt-branch-create-command (name &optional start-point)
  "Create a new branch NAME without switching to it.
Optional START-POINT specifies the starting commit or branch."
  (interactive
   (let ((default (madolt-branch-or-commit-at-point)))
     (list (read-string "Create branch: ")
           (let ((start (read-string
                         (format "Starting point%s: "
                                 (if default
                                     (format " (default %s)" default)
                                   " (default HEAD)"))
                         nil nil (or default "HEAD"))))
             (and (not (string-empty-p start))
                  (not (equal start "HEAD"))
                  start)))))
  (if start-point
      (madolt-run-dolt "branch" name start-point)
    (madolt-run-dolt "branch" name))
  (message "Created branch %s" name))

(defun madolt-branch-delete-command (name)
  "Delete branch NAME after confirmation."
  (interactive
   (let* ((current (madolt-current-branch))
          (at-point (madolt-branch-at-point))
          (default (and at-point
                        (not (equal at-point current))
                        at-point)))
     (list (completing-read "Delete branch: "
                            (remove current (madolt-branch-names))
                            nil t nil nil default))))
  (when (yes-or-no-p (format "Delete branch %s? " name))
    (let ((result (madolt-call-dolt "branch" "-d" name)))
      (if (zerop (car result))
          (progn
            (madolt-refresh)
            (message "Deleted branch %s" name))
        ;; Deletion failed — offer force delete
        (when (yes-or-no-p
               (format "Branch %s is not fully merged.  Force delete? " name))
          (madolt-run-dolt "branch" "-D" name)
          (message "Force deleted branch %s" name))))))

(defun madolt-branch-rename-command (old-name new-name)
  "Rename branch OLD-NAME to NEW-NAME."
  (interactive
   (let ((old (completing-read "Rename branch: " (madolt-branch-names)
                               nil t nil nil
                               (or (madolt-branch-at-point)
                                   (madolt-current-branch)))))
     (list old (read-string (format "Rename %s to: " old)))))
  (madolt-run-dolt "branch" "-m" old-name new-name)
  (message "Renamed branch %s to %s" old-name new-name))

(provide 'madolt-branch)
;;; madolt-branch.el ends here
