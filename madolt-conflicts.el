;;; madolt-conflicts.el --- Conflict resolution UI for Madolt  -*- lexical-binding:t -*-

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

;; Conflict resolution UI for madolt.  After a merge that produces
;; conflicts, this module provides:
;; - A conflicts buffer showing conflicting rows (base/ours/theirs)
;; - Commands to resolve conflicts by taking ours or theirs
;; - A transient menu for conflict resolution operations

;;; Code:

(require 'magit-section)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)

;;;; Buffer-local variables

(defvar-local madolt-conflicts--table nil
  "The table whose conflicts are shown, or nil for all.")

(defvar-local madolt-conflicts--limit 200
  "Number of conflict output lines to show.")

;;;; Row limit expansion

(defun madolt-conflicts-double-limit ()
  "Double the number of conflict lines shown and refresh."
  (interactive)
  (setq madolt-conflicts--limit (* madolt-conflicts--limit 2))
  (madolt-refresh))

;;;; Conflicts mode

(define-derived-mode madolt-conflicts-mode madolt-mode "Madolt Conflicts"
  "Mode for madolt conflict resolution buffers.")

;;;; Transient

;;;###autoload (autoload 'madolt-conflicts "madolt-conflicts" nil t)
(transient-define-prefix madolt-conflicts ()
  "Resolve merge conflicts."
  ["View conflicts"
   ("c" "Show conflicts" madolt-conflicts-show)]
  ["Resolve"
   ("o" "Resolve ours"   madolt-conflicts-resolve-ours)
   ("t" "Resolve theirs" madolt-conflicts-resolve-theirs)])

;;;; Commands

(defun madolt-conflicts-show (table)
  "Show conflicts for TABLE in a dedicated buffer.
Use \".\" for all tables."
  (interactive
   (list (completing-read "Show conflicts for table: "
                          (append '(".") (madolt-conflicts--table-names)))))
  (madolt-conflicts--show (if (string= table ".") nil table)))

(defun madolt-conflicts-resolve-ours (table)
  "Resolve conflicts in TABLE by taking ours."
  (interactive
   (list (completing-read "Resolve (ours) table: "
                          (append '(".") (madolt-conflicts--table-names)))))
  (let ((result (madolt-call-dolt "conflicts" "resolve" "--ours" table)))
    (if (zerop (car result))
        (progn
          (message "Resolved conflicts in %s (ours)" table)
          (madolt-refresh))
      (message "Failed to resolve conflicts: %s" (cdr result)))))

(defun madolt-conflicts-resolve-theirs (table)
  "Resolve conflicts in TABLE by taking theirs."
  (interactive
   (list (completing-read "Resolve (theirs) table: "
                          (append '(".") (madolt-conflicts--table-names)))))
  (let ((result (madolt-call-dolt "conflicts" "resolve" "--theirs" table)))
    (if (zerop (car result))
        (progn
          (message "Resolved conflicts in %s (theirs)" table)
          (madolt-refresh))
      (message "Failed to resolve conflicts: %s" (cdr result)))))

;;;; Helpers

(defun madolt-conflicts--table-names ()
  "Return a list of table names that have unresolved conflicts.
Parses `dolt status' output for unmerged tables."
  (let ((output (cdr (madolt--run "status")))
        (tables nil)
        (in-unmerged nil))
    (dolist (line (split-string output "\n"))
      (cond
       ((string-match-p "^Unmerged paths:" line)
        (setq in-unmerged t))
       ;; End of unmerged section
       ((and in-unmerged (string-match-p "^[A-Z]" line))
        (setq in-unmerged nil))
       ;; Table entry: "\tboth modified:  table_name"
       ((and in-unmerged
             (string-match "^\t[a-z ]+:\\s-+\\(\\S-+\\)" line))
        (push (match-string 1 line) tables))))
    (nreverse tables)))

;;;; Buffer display

(defun madolt-conflicts--show (table)
  "Show conflicts for TABLE (or all if nil) in a buffer."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (madolt--buffer-name 'madolt-conflicts-mode db-dir))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-conflicts-mode)
        (madolt-conflicts-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-conflicts--table table)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-conflicts-refresh-buffer ()
  "Refresh the conflicts buffer."
  (let* ((table (or madolt-conflicts--table "."))
         (result (madolt--run "conflicts" "cat" table))
         (exit-code (car result))
         (output (madolt--strip-ansi (cdr result)))
         (heading (if madolt-conflicts--table
                      (format "Conflicts in %s:" madolt-conflicts--table)
                    "Conflicts (all tables):")))
    (magit-insert-section (conflicts)
      (magit-insert-heading
        (propertize heading 'font-lock-face 'magit-section-heading))
      (if (zerop exit-code)
          (if (string-blank-p (string-trim output))
              (insert (propertize "  (no conflicts)\n"
                                  'font-lock-face 'shadow))
            (madolt-conflicts--insert-result output))
        (insert (propertize (format "  Error: %s\n" (string-trim output))
                            'font-lock-face 'error)))
      (insert "\n"))))

;;;; Result rendering

(defun madolt-conflicts--insert-result (output)
  "Insert tabular conflict OUTPUT into the current buffer."
  (let* ((lines (split-string output "\n" t))
         (total (length lines))
         (limit madolt-conflicts--limit)
         (shown 0))
    (dolist (line lines)
      (when (< shown limit)
        (insert (madolt-conflicts--fontify-line line) "\n")
        (cl-incf shown)))
    (when (> total limit)
      (madolt-insert-show-more-button
       shown total
       'madolt-mode-map 'madolt-conflicts-double-limit))))

(defun madolt-conflicts--fontify-line (line)
  "Apply faces to a conflict result LINE."
  (cond
   ;; Border line
   ((string-match-p "^\\+-" line)
    (propertize line 'font-lock-face 'shadow))
   ;; "ours" row
   ((string-match-p "| *ours" line)
    (propertize line 'font-lock-face 'diff-added))
   ;; "theirs" row
   ((string-match-p "| *theirs" line)
    (propertize line 'font-lock-face 'diff-removed))
   ;; "base" row
   ((string-match-p "| *base" line)
    (propertize line 'font-lock-face 'shadow))
   (t line)))

(provide 'madolt-conflicts)
;;; madolt-conflicts.el ends here
