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
;;
;; This module provides two commit workflows:
;;
;; 1. Buffer-based (c/a suffixes): Opens a dedicated commit message
;;    buffer derived from `text-mode'.  The user composes a summary
;;    line and optional body (separated by a blank line).  A read-only
;;    diff section below the separator shows what will be committed.
;;    `C-c C-c' finalizes (extracts message, runs `dolt commit -m'),
;;    `C-c C-k' cancels.
;;
;; 2. Minibuffer (m suffix): Reads a single-line message from the
;;    minibuffer, like the previous implementation.
;;
;; Message history is shared between both workflows via
;; `madolt-commit--message-ring', with M-p/M-n navigation.
;;
;; The commit assertion checks whether staged changes exist and
;; offers to stage all if needed.

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'ring)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

;; Forward declaration for diff insertion
(declare-function madolt-refresh "madolt-mode" ())

;;;; Faces

(defface madolt-commit-summary-too-long
  '((t :inherit font-lock-warning-face))
  "Face for overlength summary lines in commit message buffers."
  :group 'madolt-faces)

(defface madolt-commit-comment
  '((t :inherit font-lock-comment-face))
  "Face for comment lines (starting with #) in commit message buffers."
  :group 'madolt-faces)

;;;; Message history

(defvar madolt-commit--message-ring (make-ring 32)
  "Ring of previous commit messages for history navigation.")

(defvar madolt-commit--message-ring-index nil
  "Current index into `madolt-commit--message-ring' during navigation.")

;;;; Buffer-local state

(defvar-local madolt-commit--args nil
  "Transient arguments for the pending commit.")

(defvar-local madolt-commit--db-dir nil
  "Database directory for the pending commit.")

(defvar-local madolt-commit--separator-pos nil
  "Marker at the start of the comment separator line.
Everything from here to the end of buffer is read-only.
This is a marker so it tracks insertions in the editable area.")

(defvar-local madolt-commit--source-buffer nil
  "The madolt status buffer that initiated this commit.
Used to refresh it after a successful commit.")

;;;; Commit message major mode

(defconst madolt-commit-summary-max-column 72
  "Maximum recommended length for the commit summary line.")

(defvar madolt-commit-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'madolt-commit-message-finish)
    (define-key map (kbd "C-c C-k") #'madolt-commit-message-cancel)
    (define-key map (kbd "M-p") #'madolt-commit-message-prev-history)
    (define-key map (kbd "M-n") #'madolt-commit-message-next-history)
    map)
  "Keymap for `madolt-commit-message-mode'.")

(define-derived-mode madolt-commit-message-mode text-mode "Madolt Commit"
  "Major mode for composing Dolt commit messages.
\\<madolt-commit-message-mode-map>\
Write a summary line, then optionally a blank line followed by a
longer body.  Lines starting with # are comments and are stripped
from the final message.

\\[madolt-commit-message-finish] to finalize the commit.
\\[madolt-commit-message-cancel] to cancel.
\\[madolt-commit-message-prev-history] / \
\\[madolt-commit-message-next-history] to cycle message history."
  :group 'madolt
  ;; Font-lock: highlight comment lines and overlength summary
  (setq font-lock-defaults
        '(madolt-commit-message-font-lock-keywords t))
  (setq-local fill-column madolt-commit-summary-max-column))

(defvar madolt-commit-message-font-lock-keywords
  `((,"^#.*$" . 'madolt-commit-comment))
  "Font-lock keywords for `madolt-commit-message-mode'.")

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

;;;; Commit commands — buffer-based

(defun madolt-commit-create (&optional args)
  "Create a new commit using a buffer-based message editor.
Opens a commit message buffer with a diff reference section.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-commit)))
  (let ((result (madolt-commit-assert args)))
    (when result
      (madolt-commit--setup-buffer nil (cdr result) nil))))

(defun madolt-commit-amend (&optional args)
  "Amend the last commit using a buffer-based message editor.
Pre-populates the buffer with the previous commit message.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-commit)))
  (let* ((last-entry (car (madolt-log-entries 1)))
         (old-message (and last-entry (plist-get last-entry :message))))
    (madolt-commit--setup-buffer old-message (or args nil) t)))

;;;; Commit commands — minibuffer (quick)

(defun madolt-commit-message (&optional args)
  "Commit with a message read from the minibuffer.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-commit)))
  (let ((result (madolt-commit-assert args)))
    (when result
      (let ((final-args (cdr result))
            (message (madolt-commit--read-message)))
        (when (and message (not (string-empty-p message)))
          (madolt-commit--do-commit message final-args))))))

;;;; Buffer setup

(defun madolt-commit--buffer-name ()
  "Return the commit message buffer name for the current database."
  (let ((db-dir (or (madolt-database-dir) default-directory)))
    (format "madolt-commit: %s"
            (file-name-nondirectory
             (directory-file-name db-dir)))))

(defun madolt-commit--setup-buffer (initial-message args amend-p)
  "Create and display the commit message buffer.
INITIAL-MESSAGE is optional pre-populated text (for amend).
ARGS are the transient arguments to pass to `dolt commit'.
When AMEND-P is non-nil, add --amend to the final arguments."
  (let* ((db-dir (or (madolt-database-dir) default-directory))
         (source-buf (current-buffer))
         (buf-name (madolt-commit--buffer-name))
         (buf (get-buffer-create buf-name))
         (final-args (if amend-p (cons "--amend" args) args)))
    (with-current-buffer buf
      ;; Activate mode first so it doesn't clobber buffer-local vars
      (madolt-commit-message-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Insert initial message or empty area for user
        (when initial-message
          (insert initial-message))
        ;; Ensure there's at least a newline for the user to type on
        (when (= (point-min) (point-max))
          (insert "\n"))
        ;; Insert separator and diff reference
        (let ((sep-start (point-max)))
          (goto-char (point-max))
          (insert "\n# ---\n")
          (insert "# Type C-c C-c to commit, C-c C-k to cancel.\n")
          (insert "# Lines starting with # are stripped.\n")
          (insert "#\n")
          ;; Insert diff summary
          (madolt-commit--insert-diff-reference db-dir final-args)
          ;; Make separator and diff read-only
          (let ((ov (make-overlay sep-start (point-max))))
            (overlay-put ov 'read-only t)
            (overlay-put ov 'evaporate nil))
          ;; Use insertion type t so the marker advances when
          ;; text is inserted at its position (i.e., when the
          ;; editable area is cleared and rewritten).
          (let ((marker (copy-marker sep-start t)))
            (setq madolt-commit--separator-pos marker))))
      ;; Set buffer-local state (after mode activation)
      (setq madolt-commit--args final-args)
      (setq madolt-commit--db-dir db-dir)
      (setq madolt-commit--source-buffer source-buf)
      ;; Position cursor at start of buffer for typing
      (goto-char (point-min))
      (when initial-message
        (goto-char (point-min))
        (end-of-line)))
    ;; Display the buffer
    (pop-to-buffer buf '((display-buffer-same-window)))))

(defun madolt-commit--insert-diff-reference (db-dir args)
  "Insert a diff summary as commented lines for reference.
DB-DIR is the database directory.  ARGS are the transient args,
used to determine whether --all/--ALL is active."
  (let ((default-directory db-dir))
    ;; Show what will be committed
    (let ((has-all (or (member "--all" args)
                       (member "--ALL" args)))
          (status (madolt-status-tables)))
      (insert "# Changes to be committed:\n")
      (if has-all
          ;; With --all/--ALL, show staged + unstaged + possibly untracked
          (let ((staged (alist-get 'staged status))
                (unstaged (alist-get 'unstaged status))
                (untracked (alist-get 'untracked status)))
            (dolist (entry staged)
              (insert (format "#   %-12s %s\n" (cdr entry) (car entry))))
            (dolist (entry unstaged)
              (insert (format "#   %-12s %s\n" (cdr entry) (car entry))))
            (when (member "--ALL" args)
              (dolist (entry untracked)
                (insert (format "#   %-12s %s\n" (cdr entry) (car entry)))))
            (when (and (null staged) (null unstaged)
                       (or (null untracked)
                           (not (member "--ALL" args))))
              (insert "#   (no changes)\n")))
        ;; Without --all, show only staged
        (let ((staged (alist-get 'staged status)))
          (if staged
              (dolist (entry staged)
                (insert (format "#   %-12s %s\n" (cdr entry) (car entry))))
            (insert "#   (no changes)\n")))))))

;;;; Buffer commands

(defun madolt-commit--extract-message ()
  "Extract the commit message from the current buffer.
Return the message string with comment lines removed and
whitespace trimmed, or nil if the message is empty."
  (let ((end (or madolt-commit--separator-pos (point-max))))
    (save-excursion
      (goto-char (point-min))
      (let ((lines nil))
        (while (< (point) end)
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            ;; Skip comment lines
            (unless (string-prefix-p "#" line)
              (push line lines)))
          (forward-line 1))
        (let ((msg (string-trim
                    (mapconcat #'identity (nreverse lines) "\n"))))
          (if (string-empty-p msg) nil msg))))))

(defun madolt-commit-message-finish ()
  "Finalize the commit with the message from the buffer.
Extract the message, run `dolt commit -m', and close the buffer."
  (interactive)
  (let ((message (madolt-commit--extract-message)))
    (unless message
      (user-error "Empty commit message"))
    (let ((args madolt-commit--args)
          (db-dir madolt-commit--db-dir)
          (source-buf madolt-commit--source-buffer))
      ;; Close the commit buffer
      (quit-window t)
      ;; Execute the commit in the database directory
      (let ((default-directory db-dir))
        (madolt-commit--do-commit message args))
      ;; Refresh source buffer if still alive
      (when (buffer-live-p source-buf)
        (with-current-buffer source-buf
          (when (derived-mode-p 'madolt-mode)
            (madolt-refresh)))))))

(defun madolt-commit-message-cancel ()
  "Cancel the commit and close the message buffer."
  (interactive)
  (message "Commit canceled.")
  (quit-window t))

;;;; Message history in buffer

(defun madolt-commit-message-prev-history ()
  "Replace the message area with the previous message from history."
  (interactive)
  (when (ring-empty-p madolt-commit--message-ring)
    (user-error "No previous commit messages"))
  (let ((index (if madolt-commit--message-ring-index
                   (1+ madolt-commit--message-ring-index)
                 0)))
    (when (>= index (ring-length madolt-commit--message-ring))
      (setq index (1- (ring-length madolt-commit--message-ring))))
    (setq madolt-commit--message-ring-index index)
    (madolt-commit--replace-message-text
     (ring-ref madolt-commit--message-ring index))))

(defun madolt-commit-message-next-history ()
  "Replace the message area with the next message from history."
  (interactive)
  (when (ring-empty-p madolt-commit--message-ring)
    (user-error "No previous commit messages"))
  (let ((index (if madolt-commit--message-ring-index
                   (1- madolt-commit--message-ring-index)
                 0)))
    (when (< index 0)
      (setq index 0))
    (setq madolt-commit--message-ring-index index)
    (madolt-commit--replace-message-text
     (ring-ref madolt-commit--message-ring index))))

(defun madolt-commit--replace-message-text (text)
  "Replace the editable message area with TEXT.
Preserves the read-only separator and diff section."
  (let ((inhibit-read-only t)
        (end (or madolt-commit--separator-pos (point-max))))
    (save-excursion
      ;; Delete old editable text (marker moves to point-min)
      (delete-region (point-min) end)
      ;; Insert new text; marker advances with insertion
      (goto-char (point-min))
      (insert text "\n"))))

;;;; Minibuffer support (for "m" quick-message suffix)

(defun madolt-commit--read-message (&optional initial)
  "Read a commit message from the minibuffer.
INITIAL is the initial input (e.g., for amend).
Supports history navigation via `madolt-commit--message-ring'."
  (setq madolt-commit--message-ring-index nil)
  (let ((minibuffer-local-map (madolt-commit--make-minibuffer-map)))
    (read-from-minibuffer "Commit message: " initial)))

(defun madolt-commit--make-minibuffer-map ()
  "Create a minibuffer keymap with history navigation bindings."
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

;;;; Internal

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
