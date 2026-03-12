;;; madolt-refs.el --- References buffer for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7"))

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

;; References buffer for madolt.  Displays local branches, remote
;; branches, and tags in a navigable section-based buffer.
;; Bound to `y' in madolt-mode, mirroring magit-show-refs.

;;; Code:

(require 'magit-section)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-mode)

;;;; Faces

(defface madolt-branch-local
  '((t :foreground "LightSkyBlue1"))
  "Face for local branch names in refs buffers."
  :group 'madolt-faces)

(defface madolt-branch-remote
  '((t :foreground "DarkSeaGreen2"))
  "Face for remote branch names in refs buffers."
  :group 'madolt-faces)

(defface madolt-branch-current
  '((t :inherit madolt-branch-local :box t))
  "Face for the current branch in refs buffers."
  :group 'madolt-faces)

(defface madolt-tag
  '((t :foreground "Khaki"))
  "Face for tag names in refs buffers."
  :group 'madolt-faces)

;;;; Customization

(defcustom madolt-refs-primary-column-width '(16 . 32)
  "Width of the primary column in refs buffers.
If an integer, the column is that many columns wide.  Otherwise
it must be a cons cell (MIN . MAX), in which case the column is
auto-sized to fit the longest branch name, clamped to that range."
  :group 'madolt
  :type '(choice integer (cons integer integer)))

;;;; Refs mode

(define-derived-mode madolt-refs-mode madolt-mode "Madolt Refs"
  "Mode for madolt refs buffers.")

;;;; Transient menu

;;;###autoload (autoload 'madolt-show-refs "madolt-refs" nil t)
(transient-define-prefix madolt-show-refs (&optional transient)
  "List references.
Without a prefix argument, directly show the refs buffer
comparing against HEAD.  With a prefix argument (or when already
in a refs buffer), show the transient menu to choose options."
  ["Actions"
   ("y" "Show refs for HEAD"           madolt-show-refs-head)
   ("c" "Show refs for current branch" madolt-show-refs-current)
   ("o" "Show refs for other branch"   madolt-show-refs-other)]
  (interactive (list (or (derived-mode-p 'madolt-refs-mode)
                         current-prefix-arg)))
  (if transient
      (transient-setup 'madolt-show-refs)
    (madolt-refs--show "HEAD")))

;;;; Commands

(defvar-local madolt-refs--upstream nil
  "The reference to compare against in this refs buffer.")

(defun madolt-show-refs-head ()
  "Show refs comparing against HEAD."
  (interactive)
  (madolt-refs--show "HEAD"))

(defun madolt-show-refs-current ()
  "Show refs comparing against the current branch."
  (interactive)
  (madolt-refs--show (or (madolt-current-branch) "HEAD")))

(defun madolt-show-refs-other (ref)
  "Show refs comparing against REF."
  (interactive
   (list (completing-read "Show refs for: " (madolt-branch-names))))
  (madolt-refs--show ref))

;;;; Buffer setup

(defun madolt-refs--show (upstream)
  "Show refs buffer comparing against UPSTREAM."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (db-name (file-name-nondirectory
                   (directory-file-name db-dir)))
         (buf-name (format "madolt-refs: %s" db-name))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-refs-mode)
        (madolt-refs-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-refs--upstream upstream)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-refs-refresh-buffer ()
  "Refresh the refs buffer."
  (let ((branches (madolt-branch-list-verbose))
        (tags (madolt-tag-list-verbose)))
    (magit-insert-section (refs)
      (magit-insert-heading
        (format "References for %s:" (or madolt-refs--upstream "HEAD")))
      (madolt-refs--insert-local-branches
       (cl-remove-if (lambda (b) (plist-get b :remote)) branches))
      (madolt-refs--insert-remote-branches
       (cl-remove-if-not (lambda (b) (plist-get b :remote)) branches))
      (madolt-refs--insert-tags tags))))

;;;; Section inserters

(defun madolt-refs--column-width (names)
  "Return the column width for displaying NAMES.
Uses `madolt-refs-primary-column-width' to determine the width.
NAMES is a list of strings whose lengths determine auto-sizing."
  (let ((width (if names
                   (apply #'max (mapcar #'length names))
                 0)))
    (if (consp madolt-refs-primary-column-width)
        (min (max width (car madolt-refs-primary-column-width))
             (cdr madolt-refs-primary-column-width))
      madolt-refs-primary-column-width)))

(defun madolt-refs--insert-local-branches (branches)
  "Insert a section listing local BRANCHES."
  (when branches
    (let ((col-width (madolt-refs--column-width
                      (mapcar (lambda (b) (plist-get b :name)) branches))))
      (magit-insert-section (local nil t)
        (magit-insert-heading "Branches:")
        (dolist (branch branches)
          (let* ((name (plist-get branch :name))
                 (message (plist-get branch :message))
                 (current (plist-get branch :current))
                 (face (if current 'madolt-branch-current 'madolt-branch-local))
                 (padded (truncate-string-to-width name col-width nil ?\s)))
            (magit-insert-section (branch name)
              (magit-insert-heading
                (concat
                 (if current "* " "  ")
                 (propertize padded 'font-lock-face face)
                 " " (or message "")
                 "\n")))))
        (insert "\n")))))

(defun madolt-refs--insert-remote-branches (branches)
  "Insert a section listing remote BRANCHES."
  (when branches
    ;; Group by remote
    (let ((by-remote (make-hash-table :test 'equal)))
      (dolist (branch branches)
        (let ((remote (plist-get branch :remote)))
          (push branch (gethash remote by-remote))))
      (maphash
       (lambda (remote remote-branches)
         (let* ((rbranches (nreverse remote-branches))
                (col-width (madolt-refs--column-width
                            (mapcar (lambda (b)
                                      (format "%s/%s" remote
                                              (plist-get b :name)))
                                    rbranches))))
           (magit-insert-section (remote remote t)
             (magit-insert-heading (format "Remote %s:" remote))
             (dolist (branch rbranches)
               (let* ((name (plist-get branch :name))
                      (message (plist-get branch :message))
                      (display-name (format "%s/%s" remote name))
                      (padded (truncate-string-to-width
                               display-name col-width nil ?\s)))
                 (magit-insert-section (branch display-name)
                   (magit-insert-heading
                     (concat
                      "  "
                      (propertize padded
                                  'font-lock-face 'madolt-branch-remote)
                      " " (or message "")
                      "\n")))))
             (insert "\n"))))
       by-remote))))

(defun madolt-refs--insert-tags (tags)
  "Insert a section listing TAGS."
  (when tags
    (let ((col-width (madolt-refs--column-width
                      (mapcar (lambda (tg) (plist-get tg :name)) tags))))
      (magit-insert-section (tags nil t)
        (magit-insert-heading "Tags:")
        (dolist (tag tags)
          (let* ((name (plist-get tag :name))
                 (padded (truncate-string-to-width name col-width nil ?\s)))
            (magit-insert-section (tag name)
              (magit-insert-heading
                (concat
                 "  "
                 (propertize padded 'font-lock-face 'madolt-tag)
                 "\n")))))
        (insert "\n")))))

(provide 'madolt-refs)
;;; madolt-refs.el ends here
