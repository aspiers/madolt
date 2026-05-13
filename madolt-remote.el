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
(require 'auth-source)

;;;; Customization

(defcustom madolt-remote-password-function #'madolt-remote--lookup-password
  "Function to obtain the password for remote operations.
Called with two arguments: REMOTE (name) and USER (string).
Should return a password string, or nil to skip authentication.
The default uses `auth-source' to look up credentials, falling
back to `read-passwd'."
  :group 'madolt
  :type 'function)

;;;; Helpers

(defun madolt-remote--default ()
  "Return the best default remote name, or nil.
Prefers \"origin\" if it exists, otherwise uses the first
configured remote."
  (let ((remotes (madolt-remote-names)))
    (cond
     ((member "origin" remotes) "origin")
     (remotes (car remotes)))))

(defun madolt-remote--read-remote (prompt &optional force-prompt)
  "Read a remote name with PROMPT, defaulting to the default remote.
With a single remote, auto-selects it unless FORCE-PROMPT is non-nil."
  (let ((remotes (madolt-remote-names)))
    (if (null remotes)
        (user-error "No remotes configured")
      (if (and (= (length remotes) 1) (not force-prompt))
          (car remotes)
        (completing-read prompt remotes nil t nil nil
                         (madolt-remote--default))))))

(defun madolt-remote--report (operation remote result)
  "Report the outcome of OPERATION on REMOTE given RESULT cons.
RESULT is (EXIT-CODE . OUTPUT-STRING)."
  (if (zerop (car result))
      (message "%s from %s complete" operation remote)
    (message "%s from %s failed: %s"
             operation remote
             (madolt--clean-output (cdr result)))))

;;;; Remote authentication

(defvar madolt-remote--password-cache (make-hash-table :test #'equal)
  "In-memory cache of remote passwords, keyed by \"remote:user\".")

(defun madolt-remote--lookup-password (remote user)
  "Look up password for USER on REMOTE.
Checks in order: (1) in-memory session cache, (2) `auth-source',
(3) prompts with `read-passwd' and caches the result."
  (let ((cache-key (format "%s:%s" remote user)))
    (or (gethash cache-key madolt-remote--password-cache)
        (let* ((url (cdr (assoc remote (madolt-remotes) #'string=)))
               (host (and url (replace-regexp-in-string
                               "\\`https?://" ""
                               (replace-regexp-in-string "/.*" "" url))))
               (found (and host
                           (car (auth-source-search :host host :user user
                                                    :max 1))))
               (password
                (if found
                    (let ((secret (plist-get found :secret)))
                      (if (functionp secret) (funcall secret) secret))
                  (read-passwd (format "Password for %s on %s: "
                                       user remote)))))
          (puthash cache-key password madolt-remote--password-cache)
          password))))

(defun madolt-remote--extract-user (args)
  "Extract --user value from ARGS, returning (USER . REMAINING-ARGS)."
  (let ((user nil)
        (remaining nil)
        (rest args))
    (while rest
      (cond
       ((string-match "\\`--user=\\(.+\\)" (car rest))
        (setq user (match-string 1 (car rest))))
       ((equal (car rest) "--user")
        (setq user (cadr rest))
        (setq rest (cdr rest)))
       (t (push (car rest) remaining)))
      (setq rest (cdr rest)))
    (cons user (nreverse remaining))))

(defun madolt-remote--call-with-auth (remote args dolt-args)
  "Call dolt with DOLT-ARGS, handling --user auth from transient ARGS.
Extracts --user from ARGS.  If present, looks up the password and
binds DOLT_REMOTE_PASSWORD in the process environment.  Returns
the result cons (EXIT-CODE . OUTPUT)."
  (let* ((parsed (madolt-remote--extract-user args))
         (user (car parsed))
         (clean-args (cdr parsed))
         (dolt-cmd (append dolt-args
                           (when user (list "--user" user))
                           clean-args)))
    (if user
        (let* ((password (funcall madolt-remote-password-function
                                  remote user))
               (process-environment
                (cons (format "DOLT_REMOTE_PASSWORD=%s" (or password ""))
                      process-environment)))
          (apply #'madolt-call-dolt dolt-cmd))
      (apply #'madolt-call-dolt dolt-cmd))))

;;;; Fetch transient

;;;###autoload (autoload 'madolt-fetch "madolt-remote" nil t)
(transient-define-prefix madolt-fetch ()
  "Fetch from a remote repository."
  :value '("--user=root")
  ["Arguments"
   ("-p" "Prune deleted branches" "--prune")
   ("-u" "User" "--user="
    :class transient-option)]
  ["Fetch from"
   ("p" madolt-fetch-from-default)
   ("e" "elsewhere"   madolt-fetch-from-remote)])

(transient-define-suffix madolt-fetch-from-default (&optional args)
  "Fetch from a remote, prompting when multiple exist.
With a single remote, uses it directly.  With multiple remotes,
prompts via `completing-read' with the default pre-selected."
  :if (lambda () (madolt-remote--default))
  :description (lambda () (or (madolt-remote--default) "no remote"))
  (interactive (list (transient-args 'madolt-fetch)))
  (let* ((remote (madolt-remote--read-remote "Fetch from remote: "))
         (result (madolt-remote--call-with-auth
                  remote args (list "fetch" remote))))
    (madolt-refresh)
    (madolt-remote--report "Fetch" remote result)))

(defun madolt-fetch-from-remote (remote &optional args)
  "Fetch from REMOTE, always prompting for which remote.
ARGS are additional arguments from the transient."
  (interactive
   (list (madolt-remote--read-remote "Fetch from remote: " t)
         (transient-args 'madolt-fetch)))
  (let ((result (madolt-remote--call-with-auth
                 remote args (list "fetch" remote))))
    (madolt-refresh)
    (madolt-remote--report "Fetch" remote result)))

;;;; Pull transient

(defun madolt-remote--split-tracking-ref (ref)
  "Split a remote tracking REF \"REMOTE/BRANCH\" into (REMOTE . BRANCH).
Returns nil if REF does not contain a slash. The remote name is
matched against `madolt-remote-names' to handle branch names that
themselves contain slashes (e.g. origin/feature/foo)."
  (when (and ref (stringp ref) (string-match-p "/" ref))
    (let ((remotes (madolt-remote-names))
          match)
      (dolist (remote remotes)
        (let ((prefix (concat remote "/")))
          (when (and (not match) (string-prefix-p prefix ref))
            (setq match (cons remote (substring ref (length prefix)))))))
      (or match
          ;; Fallback: split on first slash.
          (let ((slash (string-match "/" ref)))
            (cons (substring ref 0 slash)
                  (substring ref (1+ slash))))))))

(defun madolt-remote--push-target ()
  "Return the (REMOTE . BRANCH) the current branch would push to.
Convention: the default remote plus the current local branch name.
Returns nil if there is no remote, no current branch, or the target
branch does not exist on the remote."
  (let ((remote (madolt-remote--default))
        (branch (madolt-current-branch)))
    (when (and remote branch
               (madolt-remote-branch-exists-p remote branch))
      (cons remote branch))))

(defun madolt-remote--upstream-target ()
  "Return the (REMOTE . BRANCH) of the current branch's upstream.
Wraps `madolt-upstream-ref' and splits the result."
  (madolt-remote--split-tracking-ref (madolt-upstream-ref)))

(defun madolt-remote--read-remote-branch (prompt)
  "Read a remote branch name with PROMPT, return (REMOTE . BRANCH).
Candidates come from `madolt-remote-branch-names', which lists every
known remote tracking ref in REMOTE/BRANCH form."
  (let* ((candidates (madolt-remote-branch-names))
         (_ (unless candidates
              (user-error "No remote branches configured")))
         (default (madolt-upstream-ref))
         (choice (completing-read prompt candidates nil t nil nil
                                  (and (member default candidates) default))))
    (or (madolt-remote--split-tracking-ref choice)
        (user-error "Could not parse remote branch %s" choice))))

;;;###autoload (autoload 'madolt-pull "madolt-remote" nil t)
(transient-define-prefix madolt-pull ()
  "Pull from a remote repository."
  :value '("--user=root")
  [:description
   (lambda ()
     (format "Pull into %s from"
             (or (madolt-current-branch) "?")))
   ("p" madolt-pull-from-push-target)
   ("u" madolt-pull-from-upstream)
   ("e" "elsewhere" madolt-pull-from-elsewhere)]
  ["Arguments"
   ("-f" "Fast-forward only" "--ff-only")
   ("-n" "No fast-forward"   "--no-ff")
   ("-s" "Squash"            "--squash")
   ("-U" "User" "--user="
    :class transient-option)])

(defun madolt-remote--do-pull (remote branch args)
  "Run dolt pull REMOTE BRANCH with auth from transient ARGS."
  (let* ((dolt-args (delq nil (list "pull" remote branch)))
         (result (madolt-remote--call-with-auth remote args dolt-args)))
    (madolt-refresh)
    (madolt-remote--report
     (format "Pull %s/%s" remote (or branch "")) remote result)))

(transient-define-suffix madolt-pull-from-push-target (&optional args)
  "Pull from the push target (default remote + current branch)."
  :if (lambda () (madolt-remote--push-target))
  :description
  (lambda ()
    (let ((target (madolt-remote--push-target)))
      (if target
          (format "%s/%s" (car target) (cdr target))
        "no push target")))
  (interactive (list (transient-args 'madolt-pull)))
  (let ((target (madolt-remote--push-target)))
    (unless target (user-error "No push target for this branch"))
    (madolt-remote--do-pull (car target) (cdr target) args)))

(transient-define-suffix madolt-pull-from-upstream (&optional args)
  "Pull from the configured upstream of the current branch."
  :if (lambda () (madolt-remote--upstream-target))
  :description
  (lambda ()
    (let ((target (madolt-remote--upstream-target)))
      (if target
          (format "@{upstream}, i.e. %s/%s" (car target) (cdr target))
        "no upstream")))
  (interactive (list (transient-args 'madolt-pull)))
  (let ((target (madolt-remote--upstream-target)))
    (unless target (user-error "No upstream for this branch"))
    (madolt-remote--do-pull (car target) (cdr target) args)))

(transient-define-suffix madolt-pull-from-elsewhere (remote-branch &optional args)
  "Pull from a remote branch chosen via `completing-read'.
REMOTE-BRANCH is a (REMOTE . BRANCH) cons."
  (interactive
   (list (madolt-remote--read-remote-branch "Pull from remote branch: ")
         (transient-args 'madolt-pull)))
  (madolt-remote--do-pull (car remote-branch) (cdr remote-branch) args))

(defun madolt-pull-from-default (&optional args)
  "Backward-compatible entry point: pull from the push target.
Prefer the transient suffix `madolt-pull-from-push-target' for new
code. ARGS are forwarded as transient args."
  (interactive (list (transient-args 'madolt-pull)))
  (let ((target (madolt-remote--push-target)))
    (unless target (user-error "No push target for this branch"))
    (madolt-remote--do-pull (car target) (cdr target) args)))

(defun madolt-pull-from-remote (remote &optional args)
  "Backward-compatible entry point: pull REMOTE with no branch arg.
Uses the legacy form `dolt pull <remote>'. New transient suffixes
should be preferred. ARGS are forwarded as transient args."
  (interactive
   (list (madolt-remote--read-remote "Pull from remote: " t)
         (transient-args 'madolt-pull)))
  (madolt-remote--do-pull remote nil args))

;;;; Push transient

;;;###autoload (autoload 'madolt-push "madolt-remote" nil t)
(transient-define-prefix madolt-push ()
  "Push to a remote repository."
  :value '("--user=root")
  ["Arguments"
   ("-f" "Force"          "--force")
   ("-U" "Set upstream"   "--set-upstream")
   ("-u" "User" "--user="
    :class transient-option)]
  ["Push to"
   ("p" madolt-push-to-default)
   ("e" "elsewhere"   madolt-push-to-remote)])

(transient-define-suffix madolt-push-to-default (&optional args)
  "Push current branch to a remote, prompting when multiple exist.
With a single remote, uses it directly.  With multiple remotes,
prompts via `completing-read' with the default pre-selected."
  :if (lambda () (madolt-remote--default))
  :description (lambda () (or (madolt-remote--default) "no remote"))
  (interactive (list (transient-args 'madolt-push)))
  (let* ((remote (madolt-remote--read-remote "Push to remote: "))
         (branch (madolt-current-branch))
         (result (madolt-remote--call-with-auth
                  remote args (list "push" remote branch))))
    (madolt-refresh)
    (madolt-remote--report "Push" remote result)))

(defun madolt-push-to-remote (remote &optional args)
  "Push current branch to REMOTE, always prompting for which remote.
ARGS are additional arguments from the transient."
  (interactive
   (list (madolt-remote--read-remote "Push to remote: " t)
         (transient-args 'madolt-push)))
  (let* ((branch (madolt-current-branch))
         (result (madolt-remote--call-with-auth
                  remote args (list "push" remote branch))))
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
