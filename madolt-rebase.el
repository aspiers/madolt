;;; madolt-rebase.el --- Rebase commands for Madolt  -*- lexical-binding:t -*-

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

;; Rebase transient menu and rebase commands for madolt.
;;
;; Provides rebase onto another branch, continue/abort an in-progress
;; rebase, and common flags via the `dolt rebase' CLI command.

;;; Code:

(require 'transient)
(require 'madolt-dolt)
(require 'madolt-process)

(declare-function madolt-branch-or-commit-at-point "madolt-mode" ())
(declare-function madolt-display-buffer "madolt-mode" (buffer))

;;;; Transient menu

;;;###autoload (autoload 'madolt-rebase "madolt-rebase" nil t)
(transient-define-prefix madolt-rebase ()
  "Rebase the current branch."
  ["Arguments"
   :if-not madolt-rebase-in-progress-p
   ("-i" "Interactive"          "--interactive")
   ("-e" "Empty commits: keep"  "--empty=keep")]
  [:if-not madolt-rebase-in-progress-p
   :description (lambda ()
                  (format (propertize "Rebase %s onto" 'face 'transient-heading)
                          (propertize (or (madolt-current-branch) "HEAD")
                                      'face 'madolt-branch-local)))
   ("e" "elsewhere"  madolt-rebase-elsewhere)]
  ["Rebase"
   :if-not madolt-rebase-in-progress-p
   ("i" "interactively"  madolt-rebase-interactive)]
  ["Actions"
   :if madolt-rebase-in-progress-p
   ("r" "Continue"     madolt-rebase-continue-command)
   ("s" "Skip"         madolt-rebase-skip-command)
   ("a" "Abort"        madolt-rebase-abort-command)])

;;;; Interactive commands

(defun madolt-rebase-elsewhere (upstream &optional args)
  "Rebase current branch onto UPSTREAM.
UPSTREAM can be a branch name or commit hash.
ARGS are additional arguments from the transient."
  (interactive
   (let* ((current (madolt-current-branch))
          (at-point (madolt-branch-or-commit-at-point))
          (default (and at-point
                        (not (equal at-point current))
                        at-point)))
     (list (completing-read
            (format "Rebase %s onto%s: " current
                    (if default (format " (default %s)" default) ""))
            (append (remove current (madolt-branch-names))
                    (madolt-all-ref-names))
            nil nil nil nil default)
           (transient-args 'madolt-rebase))))
  (when (string-empty-p upstream)
    (user-error "Must specify an upstream branch"))
  (let ((result (apply #'madolt-call-dolt "rebase" (append args (list upstream)))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebased %s onto %s" (madolt-current-branch) upstream)
      (message "Rebase failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-interactive (upstream &optional _args)
  "Start an interactive rebase of current branch onto UPSTREAM.
Uses the SQL DOLT_REBASE procedure to create a rebase plan in the
dolt_rebase system table.  The plan can then be edited via SQL and
applied with `dolt rebase --continue'.
_ARGS are accepted for transient compatibility but unused since
interactive rebase uses SQL directly."
  (interactive
   (let* ((current (madolt-current-branch))
          (at-point (madolt-branch-or-commit-at-point))
          (default (and at-point
                        (not (equal at-point current))
                        at-point)))
     (list (if default
               ;; Use the commit/branch at point without prompting
               default
             (completing-read
              (format "Rebase %s onto interactively: " current)
              (append (remove current (madolt-branch-names))
                      (madolt-all-ref-names))
              nil nil nil nil nil))
           (transient-args 'madolt-rebase))))
  (when (string-empty-p upstream)
    (user-error "Must specify an upstream branch"))
  ;; Use SQL DOLT_REBASE because the CLI interactive rebase requires
  ;; $EDITOR which Dolt v1.82.x doesn't support properly.
  (let* ((branch (madolt-current-branch))
         (db-dir (or (madolt-database-dir) default-directory))
         (query (format "CALL DOLT_REBASE('-i', '%s')"
                        (replace-regexp-in-string "'" "''" upstream)))
         (result (madolt-call-dolt "sql" "-q" query)))
    (if (zerop (car result))
        ;; Don't refresh before showing the plan — refreshing runs
        ;; CLI commands that Dolt may interpret as branch changes,
        ;; causing --continue to fail with "changes in branch".
        (madolt-rebase--show-plan branch upstream db-dir)
      (madolt-refresh)
      (message "Rebase failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-continue-command ()
  "Continue a rebase after resolving conflicts or adjusting the plan.
Tries SQL DOLT_REBASE first (for SQL-initiated rebases), then
falls back to CLI."
  (interactive)
  (let* ((branch (madolt-current-branch))
         (rebase-branch (concat "dolt_rebase_" branch))
         (sql-rebase (and branch
                         (member rebase-branch (madolt-branch-names))))
         (result (if sql-rebase
                     (madolt-call-dolt "--branch" rebase-branch
                                       "sql" "-q"
                                       "CALL DOLT_REBASE('--continue')")
                   (madolt-call-dolt "rebase" "--continue"))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebase continued successfully")
      (message "Continue failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-skip-command ()
  "Skip the current commit in a rebase."
  (interactive)
  ;; Dolt doesn't have --skip; drop the current commit from the
  ;; rebase plan via SQL update, then continue.
  (let ((result (madolt-call-dolt "sql" "-q"
                                  "UPDATE dolt_rebase SET action = 'drop' WHERE rebase_order = (SELECT MIN(rebase_order) FROM dolt_rebase WHERE action = 'pick')")))
    (if (zerop (car result))
        (madolt-rebase-continue-command)
      (message "Skip failed: %s" (string-trim (cdr result))))))

(defun madolt-rebase-abort-command ()
  "Abort the current rebase.
Tries SQL DOLT_REBASE first (for SQL-initiated rebases), then
falls back to CLI."
  (interactive)
  (let* ((branch (madolt-current-branch))
         (rebase-branch (concat "dolt_rebase_" branch))
         (sql-rebase (and branch
                         (member rebase-branch (madolt-branch-names))))
         (result (if sql-rebase
                     (madolt-call-dolt "--branch" rebase-branch
                                       "sql" "-q"
                                       "CALL DOLT_REBASE('--abort')")
                   (madolt-call-dolt "rebase" "--abort"))))
    (madolt-refresh)
    (if (zerop (car result))
        (message "Rebase aborted")
      (message "Abort failed: %s" (string-trim (cdr result))))))

;;;; Rebase plan editor

(defvar-local madolt-rebase--branch nil
  "The branch being rebased.")

(defvar-local madolt-rebase--upstream nil
  "The upstream branch for the rebase.")

(defvar-local madolt-rebase--db-dir nil
  "The database directory for the rebase.")

(defvar-keymap madolt-rebase-mode-map
  :doc "Keymap for madolt rebase plan editor."
  :parent special-mode-map
  "c"     #'madolt-rebase-plan-pick
  "d"     #'madolt-rebase-plan-drop
  "k"     #'madolt-rebase-plan-drop
  "s"     #'madolt-rebase-plan-squash
  "f"     #'madolt-rebase-plan-fixup
  "r"     #'madolt-rebase-plan-reword
  "w"     #'madolt-rebase-plan-reword
  "p"     #'previous-line
  "n"     #'next-line
  "M-p"   #'madolt-rebase-plan-move-up
  "M-n"   #'madolt-rebase-plan-move-down
  "M-<up>"   #'madolt-rebase-plan-move-up
  "M-<down>" #'madolt-rebase-plan-move-down
  "C-c C-c"  #'madolt-rebase-plan-finish
  "C-c C-k"  #'madolt-rebase-plan-abort)

(define-derived-mode madolt-rebase-mode special-mode "Madolt Rebase"
  "Mode for editing a Dolt interactive rebase plan.
\\<madolt-rebase-mode-map>
Change the action for the commit at point:
  \\[madolt-rebase-plan-pick]     pick
  \\[madolt-rebase-plan-squash]   squash
  \\[madolt-rebase-plan-fixup]    fixup
  \\[madolt-rebase-plan-drop]     drop
  \\[madolt-rebase-plan-reword]   reword

Reorder commits:
  \\[madolt-rebase-plan-move-up]   move up
  \\[madolt-rebase-plan-move-down] move down

Finish or abort:
  \\[madolt-rebase-plan-finish]  apply the plan
  \\[madolt-rebase-plan-abort]   abort the rebase"
  (setq truncate-lines t))

(defun madolt-rebase--read-plan ()
  "Read the rebase plan from the dolt_rebase table.
Uses --branch to query the rebase branch without checking it out.
Returns a list of plists (:order :action :hash :message)."
  (let* ((rebase-branch (concat "dolt_rebase_" madolt-rebase--branch))
         (json (let ((default-directory madolt-rebase--db-dir))
                 (madolt-dolt-json
                  "--branch" rebase-branch
                  "sql" "-q"
                  "SELECT * FROM dolt_rebase ORDER BY rebase_order"
                  "-r" "json"))))
    (when json
      (let ((rows (alist-get 'rows json)))
        (mapcar (lambda (row)
                  (list :order (string-to-number
                                (alist-get 'rebase_order row))
                        :action (alist-get 'action row)
                        :hash (alist-get 'commit_hash row)
                        :message (alist-get 'commit_message row)))
                rows)))))

(defun madolt-rebase--render-plan (plan)
  "Render PLAN entries in the current buffer.
Commits appear first, followed by help comments, matching magit's
git-rebase-todo layout."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (dolist (entry plan)
      (let* ((action (plist-get entry :action))
             (hash (plist-get entry :hash))
             (short-hash (substring hash 0 (min 8 (length hash))))
             (message (plist-get entry :message))
             (face (pcase action
                     ("pick"   'madolt-diff-added)
                     ("squash" 'madolt-diff-old)
                     ("fixup"  'madolt-diff-old)
                     ("drop"   'madolt-diff-removed)
                     ("reword" 'madolt-diff-new)
                     (_        'default))))
        (let ((line-start (point)))
          (insert (propertize (format "%-7s" action) 'font-lock-face face)
                  " "
                  (propertize short-hash 'font-lock-face 'madolt-hash)
                  " "
                  (or message "")
                  "\n")
          (when (equal action "drop")
            (let ((ov (make-overlay line-start (1- (point)))))
              (overlay-put ov 'madolt-drop t)
              (overlay-put ov 'face '(:strike-through t)))))))
    (insert (propertize
             (concat
              "\n"
              (format "# Rebase %s onto %s (%d command%s)\n"
                      madolt-rebase--branch madolt-rebase--upstream
                      (length plan) (if (= 1 (length plan)) "" "s"))
              "#\n"
              "# Commands:\n"
              "# C-c C-c  apply the rebase plan\n"
              "# C-c C-k  abort the rebase\n"
              "# p        move point to previous line\n"
              "# n        move point to next line\n"
              "# M-p      move the commit at point up\n"
              "# M-n      move the commit at point down\n"
              "# c        pick = use commit\n"
              "# r        reword = use commit, but edit the commit message\n"
              "# s        squash = use commit, but meld into previous commit\n"
              "# f        fixup = like squash, but discard this commit's message\n"
              "# d        drop = remove commit\n"
              "#\n"
              "# These lines can be re-ordered; they are executed from top to bottom.\n"
              "#\n"
              "# If you drop a line here THAT COMMIT WILL BE LOST.\n")
             'font-lock-face 'font-lock-comment-face))
    (goto-char (point-min))))

(defun madolt-rebase--current-line-data ()
  "Return the plan entry data for the current line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "\\(\\w+\\) +\\([a-z0-9]+\\) +\\(.*\\)")
      (list :action (match-string-no-properties 1)
            :hash-prefix (match-string-no-properties 2)
            :message (match-string-no-properties 3)))))

(defun madolt-rebase--set-action (action)
  "Set the ACTION for the commit on the current line."
  (let ((data (madolt-rebase--current-line-data)))
    (unless data
      (user-error "No commit on this line"))
    (let ((inhibit-read-only t)
          (line-start (line-beginning-position))
          (line-end (line-end-position)))
      (beginning-of-line)
      (when (looking-at "\\w+")
        (let ((face (pcase action
                      ("pick"   'madolt-diff-added)
                      ("squash" 'madolt-diff-old)
                      ("fixup"  'madolt-diff-old)
                      ("drop"   'madolt-diff-removed)
                      ("reword" 'madolt-diff-new)
                      (_        'default))))
          (replace-match (propertize (format "%-7s" action)
                                     'font-lock-face face)))
        ;; Add/remove strikethrough on the whole line for drop
        (let ((ov (cl-find-if (lambda (o) (overlay-get o 'madolt-drop))
                              (overlays-in line-start line-end))))
          (if (equal action "drop")
              (unless ov
                (let ((new-ov (make-overlay line-start line-end)))
                  (overlay-put new-ov 'madolt-drop t)
                  (overlay-put new-ov 'face '(:strike-through t))))
            (when ov
              (delete-overlay ov))))))))

(defun madolt-rebase-plan-pick ()
  "Set the current commit to pick." (interactive)
  (madolt-rebase--set-action "pick"))

(defun madolt-rebase-plan-squash ()
  "Set the current commit to squash." (interactive)
  (madolt-rebase--set-action "squash"))

(defun madolt-rebase-plan-fixup ()
  "Set the current commit to fixup." (interactive)
  (madolt-rebase--set-action "fixup"))

(defun madolt-rebase-plan-drop ()
  "Set the current commit to drop and move to next line." (interactive)
  (madolt-rebase--set-action "drop")
  (forward-line 1)
  (beginning-of-line))

(defun madolt-rebase-plan-reword ()
  "Set the current commit to reword." (interactive)
  (madolt-rebase--set-action "reword"))

(defun madolt-rebase-plan-move-up ()
  "Move the current commit up in the rebase plan."
  (interactive)
  (when (madolt-rebase--current-line-data)
    (let ((inhibit-read-only t)
          (col (current-column)))
      (beginning-of-line)
      (when (save-excursion
              (forward-line -1)
              (madolt-rebase--current-line-data))
        (let ((line (delete-and-extract-region
                     (line-beginning-position) (1+ (line-end-position)))))
          (forward-line -1)
          (insert line)
          (forward-line -1)
          (move-to-column col))))))

(defun madolt-rebase-plan-move-down ()
  "Move the current commit down in the rebase plan."
  (interactive)
  (when (madolt-rebase--current-line-data)
    (let ((inhibit-read-only t)
          (col (current-column)))
      (beginning-of-line)
      (when (save-excursion
              (forward-line 1)
              (madolt-rebase--current-line-data))
        (let ((line (delete-and-extract-region
                     (line-beginning-position) (1+ (line-end-position)))))
          (forward-line 1)
          (insert line)
          (forward-line -1)
          (move-to-column col))))))

(defun madolt-rebase--parse-buffer ()
  "Parse the buffer into a list of (action . hash-prefix) entries."
  (let ((entries nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((data (madolt-rebase--current-line-data)))
          (when data
            (push (cons (plist-get data :action)
                        (plist-get data :hash-prefix))
                  entries)))
        (forward-line 1)))
    (nreverse entries)))

(defun madolt-rebase-plan-finish ()
  "Apply the rebase plan by updating dolt_rebase and continuing."
  (interactive)
  (let* ((entries (madolt-rebase--parse-buffer))
         (default-directory madolt-rebase--db-dir)
         (rebase-branch (concat "dolt_rebase_" madolt-rebase--branch)))
    ;; Build a single SQL statement that updates all entries.
    ;; First shift all orders to high values to avoid PK conflicts,
    ;; then set the final orders and actions.
    (let* ((shift-stmts
            (let ((i 1000))
              (mapcar (lambda (entry)
                        (prog1
                            (format "UPDATE dolt_rebase SET rebase_order=%d.00 WHERE commit_hash LIKE '%s%%'"
                                    i (cdr entry))
                          (cl-incf i)))
                      entries)))
           (update-stmts
            (let ((order 1))
              (mapcar (lambda (entry)
                        (prog1
                            (format "UPDATE dolt_rebase SET action='%s', rebase_order=%d.00 WHERE commit_hash LIKE '%s%%'"
                                    (car entry) order (cdr entry))
                          (cl-incf order)))
                      entries)))
           (all-sql (mapconcat #'identity
                               (append shift-stmts update-stmts)
                               ";\n"))
           ;; Use madolt--run-cli directly to avoid cluttering the
           ;; process buffer with the lengthy plan update SQL.
           (result (madolt--run-cli
                    (list "--branch" rebase-branch "sql" "-q" all-sql))))
      (unless (zerop (car result))
        (user-error "Failed to update plan: %s"
                    (string-trim (cdr result)))))
    ;; Continue the rebase from the rebase branch
    (let ((result (madolt-call-dolt
                   "--branch" rebase-branch
                   "sql" "-q" "CALL DOLT_REBASE('--continue')")))
      (kill-buffer (current-buffer))
      (madolt-refresh)
      (if (zerop (car result))
          (message "Rebase completed successfully")
        (message "Rebase failed: %s" (string-trim (cdr result)))))))

(defun madolt-rebase-plan-abort ()
  "Abort the rebase and kill the plan buffer."
  (interactive)
  (when (y-or-n-p "Abort the rebase? ")
    (let* ((default-directory madolt-rebase--db-dir)
           (rebase-branch (concat "dolt_rebase_" madolt-rebase--branch)))
      (madolt-call-dolt "--branch" rebase-branch
                        "sql" "-q" "CALL DOLT_REBASE('--abort')"))
    (kill-buffer (current-buffer))
    (madolt-refresh)
    (message "Rebase aborted")))

(defun madolt-rebase--show-plan (branch upstream db-dir)
  "Show the rebase plan editor for BRANCH onto UPSTREAM.
DB-DIR is the database directory."
  (let ((buf (get-buffer-create (format "*madolt-rebase: %s*" branch))))
    (with-current-buffer buf
      (madolt-rebase-mode)
      (setq madolt-rebase--branch branch
            madolt-rebase--upstream upstream
            madolt-rebase--db-dir db-dir)
      (let ((plan (madolt-rebase--read-plan)))
        (if plan
            (madolt-rebase--render-plan plan)
          (kill-buffer buf)
          (user-error "No rebase plan found"))))
    (madolt-display-buffer buf)))

(provide 'madolt-rebase)
;;; madolt-rebase.el ends here
