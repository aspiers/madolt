;;; madolt.el --- A magit-like interface for the Dolt database  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>
;; URL: https://github.com/aspiers/madolt
;; Version: 0.1.0
;; Keywords: tools, vc
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7") (with-editor "3.0") (compat "30.1"))

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

;; Madolt is a magit-like Emacs interface for the Dolt version-controlled
;; database.  It provides a section-based, keyboard-driven UI for Dolt's
;; Git-like version control operations on SQL databases.
;;
;; The core loop is: view status -> stage tables -> write commit message
;; -> view history.
;;
;; Entry points:
;;   M-x madolt-status    Open the madolt status buffer
;;   M-x madolt-dispatch  Show the main dispatch menu

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-status)
(require 'madolt-apply)
(require 'madolt-commit)
(require 'madolt-branch)
(require 'madolt-cherry-pick)
(require 'madolt-diff)
(require 'madolt-log)
(require 'madolt-merge)
(require 'madolt-rebase)
(require 'madolt-reset)
(require 'madolt-blame)
(require 'madolt-conflicts)
(require 'madolt-reflog)
(require 'madolt-sql)
(require 'madolt-remote)
(require 'madolt-stash)
(require 'madolt-tag)
(require 'madolt-connection)
(require 'madolt-refs)

;;;; Customization

(defgroup madolt nil
  "A magit-like interface for the Dolt database."
  :group 'tools
  :prefix "madolt-")

(defgroup madolt-faces nil
  "Faces used by Madolt."
  :group 'madolt
  :group 'faces)

;;;; Entry point

;;;###autoload
(defun madolt-status (&optional directory)
  "Open the madolt status buffer for DIRECTORY.
If DIRECTORY is nil, search upward from `default-directory' for a
Dolt database (a directory containing `.dolt/').

When called interactively outside a Dolt database, prompt for a
directory (like `magit-status' does for Git repositories).
With a prefix argument, always prompt for the directory."
  (interactive
   (list (and (or current-prefix-arg (not (madolt-database-dir)))
              (read-directory-name "Dolt database: "))))
  (let ((default-directory (or directory default-directory)))
    (madolt-setup-buffer 'madolt-status-mode)))

;;;; Dispatch

(defclass madolt-responsive-columns (transient-columns)
  ()
  "A `transient-columns' subclass that redistributes suffixes at
display time based on window width.  The static layout defines
suffixes in their canonical order across the original columns;
this class flattens and reflows them into more columns on wider
screens.")

(defun madolt-responsive-columns--column-width (group)
  "Estimate the display width of one column in GROUP.
Uses the widest formatted suffix across all columns."
  (let ((max-width 0))
    (dolist (col (oref group suffixes))
      (dolist (suffix (oref col suffixes))
        (let* ((formatted (transient-format suffix))
               (width (length formatted)))
          (setq max-width (max max-width width)))))
    ;; Add inter-column padding (2 spaces)
    (+ max-width 2)))

(cl-defmethod transient--insert-group ((group madolt-responsive-columns))
  "Insert GROUP, redistributing suffixes across columns for width.
Flattens all suffixes from the original columns, then reflows
them into N columns based on window width (min 3, max 6)."
  (let* ((all-suffixes
          (cl-mapcan (lambda (col)
                       (copy-sequence (oref col suffixes)))
                     (oref group suffixes)))
         (col-width (madolt-responsive-columns--column-width group))
         (ncols (max 3 (min 6 (/ (window-width) (max 1 col-width)))))
         (nitems (length all-suffixes))
         (nrows (ceiling nitems ncols)))
    ;; Redistribute into new column objects, filling down then across
    (let ((new-columns nil))
      (dotimes (c ncols)
        (let ((col-suffixes nil))
          (dotimes (r nrows)
            (let ((idx (+ (* c nrows) r)))
              (when (< idx nitems)
                (push (nth idx all-suffixes) col-suffixes))))
          (when col-suffixes
            (let ((col (clone (car (oref group suffixes)))))
              (oset col suffixes (nreverse col-suffixes))
              (push col new-columns)))))
      ;; Temporarily swap in the new columns and use the standard renderer
      (let ((orig-suffixes (oref group suffixes)))
        (oset group suffixes (nreverse new-columns))
        (unwind-protect
            (cl-call-next-method group)
          (oset group suffixes orig-suffixes))))))

;;;###autoload (autoload 'madolt-dispatch "madolt" nil t)
(transient-define-prefix madolt-dispatch ()
  "Invoke a Madolt command from a list of available commands."
  ["Transient commands"
   :class madolt-responsive-columns
   [("b" "Branch"         madolt-branch)
    ("A" "Cherry-pick"    madolt-cherry-pick)
    ("c" "Commit"         madolt-commit)
    ("d" "Diff"           madolt-diff)
    ("f" "Fetch"          madolt-fetch)
    ("l" "Log"            madolt-log)]
   [("L" "Log (change)"   madolt-log-refresh)
    ("m" "Merge"          madolt-merge)
    ("F" "Pull"           madolt-pull)
    ("P" "Push"           madolt-push)
    ("r" "Rebase"         madolt-rebase)
    ("M" "Remote"         madolt-remote-manage)]
   [("X" "Reset"          madolt-reset)
    ("V" "Revert"         madolt-revert)
    ("E" "SQL server"     madolt-server)
    ("z" "Stash"          madolt-stash)
    ("t" "Tag"            madolt-tag)]]
  [["Inspecting"
    ("B" "Blame"          madolt-blame)
    ("C" "Conflicts"      madolt-conflicts)
    ("y" "Refs"           madolt-show-refs)
    ("e" "SQL query"      madolt-sql-query)]
   ["Applying changes"
    :if-derived madolt-mode
    ("s" "Stage"          madolt-stage)
    ("S" "Stage all"      madolt-stage-all)
    ("u" "Unstage"        madolt-unstage)
    ("U" "Unstage all"    madolt-unstage-all)]
   [""
    :if-derived madolt-mode
    ("x" "Clean"          madolt-clean)
    ("k" "Discard"        madolt-discard)]]
  ["Essential commands"
   :if-derived madolt-mode
   [("g"   "Refresh buffer"          madolt-refresh)
    ("j"   "Jump to section"         madolt-status-jump
     :if-mode madolt-status-mode)
    ("$"   "Process buffer"          madolt-process-buffer)
    ("q"   "Bury buffer"             quit-window)]
   [("<tab>"    "Toggle section"     magit-section-toggle)
    ("<return>" "Visit thing"        madolt-visit-thing)
    ("w"        "Copy section value" madolt-copy-section-value)]])

(provide 'madolt)
;;; madolt.el ends here
