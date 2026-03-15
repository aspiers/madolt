;;; madolt-reflog.el --- Reflog viewer for Madolt  -*- lexical-binding:t -*-

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

;; Reflog viewer for madolt.  Shows the history of ref changes
;; (branch/tag updates) in a read-only, section-based buffer.
;; Accessible from the log transient via `O'.

;;; Code:

(require 'magit-section)
(require 'madolt-dolt)
(require 'madolt-mode)

;;;; Buffer-local variables

(defvar-local madolt-reflog--ref nil
  "The ref being shown in this reflog buffer, or nil for all.")

(defvar-local madolt-reflog--all nil
  "When non-nil, show all refs including hidden ones.")

(defvar-local madolt-reflog--limit 100
  "Number of reflog entries to show.")

;;;; Row limit expansion

(defun madolt-reflog-double-limit ()
  "Double the number of reflog entries shown and refresh."
  (interactive)
  (setq madolt-reflog--limit (* madolt-reflog--limit 2))
  (madolt-refresh))

;;;; Reflog mode

(define-derived-mode madolt-reflog-mode madolt-mode "Madolt Reflog"
  "Mode for madolt reflog buffers.")

;;;; Commands

;;;###autoload
(defun madolt-reflog-current ()
  "Show reflog for the current branch."
  (interactive)
  (madolt-reflog--show (madolt-current-branch) nil))

;;;###autoload
(defun madolt-reflog-other (ref)
  "Show reflog for REF."
  (interactive
   (list (completing-read "Reflog for ref: " (madolt-branch-names)
                          nil nil nil nil (madolt-branch-at-point))))
  (madolt-reflog--show ref nil))

;;;###autoload
(defun madolt-reflog-all ()
  "Show reflog for all refs."
  (interactive)
  (madolt-reflog--show nil t))

;;;; Buffer display

(defun madolt-reflog--show (ref all)
  "Show reflog for REF in a reflog buffer.
When ALL is non-nil, show all refs including hidden ones.
If a buffer already exists for this ref, switch to it without
refreshing.  Use \\`g' to refresh manually."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (db-name (file-name-nondirectory
                   (directory-file-name db-dir)))
         (buf-name (format "madolt-reflog: %s %s"
                           db-name
                           (cond (all "all")
                                 (ref ref)
                                 (t "HEAD"))))
         (existing (get-buffer buf-name))
         (buffer (or existing (generate-new-buffer buf-name))))
    (unless existing
      (with-current-buffer buffer
        (madolt-reflog-mode)
        (setq default-directory db-dir)
        (setq madolt-buffer-database-dir db-dir)
        (setq madolt-reflog--ref ref)
        (setq madolt-reflog--all all)
        (madolt-refresh)))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-reflog-refresh-buffer ()
  "Refresh the reflog buffer by inserting entry sections."
  (let* ((all-entries (madolt-reflog-entries
                       madolt-reflog--ref madolt-reflog--all))
         (total (length all-entries))
         (entries (if (> total madolt-reflog--limit)
                      (seq-take all-entries madolt-reflog--limit)
                    all-entries))
         (heading (cond
                   (madolt-reflog--all "Reflog (all refs):")
                   (madolt-reflog--ref
                    (format "Reflog for %s:" madolt-reflog--ref))
                   (t "Reflog:"))))
    (magit-insert-section (reflog)
      (magit-insert-heading heading)
      (if (null entries)
          (insert (propertize "  (no reflog entries)\n"
                              'font-lock-face 'shadow))
        (dolist (entry entries)
          (madolt-reflog--insert-entry entry))
        (when (> total madolt-reflog--limit)
          (madolt-insert-show-more-button
           (length entries) total
           'madolt-mode-map 'madolt-reflog-double-limit)))
      (insert "\n"))))

(defun madolt-reflog--insert-entry (entry)
  "Insert a reflog section for ENTRY.
ENTRY is a plist with keys :hash :refs :message."
  (let* ((hash (plist-get entry :hash))
         (refs (plist-get entry :refs))
         (message (plist-get entry :message))
         (short-hash (substring hash 0 (min 8 (length hash)))))
    (magit-insert-section (reflog-entry hash)
      (magit-insert-heading
        (concat
         (propertize short-hash 'font-lock-face 'madolt-hash)
         " "
         (propertize (format "(%s)" refs)
                     'font-lock-face 'magit-section-heading)
         " "
         (or message "")
         "\n")))))

(provide 'madolt-reflog)
;;; madolt-reflog.el ends here
