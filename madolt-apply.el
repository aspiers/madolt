;;; madolt-apply.el --- Stage, unstage, and discard for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

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

;; Stage, unstage, and discard operations for the madolt status buffer.
;; Dolt stages whole tables (not hunks), so this layer is simpler than
;; magit's apply layer.
;;
;; All operations go through `madolt-run-dolt' which logs to the
;; process buffer and refreshes the status buffer afterward.

;;; Code:

(require 'magit-section)
(require 'madolt-process)

;;;; Helpers

(defun madolt-apply--section-table-name ()
  "Return the table name of the section at point, or nil."
  (let ((section (magit-current-section)))
    (and section
         (eq (oref section type) 'table)
         (oref section value))))

(defun madolt-apply--parent-type ()
  "Return the type of the parent section of the section at point."
  (let ((section (magit-current-section)))
    (and section
         (oref section parent)
         (oref (oref section parent) type))))

(defun madolt-apply--section-type ()
  "Return the type of the section at point."
  (let ((section (magit-current-section)))
    (and section (oref section type))))

(defun madolt-apply--inside-row-p ()
  "Return non-nil if point is on a row-level or schema-level section.
Dolt stages whole tables, not individual rows.  This detects when
the user is trying to stage/unstage/discard a sub-table section
so we can show a helpful error message."
  (let ((type (madolt-apply--section-type)))
    (memq type '(row-diff schema-diff))))

;;;; Stage

(defun madolt-stage ()
  "Stage the table at point, or all tables if on a section heading.
On a table under \"Unstaged changes\" or \"Untracked tables\", stages
that table.  On the section heading itself, stages all tables."
  (interactive)
  (let ((section-type (madolt-apply--section-type))
        (parent-type (madolt-apply--parent-type))
        (table (madolt-apply--section-table-name)))
    (cond
     ;; Table under unstaged or untracked
     ((and table (memq parent-type '(unstaged untracked)))
      (madolt-run-dolt "add" table))
     ;; Unstaged or untracked section heading
     ((memq section-type '(unstaged untracked))
      (madolt-run-dolt "add" "."))
     ;; Row-level section: Dolt doesn't support partial staging
     ((madolt-apply--inside-row-p)
      (user-error "Dolt doesn't support staging individual rows; stage the whole table instead"))
     (t
      (user-error "Nothing to stage here")))))

(defun madolt-stage-all ()
  "Stage all changed and untracked tables."
  (interactive)
  (madolt-run-dolt "add" "."))

;;;; Unstage

(defun madolt-unstage ()
  "Unstage the table at point, or all tables if on a section heading.
On a table under \"Staged changes\", unstages that table.
On the section heading itself, unstages all tables."
  (interactive)
  (let ((section-type (madolt-apply--section-type))
        (parent-type (madolt-apply--parent-type))
        (table (madolt-apply--section-table-name)))
    (cond
     ;; Table under staged
     ((and table (eq parent-type 'staged))
      (madolt-run-dolt "reset" table))
     ;; Staged section heading
     ((eq section-type 'staged)
      (madolt-run-dolt "reset"))
     ;; Row-level section: Dolt doesn't support partial unstaging
     ((madolt-apply--inside-row-p)
      (user-error "Dolt doesn't support unstaging individual rows; unstage the whole table instead"))
     (t
      (user-error "Nothing to unstage here")))))

(defun madolt-unstage-all ()
  "Unstage all staged tables."
  (interactive)
  (madolt-run-dolt "reset"))

;;;; Discard

(defun madolt-discard ()
  "Discard changes to the table at point.
Prompts for confirmation because discard is destructive and
irreversible."
  (interactive)
  (let ((section-type (madolt-apply--section-type))
        (parent-type (madolt-apply--parent-type))
        (table (madolt-apply--section-table-name)))
    (cond
     ;; Table under unstaged
     ((and table (eq parent-type 'unstaged))
      (when (y-or-n-p (format "Discard changes to %s? " table))
        (madolt-run-dolt "checkout" table)))
     ;; Unstaged section heading — discard all
     ((eq section-type 'unstaged)
      (when (y-or-n-p "Discard ALL unstaged changes? ")
        (let ((section (magit-current-section)))
          (dolist (child (oref section children))
            (when (eq (oref child type) 'table)
              (madolt-call-dolt "checkout" (oref child value))))
          (madolt-refresh))))
     ;; Row-level section: Dolt doesn't support partial discard
     ((madolt-apply--inside-row-p)
      (user-error "Dolt doesn't support discarding individual rows; discard the whole table instead"))
     (t
       (user-error "Nothing to discard here")))))

;;;; Clean

(defun madolt-clean ()
  "Remove untracked tables from the working set.
When point is on a specific untracked table, remove only that table.
When point is on the untracked section heading, remove all untracked
tables.  Prompts for confirmation because this is destructive."
  (interactive)
  (let ((section-type (madolt-apply--section-type))
        (parent-type (madolt-apply--parent-type))
        (table (madolt-apply--section-table-name)))
    (cond
     ;; Table under untracked
     ((and table (eq parent-type 'untracked))
      (when (y-or-n-p (format "Delete untracked table %s? " table))
        (madolt-run-dolt "clean" table)))
     ;; Untracked section heading — clean all
     ((eq section-type 'untracked)
      (let ((tables nil))
        (dolist (child (oref (magit-current-section) children))
          (when (eq (oref child type) 'table)
            (push (oref child value) tables)))
        (if (null tables)
            (user-error "No untracked tables to clean")
          (when (y-or-n-p (format "Delete %d untracked table%s (%s)? "
                                  (length tables)
                                  (if (= (length tables) 1) "" "s")
                                  (string-join tables ", ")))
            (apply #'madolt-run-dolt "clean" tables)))))
     (t
      (user-error "Nothing to clean here; move to an untracked table or the Untracked section")))))

(provide 'madolt-apply)
;;; madolt-apply.el ends here
