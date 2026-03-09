;;; madolt-sql.el --- SQL query interface for Madolt  -*- lexical-binding:t -*-

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

;; Interactive SQL query interface for madolt.  Prompts for a SQL
;; query via the minibuffer, executes it with `dolt sql -q', and
;; displays the results in a dedicated buffer.  Previous queries
;; are available via minibuffer history.

;;; Code:

(require 'magit-section)
(require 'madolt-dolt)
(require 'madolt-mode)

;;;; Query history

(defvar madolt-sql-history nil
  "Minibuffer history for SQL queries.")

;;;; Buffer-local variables

(defvar-local madolt-sql--query nil
  "The SQL query shown in this result buffer.")

;;;; SQL result mode

(define-derived-mode madolt-sql-mode madolt-mode "Madolt SQL"
  "Mode for madolt SQL result buffers.")

;;;; Commands

;;;###autoload
(defun madolt-sql-query (query)
  "Execute SQL QUERY and display results.
Prompts for QUERY via the minibuffer with history support."
  (interactive
   (list (read-string "SQL query: " nil 'madolt-sql-history)))
  (when (string-blank-p query)
    (user-error "Empty query"))
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (madolt--buffer-name 'madolt-sql-mode db-dir))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-sql-mode)
        (madolt-sql-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-sql--query query)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-sql-refresh-buffer ()
  "Refresh the SQL result buffer by re-executing the query."
  (let* ((query madolt-sql--query)
         (result (madolt--run "sql" "-q" query "-r" "tabular"))
         (exit-code (car result))
         (output (madolt--strip-ansi (cdr result))))
    (magit-insert-section (sql-result)
      (magit-insert-heading
        (propertize (format "SQL: %s" query)
                    'font-lock-face 'magit-section-heading))
      (if (zerop exit-code)
          (if (string-blank-p (string-trim output))
              (insert (propertize "  Query executed successfully (no output)\n"
                                  'font-lock-face 'shadow))
            (madolt-sql--insert-result output))
        (insert (propertize (format "  Error: %s\n" (string-trim output))
                            'font-lock-face 'error)))
      (insert "\n"))))

;;;; Result rendering

(defun madolt-sql--insert-result (output)
  "Insert tabular OUTPUT from dolt sql into the current buffer."
  (let ((lines (split-string output "\n" t)))
    (dolist (line lines)
      (insert (madolt-sql--fontify-line line) "\n"))))

(defun madolt-sql--fontify-line (line)
  "Apply faces to a tabular result LINE.
Border lines (+-...) get shadow face; header rows get bold."
  (cond
   ;; Border line: +----+----+
   ((string-match-p "^[+|]-" line)
    (if (string-match-p "^\\+-" line)
        (propertize line 'font-lock-face 'shadow)
      line))
   (t line)))

(provide 'madolt-sql)
;;; madolt-sql.el ends here
