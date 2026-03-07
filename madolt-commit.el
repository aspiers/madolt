;;; madolt-commit.el --- Commit commands for Madolt  -*- lexical-binding:t -*-

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

;; Commit transient menu and commit commands for madolt.
;;
;; Dolt (as of v1.82.x) does not support the $EDITOR-based commit
;; message flow that git uses.  All commits must use the `-m' flag.
;; Therefore this module reads the commit message from the minibuffer
;; and passes it via `-m'.
;;
;; Message history is provided via `log-edit-comment-ring', giving
;; M-p/M-n navigation through previous commit messages.
;;
;; The commit assertion checks whether staged changes exist and
;; offers to stage all if needed.

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'ring)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

;;;; Message history

(defvar madolt-commit--message-ring (make-ring 32)
  "Ring of previous commit messages for history navigation.")

(defvar madolt-commit--message-ring-index nil
  "Current index into `madolt-commit--message-ring' during navigation.")

;;;; Transient menu

;;;###autoload (autoload 'madolt-commit "madolt-commit" nil t)
(transient-define-prefix madolt-commit ()
  "Create a Dolt commit."
  ["Arguments"
   ("-a" "Stage all modified and deleted tables" "--all")
   ("-A" "Stage all tables (including new)"      "--ALL")
   ("-e" "Allow empty commit"                    "--allow-empty")
   ("-f" "Force (ignore constraint warnings)"    "--force")
   ("=d" "Override date"                         "--date=")
   ("=A" "Override author"                       "--author=")]
  ["Create"
   ("c" "Commit"  madolt-commit-create)
   ("a" "Amend"   madolt-commit-amend)]
  ["Edit"
   ("m" "Message" madolt-commit-message)])

;;;; Commit assertion

(defun madolt-commit-assert (&optional args)
  "Assert that there is something to commit.
If there are no staged changes and --all/--ALL is not in ARGS,
offer to stage all.  Return a cons (t . ARGS) if committing
should proceed, or nil to abort."
  (let ((status (madolt-status-tables))
        (has-all (or (member "--all" args)
                     (member "--ALL" args))))
    (if (or has-all
            (alist-get 'staged status))
        (cons t args)
      ;; Nothing staged and no --all flag
      (if (y-or-n-p "Nothing staged.  Stage all and commit? ")
          (cons t (cons "--all" (or args nil)))
        nil))))

;;;; Commit commands

(defun madolt-commit-create (&optional args)
  "Create a new commit.
Read the commit message from the minibuffer.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-commit)))
  (let ((result (madolt-commit-assert args)))
    (when result
      (let ((final-args (cdr result))
            (message (madolt-commit--read-message)))
        (when (and message (not (string-empty-p message)))
          (madolt-commit--do-commit message final-args))))))

(defun madolt-commit-amend (&optional args)
  "Amend the last commit.
Read the replacement message from the minibuffer.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-commit)))
  (let* ((last-entry (car (madolt-log-entries 1)))
         (old-message (and last-entry (plist-get last-entry :message)))
         (message (madolt-commit--read-message old-message)))
    (when (and message (not (string-empty-p message)))
      (madolt-commit--do-commit message (cons "--amend" (or args nil))))))

(defun madolt-commit-message (&optional args)
  "Commit with a message read from the minibuffer.
This is an alias for `madolt-commit-create' for discoverability.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-commit)))
  (madolt-commit-create args))

;;;; Internal

(defun madolt-commit--read-message (&optional initial)
  "Read a commit message from the minibuffer.
INITIAL is the initial input (e.g., for amend).
Support M-p/M-n for message history via `madolt-commit--message-ring'."
  (setq madolt-commit--message-ring-index nil)
  (let ((minibuffer-local-map (madolt-commit--make-minibuffer-map)))
    (read-from-minibuffer "Commit message: " initial)))

(defun madolt-commit--make-minibuffer-map ()
  "Create a minibuffer keymap with M-p/M-n for message history."
  (let ((map (copy-keymap minibuffer-local-map)))
    (keymap-set map "M-p" #'madolt-commit--previous-message)
    (keymap-set map "M-n" #'madolt-commit--next-message)
    map))

(defun madolt-commit--previous-message ()
  "Insert the previous commit message from the ring."
  (interactive)
  (when (ring-empty-p madolt-commit--message-ring)
    (user-error "No previous commit messages"))
  (let ((index (if madolt-commit--message-ring-index
                   (1+ madolt-commit--message-ring-index)
                 0)))
    (when (>= index (ring-length madolt-commit--message-ring))
      (setq index (1- (ring-length madolt-commit--message-ring))))
    (setq madolt-commit--message-ring-index index)
    (delete-minibuffer-contents)
    (insert (ring-ref madolt-commit--message-ring index))))

(defun madolt-commit--next-message ()
  "Insert the next commit message from the ring."
  (interactive)
  (when (ring-empty-p madolt-commit--message-ring)
    (user-error "No previous commit messages"))
  (let ((index (if madolt-commit--message-ring-index
                   (1- madolt-commit--message-ring-index)
                 0)))
    (when (< index 0)
      (setq index 0))
    (setq madolt-commit--message-ring-index index)
    (delete-minibuffer-contents)
    (insert (ring-ref madolt-commit--message-ring index))))

(defun madolt-commit--do-commit (message args)
  "Execute `dolt commit' with MESSAGE and ARGS.
Save MESSAGE to the message ring and refresh the buffer."
  ;; Save to message history
  (ring-insert madolt-commit--message-ring message)
  ;; Build the full argument list
  (apply #'madolt-run-dolt "commit" "-m" message
         (madolt--flatten-args args)))

(provide 'madolt-commit)
;;; madolt-commit.el ends here
