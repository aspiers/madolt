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

;;;; Remote management transient

;;;###autoload (autoload 'madolt-remote-manage "madolt-remote" nil t)
(transient-define-prefix madolt-remote-manage ()
  "Add, configure or remove a remote."
  ["Arguments for add"
   ("-f" "Fetch after add" "-f")]
  ["Actions"
   ("a" "Add"           madolt-remote-add-command)
   ("C" "Configure URL" madolt-remote-configure-url-command)
   ("k" "Remove"        madolt-remote-remove-command)])

(defun madolt-remote-add-command (name url &optional args)
  "Add a remote named NAME pointing to URL.
ARGS are additional arguments from the transient."
  (interactive
   (list (read-string "Remote name: ")
         (read-string "Remote URL: ")
         (transient-args 'madolt-remote-manage)))
  (when (string-empty-p name)
    (user-error "Remote name cannot be empty"))
  (when (string-empty-p url)
    (user-error "Remote URL cannot be empty"))
  (let ((result (madolt-remote-add name url)))
    (if (zerop (car result))
        (progn
          (when (member "-f" args)
            (madolt-call-dolt "fetch" name))
          (madolt-refresh)
          (message "Added remote %s -> %s" name url))
      (user-error "Failed to add remote %s: %s"
                  name (string-trim (cdr result))))))

(defun madolt-remote-remove-command (name)
  "Remove the remote named NAME (with confirmation)."
  (interactive
   (list (madolt-remote--read-remote "Remove remote: ")))
  (when (yes-or-no-p (format "Remove remote %s? " name))
    (let ((result (madolt-remote-remove name)))
      (if (zerop (car result))
          (progn
            (madolt-refresh)
            (message "Removed remote %s" name))
        (user-error "Failed to remove remote %s: %s"
                    name (string-trim (cdr result)))))))

(defun madolt-remote-configure-url-command (name new-url)
  "Change the URL of remote NAME to NEW-URL.
Dolt has no `set-url' subcommand, so this removes and re-adds
the remote."
  (interactive
   (let* ((name (madolt-remote--read-remote "Configure remote: "))
          (remotes (madolt-remotes))
          (old-url (cdr (assoc name remotes #'string=)))
          (new-url (read-string (format "URL for %s: " name) old-url)))
     (list name new-url)))
  (when (string-empty-p new-url)
    (user-error "Remote URL cannot be empty"))
  (let* ((remotes (madolt-remotes))
         (old-url (cdr (assoc name remotes #'string=))))
    (if (string= new-url old-url)
        (message "URL for %s unchanged" name)
      (let ((rm-result (madolt-remote-remove name)))
        (unless (zerop (car rm-result))
          (user-error "Failed to remove remote %s: %s"
                      name (string-trim (cdr rm-result)))))
      (let ((add-result (madolt-remote-add name new-url)))
        (if (zerop (car add-result))
            (progn
              (madolt-refresh)
              (message "Remote %s URL changed: %s -> %s"
                       name old-url new-url))
          ;; Re-add failed; try to restore the old remote
          (madolt-remote-add name old-url)
          (user-error "Failed to set URL for %s: %s"
                      name (string-trim (cdr add-result))))))))

(provide 'madolt-remote)
;;; madolt-remote.el ends here
