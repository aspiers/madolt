;;; madolt-blame.el --- Per-row blame annotations for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

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

;; Per-row blame annotations for madolt.  Shows which commit last
;; modified each row in a table, using `dolt blame <table>'.
;; Accessible from the dispatch menu via `B'.

;;; Code:

(require 'magit-section)
(require 'madolt-dolt)
(require 'madolt-mode)

;;;; Buffer-local variables

(defvar-local madolt-blame--table nil
  "The table being blamed in this buffer.")

(defvar-local madolt-blame--rev nil
  "Optional revision to start blame from.")

(defvar-local madolt-blame--limit 200
  "Number of blame output lines to show.")

;;;; Row limit expansion

(defun madolt-blame-double-limit ()
  "Double the number of blame lines shown and refresh."
  (interactive)
  (setq madolt-blame--limit (* madolt-blame--limit 2))
  (madolt-refresh))

;;;; Blame mode

(define-derived-mode madolt-blame-mode madolt-mode "Madolt Blame"
  "Mode for madolt blame buffers.")

;;;; Commands

;;;###autoload
(defun madolt-blame (table)
  "Show per-row blame annotations for TABLE."
  (interactive
   (list (completing-read "Blame table: " (madolt-table-names))))
  (madolt-blame--show table nil))

;;;; Buffer display

(defun madolt-blame--show (table rev)
  "Show blame for TABLE at optional REV."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (madolt--buffer-name 'madolt-blame-mode db-dir))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-blame-mode)
        (madolt-blame-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-blame--table table)
      (setq madolt-blame--rev rev)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-blame-refresh-buffer ()
  "Refresh the blame buffer by running dolt blame."
  (let* ((table madolt-blame--table)
         (rev madolt-blame--rev)
         (args (append (list "blame")
                       (when rev (list rev))
                       (list table)))
         (result (apply #'madolt--run args))
         (exit-code (car result))
         (output (madolt--strip-ansi (cdr result))))
    (magit-insert-section (blame)
      (magit-insert-heading
        (propertize (if rev
                        (format "Blame for %s at %s:" table rev)
                      (format "Blame for %s:" table))
                    'font-lock-face 'magit-section-heading))
      (if (zerop exit-code)
          (if (string-blank-p (string-trim output))
              (insert (propertize "  (no rows)\n"
                                  'font-lock-face 'shadow))
            (madolt-blame--insert-result output))
        (insert (propertize (format "  Error: %s\n" (string-trim output))
                            'font-lock-face 'error)))
      (insert "\n"))))

;;;; Result rendering

(defun madolt-blame--insert-result (output)
  "Insert tabular blame OUTPUT into the current buffer."
  (let* ((lines (split-string output "\n" t))
         (total (length lines))
         (limit madolt-blame--limit)
         (shown 0))
    (dolist (line lines)
      (when (< shown limit)
        (insert (madolt-blame--fontify-line line) "\n")
        (cl-incf shown)))
    (when (> total limit)
      (madolt-insert-show-more-button
       shown total
       'madolt-mode-map 'madolt-blame-double-limit))))

(defun madolt-blame--fontify-line (line)
  "Apply faces to a blame result LINE."
  (cond
   ;; Border line: +----+----+
   ((string-match-p "^\\+-" line)
    (propertize line 'font-lock-face 'shadow))
   ;; Header line (contains column names)
   ((and (string-match-p "^|" line)
         (string-match-p "commit" line)
         (string-match-p "committer" line))
    (propertize line 'font-lock-face 'bold))
   (t line)))

(provide 'madolt-blame)
;;; madolt-blame.el ends here
