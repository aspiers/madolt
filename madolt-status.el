;;; madolt-status.el --- Status buffer for Madolt  -*- lexical-binding:t -*-

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

;; The status buffer is the main entry point and central hub of madolt.
;; It shows the current branch, staged/unstaged/untracked tables,
;; stashes, and recent commits.
;;
;; The buffer is driven by `madolt-status-sections-hook', a hook whose
;; functions each insert one section.

;;; Code:

(require 'magit-section)
(require 'madolt-dolt)
(require 'madolt-mode)

;; Forward declarations for commands/functions in other files.
(declare-function madolt-diff-insert-table "madolt-diff" (table &optional staged))

;;;; Faces

(defface madolt-section-heading
  '((t :inherit magit-section-heading))
  "Face for section headings in madolt buffers."
  :group 'madolt-faces)

(defface madolt-hash
  '((t :inherit magit-hash))
  "Face for commit hashes."
  :group 'madolt-faces)

(defface madolt-branch-local
  '((t :inherit magit-branch-local))
  "Face for local branch names."
  :group 'madolt-faces)

(defface madolt-branch-remote
  '((t :inherit magit-branch-remote))
  "Face for remote branch/URL names."
  :group 'madolt-faces)

(defface madolt-table-modified
  '((t :foreground "yellow3"))
  "Face for the \"modified\" table status."
  :group 'madolt-faces)

(defface madolt-table-new
  '((t :foreground "green3"))
  "Face for the \"new table\" status."
  :group 'madolt-faces)

(defface madolt-table-deleted
  '((t :foreground "red3"))
  "Face for the \"deleted\" table status."
  :group 'madolt-faces)

(defface madolt-table-renamed
  '((t :foreground "cyan3"))
  "Face for the \"renamed\" table status."
  :group 'madolt-faces)

;;;; Sections hook

(defcustom madolt-status-sections-hook
  '(madolt-insert-status-header
    madolt-insert-untracked-tables
    madolt-insert-unstaged-changes
    madolt-insert-staged-changes
    madolt-insert-stashes
    madolt-insert-unpushed-commits
    madolt-insert-unpulled-commits
    madolt-insert-recent-commits)
  "Hook run to insert sections into the status buffer.
Each function on the hook inserts one section."
  :group 'madolt
  :type 'hook)

;;;; Per-refresh cache

(defvar-local madolt--status-tables-cache nil
  "Cached result of `madolt-status-tables' for the current refresh cycle.")

(defvar-local madolt--upstream-ref-cache 'unset
  "Cached result of `madolt-upstream-ref' for the current refresh cycle.
The value `unset' means not yet computed.")

(defun madolt--cached-status-tables ()
  "Return cached status tables, computing if needed."
  (or madolt--status-tables-cache
      (setq madolt--status-tables-cache (madolt-status-tables))))

(defun madolt--cached-upstream-ref ()
  "Return cached upstream ref, computing if needed."
  (when (eq madolt--upstream-ref-cache 'unset)
    (setq madolt--upstream-ref-cache (madolt-upstream-ref)))
  madolt--upstream-ref-cache)

;;;; Refresh

(defun madolt-status-refresh-buffer ()
  "Refresh the status buffer by running `madolt-status-sections-hook'."
  (setq madolt--status-tables-cache nil)
  (setq madolt--upstream-ref-cache 'unset)
  (magit-insert-section (status)
    (run-hooks 'madolt-status-sections-hook)))

;;;; Status header

(defun madolt-insert-status-header ()
  "Insert the status header showing branch, HEAD, upstream, and remote info."
  (let* ((branch (madolt-current-branch))
         (head-entry (car (madolt-log-entries 1)))
         (hash (and head-entry (plist-get head-entry :hash)))
         (message (and head-entry (plist-get head-entry :message)))
         (upstream (madolt--cached-upstream-ref))
         (remotes (madolt-remotes)))
    ;; Head line
    (insert (propertize "Head:     " 'font-lock-face 'bold)
            (if branch
                (propertize branch 'font-lock-face 'madolt-branch-local)
              "(detached)")
            (if hash
                (concat " "
                        (propertize (substring hash 0 (min 8 (length hash)))
                                    'font-lock-face 'madolt-hash)
                        " "
                        (or message ""))
              "")
            "\n")
    ;; Upstream line (if tracking a remote branch)
    (when upstream
      (insert (propertize "Upstream: " 'font-lock-face 'bold)
              (propertize upstream 'font-lock-face 'madolt-branch-remote)
              "\n"))
    ;; Remote lines
    (dolist (remote remotes)
      (insert (propertize "Remote:   " 'font-lock-face 'bold)
              (propertize (car remote) 'font-lock-face 'madolt-branch-remote)
              " "
              (propertize (cdr remote) 'font-lock-face 'shadow)
              "\n"))
    (insert "\n")))

;;;; Table change sections

(defun madolt--status-face-for-change (status)
  "Return the face for table change STATUS string."
  (pcase status
    ("modified"  'madolt-table-modified)
    ("new table" 'madolt-table-new)
    ("deleted"   'madolt-table-deleted)
    ("renamed"   'madolt-table-renamed)
    (_           'default)))

(defun madolt--insert-table-change-section (type label tables)
  "Insert a section of TYPE with LABEL heading for TABLES.
TABLES is a list of (TABLE-NAME . STATUS) cons cells.
If TABLES is empty, nothing is inserted."
  (when tables
    (magit-insert-section ((eval type))
      (magit-insert-heading
        (propertize (format "%s (%d)" label (length tables))
                    'font-lock-face 'madolt-section-heading))
      (dolist (entry tables)
        (let ((table (car entry))
              (status (cdr entry)))
          (magit-insert-section (table table t)
            (magit-insert-heading
              (concat "  "
                      (propertize (format "%-12s" status)
                                  'font-lock-face
                                  (madolt--status-face-for-change status))
                      table))
            (magit-insert-section-body
              (madolt--wash-table-diff)))))
      (insert "\n"))))

;;;; Staged changes

(defun madolt-insert-staged-changes ()
  "Insert the staged changes section."
  (let ((tables (alist-get 'staged (madolt--cached-status-tables))))
    (madolt--insert-table-change-section 'staged "Staged changes" tables)))

;;;; Unstaged changes

(defun madolt-insert-unstaged-changes ()
  "Insert the unstaged changes section."
  (let ((tables (alist-get 'unstaged (madolt--cached-status-tables))))
    (madolt--insert-table-change-section 'unstaged "Unstaged changes" tables)))

;;;; Untracked tables

(defun madolt-insert-untracked-tables ()
  "Insert the untracked tables section."
  (let ((tables (alist-get 'untracked (madolt--cached-status-tables))))
    (madolt--insert-table-change-section 'untracked "Untracked tables" tables)))

;;;; Stashes

(defun madolt-insert-stashes ()
  "Insert the stashes section."
  (let ((lines (madolt-dolt-lines "stash" "list")))
    (when lines
      (magit-insert-section (stashes)
        (magit-insert-heading
          (propertize (format "Stashes (%d)" (length lines))
                      'font-lock-face 'madolt-section-heading))
        (dolist (line lines)
          (magit-insert-section (stash line)
            (insert "  " line "\n")))
        (insert "\n")))))

;;;; Unpulled / Unpushed commits

(defun madolt--insert-commit-list-section (type label entries)
  "Insert a section of TYPE with LABEL for commit ENTRIES.
ENTRIES is a list of plists with :hash and :message keys.
If ENTRIES is nil, nothing is inserted."
  (when entries
    (magit-insert-section ((eval type))
      (magit-insert-heading
        (propertize (format "%s (%d)" label (length entries))
                    'font-lock-face 'madolt-section-heading))
      (dolist (entry entries)
        (let* ((hash (plist-get entry :hash))
               (message (plist-get entry :message))
               (short-hash (substring hash 0 (min 8 (length hash)))))
          (magit-insert-section (commit hash)
            (insert "  "
                    (propertize short-hash 'font-lock-face 'madolt-hash)
                    "  "
                    (or message "")
                    "\n"))))
      (insert "\n"))))

(defun madolt-insert-unpulled-commits ()
  "Insert a section showing commits in upstream not in HEAD."
  (let* ((upstream (madolt--cached-upstream-ref))
         (entries (madolt-unpulled-commits upstream)))
    (madolt--insert-commit-list-section
     'unpulled
     (format "Unpulled from %s" (or upstream "upstream"))
     entries)))

(defun madolt-insert-unpushed-commits ()
  "Insert a section showing commits in HEAD not in upstream."
  (let* ((upstream (madolt--cached-upstream-ref))
         (entries (madolt-unpushed-commits upstream)))
    (madolt--insert-commit-list-section
     'unpushed
     (format "Unpushed to %s" (or upstream "upstream"))
     entries)))

;;;; Recent commits

(defun madolt-insert-recent-commits ()
  "Insert the recent commits section."
  (let ((entries (madolt-log-entries 10)))
    (when entries
      (magit-insert-section (recent)
        (magit-insert-heading
          (propertize "Recent commits"
                      'font-lock-face 'madolt-section-heading))
        (dolist (entry entries)
          (let* ((hash (plist-get entry :hash))
                 (message (plist-get entry :message))
                 (short-hash (substring hash 0 (min 8 (length hash)))))
            (magit-insert-section (commit hash)
              (insert "  "
                      (propertize short-hash 'font-lock-face 'madolt-hash)
                      "  "
                      (or message "")
                      "\n"))))
        (insert "\n")))))

;;;; Inline diff washer

(defun madolt--wash-table-diff ()
  "Insert diff content for the table section at point.
Used as a washer function for lazy diff expansion.
Uses `magit-insert-section--current' because the washer may run
deferred (via `magit-section--opportunistic-wash') where point
is at the section end and `magit-current-section' would return
a sibling or parent."
  (let* ((section magit-insert-section--current)
         (table (oref section value))
         (staged (eq 'staged
                     (oref (oref section parent) type))))
    (if (fboundp 'madolt-diff-insert-table)
        (madolt-diff-insert-table table staged)
      ;; Fallback before madolt-diff.el is implemented
      (insert "      (diff not yet available)\n"))))

;;;; Visit-thing

(defun madolt-visit-thing ()
  "Visit the thing at point.
Context-sensitive: on a table, describe the table.
On a commit, show the commit details."
  (interactive)
  (let ((section (magit-current-section)))
    (pcase (oref section type)
      ('table
       (let ((table (oref section value)))
         (if (fboundp 'madolt-diff-table)
             (madolt-diff-table table)
           (message "Diff for table: %s (madolt-diff not yet available)" table))))
      ('commit
       (let ((hash (oref section value)))
         (if (fboundp 'madolt-show-commit)
             (madolt-show-commit hash)
           (message "Commit: %s (madolt-log not yet available)" hash))))
      (_
       (user-error "Nothing to visit here")))))

(provide 'madolt-status)
;;; madolt-status.el ends here
