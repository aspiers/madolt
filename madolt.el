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

;; Forward declarations for commands defined in other files.
(declare-function madolt-diff "madolt-diff" ())
(declare-function madolt-log "madolt-log" ())
(declare-function madolt-commit "madolt-commit" ())
(declare-function madolt-stage "madolt-apply" ())
(declare-function madolt-stage-all "madolt-apply" ())
(declare-function madolt-unstage "madolt-apply" ())
(declare-function madolt-unstage-all "madolt-apply" ())
(declare-function madolt-discard "madolt-apply" ())
(declare-function madolt-visit-thing "madolt-status" ())

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
Interactively with a prefix argument, prompt for the directory."
  (interactive
   (list (and current-prefix-arg
              (read-directory-name "Dolt database: "))))
  (let ((default-directory (or directory default-directory)))
    (madolt-setup-buffer 'madolt-status-mode)))

;;;; Dispatch

;;;###autoload (autoload 'madolt-dispatch "madolt" nil t)
(transient-define-prefix madolt-dispatch ()
  "Invoke a Madolt command from a list of available commands."
  ["Transient commands"
   [("c" "Commit"         madolt-commit)
    ("d" "Diff"           madolt-diff)
    ("l" "Log"            madolt-log)]
   [("j" "Status"         madolt-status)
    ("$" "Process"        madolt-process-buffer)]]
  ["Applying changes"
   :if-derived madolt-mode
   [("s" "Stage"          madolt-stage)
    ("u" "Unstage"        madolt-unstage)
    ("k" "Discard"        madolt-discard)]
   [("S" "Stage all"      madolt-stage-all)
    ("U" "Unstage all"    madolt-unstage-all)]]
  ["Essential commands"
   :if-derived madolt-mode
   [("g"        "       Refresh current buffer"  madolt-refresh)
    ("q"        "       Bury current buffer"     quit-window)]
   [("<tab>"    "       Toggle section at point" magit-section-toggle)
    ("<return>" "       Visit thing at point"    madolt-visit-thing)]])

(provide 'madolt)
;;; madolt.el ends here
