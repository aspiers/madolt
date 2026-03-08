;;; madolt-remote.el --- Push, pull, and fetch for Madolt  -*- lexical-binding:t -*-

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

;; Push, pull, and fetch transient menus for madolt.
;;
;; Follows magit key conventions:
;;   f = fetch, F = pull, P = push
;;
;; Uses `dolt push', `dolt pull', and `dolt fetch' CLI commands.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

;;;; Helpers

(defun madolt-remote--read-remote (prompt)
  "Read a remote name with PROMPT, defaulting to \"origin\"."
  (let ((remotes (madolt-remote-names)))
    (if (null remotes)
        (user-error "No remotes configured")
      (if (= (length remotes) 1)
          (car remotes)
        (completing-read prompt remotes nil t nil nil
                         (and (member "origin" remotes) "origin"))))))

(defun madolt-remote--report (operation remote result)
  "Report the outcome of OPERATION on REMOTE given RESULT cons.
RESULT is (EXIT-CODE . OUTPUT-STRING)."
  (if (zerop (car result))
      (message "%s from %s complete" operation remote)
    (message "%s from %s failed: %s"
             operation remote
             (string-trim (cdr result)))))

;;;; Fetch transient

;;;###autoload (autoload 'madolt-fetch "madolt-remote" nil t)
(transient-define-prefix madolt-fetch ()
  "Fetch from a remote repository."
  ["Arguments"
   ("-p" "Prune deleted branches" "--prune")]
  ["Fetch from"
   ("p" "origin"      madolt-fetch-from-origin)
   ("e" "elsewhere"   madolt-fetch-from-remote)])

(defun madolt-fetch-from-origin (&optional args)
  "Fetch from origin remote.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-fetch)))
  (let ((result (apply #'madolt-call-dolt "fetch" "origin" args)))
    (madolt-refresh)
    (madolt-remote--report "Fetch" "origin" result)))

(defun madolt-fetch-from-remote (remote &optional args)
  "Fetch from REMOTE.
ARGS are additional arguments from the transient."
  (interactive
   (list (madolt-remote--read-remote "Fetch from remote: ")
         (transient-args 'madolt-fetch)))
  (let ((result (apply #'madolt-call-dolt "fetch" remote args)))
    (madolt-refresh)
    (madolt-remote--report "Fetch" remote result)))

;;;; Pull transient

;;;###autoload (autoload 'madolt-pull "madolt-remote" nil t)
(transient-define-prefix madolt-pull ()
  "Pull from a remote repository."
  ["Arguments"
   ("-f" "Fast-forward only" "--ff-only")
   ("-n" "No fast-forward"   "--no-ff")
   ("-s" "Squash"            "--squash")]
  ["Pull from"
   ("p" "origin"      madolt-pull-from-origin)
   ("e" "elsewhere"   madolt-pull-from-remote)])

(defun madolt-pull-from-origin (&optional args)
  "Pull from origin remote.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-pull)))
  (let ((result (apply #'madolt-call-dolt "pull" "origin" args)))
    (madolt-refresh)
    (madolt-remote--report "Pull" "origin" result)))

(defun madolt-pull-from-remote (remote &optional args)
  "Pull from REMOTE.
ARGS are additional arguments from the transient."
  (interactive
   (list (madolt-remote--read-remote "Pull from remote: ")
         (transient-args 'madolt-pull)))
  (let ((result (apply #'madolt-call-dolt "pull" remote args)))
    (madolt-refresh)
    (madolt-remote--report "Pull" remote result)))

;;;; Push transient

;;;###autoload (autoload 'madolt-push "madolt-remote" nil t)
(transient-define-prefix madolt-push ()
  "Push to a remote repository."
  ["Arguments"
   ("-f" "Force"          "--force")
   ("-u" "Set upstream"   "--set-upstream")]
  ["Push to"
   ("p" "origin"      madolt-push-to-origin)
   ("e" "elsewhere"   madolt-push-to-remote)])

(defun madolt-push-to-origin (&optional args)
  "Push current branch to origin remote.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-push)))
  (let* ((branch (madolt-current-branch))
         (result (apply #'madolt-call-dolt "push" "origin" branch args)))
    (madolt-refresh)
    (madolt-remote--report "Push" "origin" result)))

(defun madolt-push-to-remote (remote &optional args)
  "Push current branch to REMOTE.
ARGS are additional arguments from the transient."
  (interactive
   (list (madolt-remote--read-remote "Push to remote: ")
         (transient-args 'madolt-push)))
  (let* ((branch (madolt-current-branch))
         (result (apply #'madolt-call-dolt "push" remote branch args)))
    (madolt-refresh)
    (madolt-remote--report "Push" remote result)))

(provide 'madolt-remote)
;;; madolt-remote.el ends here
