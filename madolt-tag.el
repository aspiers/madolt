;;; madolt-tag.el --- Tag commands for Madolt  -*- lexical-binding:t -*-

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

;; Tag transient menu and tag commands for madolt.
;;
;; Provides create (lightweight and annotated), delete, and list
;; operations via the `dolt tag' CLI command.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

(declare-function madolt-branch-or-commit-at-point "madolt-mode" ())

;;;; Transient menu

;;;###autoload (autoload 'madolt-tag "madolt-tag" nil t)
(transient-define-prefix madolt-tag ()
  "Manage Dolt tags."
  ["Arguments"
   ("-m" "Message" "-m")]
  ["Tag"
   ("t" "Create"  madolt-tag-create-command)
   ("k" "Delete"  madolt-tag-delete-command)
   ("l" "List"    madolt-tag-list-command)])

;;;; Interactive commands

(defun madolt-tag-create-command (name &optional args)
  "Create a tag named NAME at HEAD or a specified commit.
ARGS are additional arguments from the transient."
  (interactive
   (list (read-string "Tag name: ")
         (transient-args 'madolt-tag)))
  (when (string-empty-p name)
    (user-error "Tag name must not be empty"))
  (let* ((at-point (madolt-branch-or-commit-at-point))
         (ref (let ((r (completing-read
                        (format "Tag at (default %s): "
                                (or at-point "HEAD"))
                        (madolt-all-ref-names) nil nil nil nil
                        (or at-point "HEAD"))))
                (and (not (string-empty-p r))
                     (not (equal r "HEAD"))
                     r)))
         (msg-flag (seq-find (lambda (a) (string-prefix-p "-m" a)) args))
         (message (when msg-flag
                    (if (string-match "^-m\\(.+\\)" msg-flag)
                        (match-string 1 msg-flag)
                      (read-string "Tag message: "))))
         (result (madolt-tag-create name ref message)))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Created tag %s" name)
      (message "Tag creation failed: %s" (string-trim (cdr result))))))

(defun madolt-tag-delete-command (name)
  "Delete tag NAME after confirmation."
  (interactive
   (let ((tags (madolt-tag-names)))
     (if (null tags)
         (user-error "No tags to delete")
       (list (completing-read "Delete tag: " tags nil t)))))
  (when (yes-or-no-p (format "Delete tag %s? " name))
    (let ((result (madolt-tag-delete name)))
      (madolt-refresh)
      (if (zerop (car result))
          (message "Deleted tag %s" name)
        (message "Tag deletion failed: %s" (string-trim (cdr result)))))))

(defun madolt-tag-list-command ()
  "List all tags in the current database."
  (interactive)
  (let ((tags (madolt-tag-names)))
    (if (null tags)
        (message "No tags")
      (message "Tags: %s" (string-join tags ", ")))))

(provide 'madolt-tag)
;;; madolt-tag.el ends here
