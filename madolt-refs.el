;;; madolt-refs.el --- References buffer for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7"))

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

;; References buffer for madolt.  Displays local branches, remote
;; branches, and tags in a navigable section-based buffer.
;; Bound to `y' in madolt-mode, mirroring magit-show-refs.

;;; Code:

(require 'magit-section)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-mode)

;;;; Visibility cache

(defvar madolt-refs--visibility-caches (make-hash-table :test 'equal)
  "Hash table mapping database directories to section visibility caches.
Used to preserve expand/collapse state across buffer recreations,
mirroring magit's `magit-preserve-section-visibility-cache'.")

(defun madolt-refs--preserve-visibility-cache ()
  "Save section visibility cache for the current refs buffer.
Added to `kill-buffer-hook' so the cache survives buffer kills."
  (when (and (derived-mode-p 'madolt-refs-mode)
             madolt-buffer-database-dir
             magit-section-visibility-cache)
    (puthash madolt-buffer-database-dir
             magit-section-visibility-cache
             madolt-refs--visibility-caches)))

(defun madolt-refs--restore-visibility-cache ()
  "Restore section visibility cache for the current refs buffer."
  (when madolt-buffer-database-dir
    (setq magit-section-visibility-cache
          (gethash madolt-buffer-database-dir
                   madolt-refs--visibility-caches))))

;;;; Faces

(defface madolt-branch-local
  '((((class color) (background light)) :foreground "SkyBlue4")
    (((class color) (background dark))  :foreground "LightSkyBlue1"))
  "Face for local branch names in refs buffers."
  :group 'madolt-faces)

(defface madolt-branch-remote
  '((((class color) (background light)) :foreground "DarkOliveGreen4")
    (((class color) (background dark))  :foreground "DarkSeaGreen2"))
  "Face for remote branch names in refs buffers."
  :group 'madolt-faces)

(defface madolt-branch-remote-head
  '((t :inherit madolt-branch-remote :box t))
  "Face for the remote HEAD branch (e.g. origin/HEAD)."
  :group 'madolt-faces)

(defface madolt-branch-current
  '((t :inherit madolt-branch-local :box t))
  "Face for the current branch in refs buffers."
  :group 'madolt-faces)

(defface madolt-branch-upstream
  '((t :inherit madolt-branch-remote :slant italic))
  "Face for upstream tracking branches."
  :group 'madolt-faces)

(defface madolt-branch-warning
  '((t :inherit warning))
  "Face for warning indicators on branches."
  :group 'madolt-faces)

(defface madolt-tag
  '((((class color) (background light)) :foreground "Goldenrod4")
    (((class color) (background dark))  :foreground "LightGoldenrod2"))
  "Face for tag names in refs buffers."
  :group 'madolt-faces)

;;;; Customization

(defcustom madolt-refs-sections-hook
  (list #'madolt-refs--insert-local-branches
        #'madolt-refs--insert-remote-branches
        #'madolt-refs--insert-tags)
  "Hook run to insert sections into a refs buffer.
Each function is called with no arguments.  Data is available
via `madolt-refs--local-branches', `madolt-refs--remote-branches',
and `madolt-refs--tags'."
  :group 'madolt
  :type 'hook)

(defcustom madolt-refs-primary-column-width '(16 . 32)
  "Width of the primary column in refs buffers.
If an integer, the column is that many columns wide.  Otherwise
it must be a cons cell (MIN . MAX), in which case the column is
auto-sized to fit the longest branch name, clamped to that range."
  :group 'madolt
  :type '(choice integer (cons integer integer)))

(defcustom madolt-refs-show-remote-prefix nil
  "Whether to show the remote prefix in remote branch names.
When nil (the default), show just the branch name (e.g. \"main\").
When non-nil, show \"origin/main\"."
  :group 'madolt
  :type 'boolean)

(defcustom madolt-refs-margin '(nil age 18 t 18)
  "Format of the margin in `madolt-refs-mode' buffers.
The value has the form (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH).

If INIT is non-nil, the margin is shown initially.
STYLE controls how dates are displayed:
  `age'              -- show relative age (e.g. \"2 days\")
  `age-abbreviated'  -- show abbreviated age (e.g. \"2d\")
  a format string    -- use `format-time-string' (e.g. \"%Y-%m-%d\")
WIDTH is the total width of the margin.
If AUTHOR is non-nil, show author names.
AUTHOR-WIDTH is the width of the author column."
  :group 'madolt
  :type '(list (boolean :tag "Show margin initially")
               (choice  :tag "Show committer"
                        (string :tag "date using time-format" "%Y-%m-%d %H:%M ")
                        (const  :tag "date's age" age)
                        (const  :tag "date's age (abbreviated)" age-abbreviated))
               (integer :tag "Margin width")
               (boolean :tag "Show author name by default")
               (integer :tag "Show author name using width")))

;;;; Refs mode

(define-derived-mode madolt-refs-mode madolt-mode "Madolt Refs"
  "Mode for madolt refs buffers."
  (add-hook 'kill-buffer-hook #'madolt-refs--preserve-visibility-cache nil t))

;;;; Section keymaps

(defun madolt-refs-visit-branch ()
  "Check out the branch at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (let ((value (oref section value)))
      (when (and value (eq (oref section type) 'branch))
        ;; Strip remote prefix for remote branches
        (if (string-match "^\\([^/]+\\)/\\(.+\\)$" value)
            (madolt-branch-checkout-create
             (match-string 2 value)
             value)
          (madolt-branch-checkout value))
        (madolt-refresh)))))

(defun madolt-refs-delete-branch ()
  "Delete the branch at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (let ((value (oref section value)))
      (when (and value (eq (oref section type) 'branch))
        (when (yes-or-no-p (format "Delete branch %s? " value))
          (madolt-branch-delete value)
          (madolt-refresh))))))

(defun madolt-refs-rename-branch ()
  "Rename the branch at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (let ((value (oref section value)))
      (when (and value (eq (oref section type) 'branch))
        (let ((new-name (read-string
                         (format "Rename branch %s to: " value)
                         value)))
          (madolt-branch-rename value new-name)
          (madolt-refresh))))))

(defun madolt-refs-delete-tag ()
  "Delete the tag at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (let ((value (oref section value)))
      (when (and value (eq (oref section type) 'tag))
        (when (yes-or-no-p (format "Delete tag %s? " value))
          (madolt-tag-delete value)
          (madolt-refresh))))))

(defun madolt-refs-delete-remote ()
  "Remove the remote at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (let ((value (oref section value)))
      (when (and value (eq (oref section type) 'remote))
        (when (yes-or-no-p (format "Remove remote %s? " value))
          (madolt-remote-remove value)
          (madolt-refresh))))))

;; Section keymaps follow the magit-<type>-section-map naming
;; convention, which magit-section resolves automatically.
;; Only define them if magit hasn't already (i.e. magit-refs not loaded).

(unless (and (boundp 'magit-branch-section-map)
             (keymapp (symbol-value 'magit-branch-section-map)))
  (defvar-keymap magit-branch-section-map
    :doc "Keymap for `branch' sections."
    "RET"   #'madolt-refs-visit-branch
    "k"     #'madolt-refs-delete-branch
    "R"     #'madolt-refs-rename-branch))

(unless (and (boundp 'magit-remote-section-map)
             (keymapp (symbol-value 'magit-remote-section-map)))
  (defvar-keymap magit-remote-section-map
    :doc "Keymap for `remote' sections."
    "k"     #'madolt-refs-delete-remote))

(unless (and (boundp 'magit-tag-section-map)
             (keymapp (symbol-value 'magit-tag-section-map)))
  (defvar-keymap magit-tag-section-map
    :doc "Keymap for `tag' sections."
    "k"     #'madolt-refs-delete-tag))

;;;; Transient menu

;;;###autoload (autoload 'madolt-show-refs "madolt-refs" nil t)
(transient-define-prefix madolt-show-refs (&optional transient)
  "List references.
Without a prefix argument, directly show the refs buffer
comparing against HEAD.  With a prefix argument (or when already
in a refs buffer), show the transient menu to choose options."
  ["Actions"
   ("y" "Show refs for HEAD"           madolt-show-refs-head)
   ("c" "Show refs for current branch" madolt-show-refs-current)
   ("o" "Show refs for other branch"   madolt-show-refs-other)]
  (interactive (list (or (derived-mode-p 'madolt-refs-mode)
                         current-prefix-arg)))
  (if transient
      (transient-setup 'madolt-show-refs)
    (madolt-refs--show "HEAD")))

;;;; Commands

(defvar-local madolt-refs--upstream nil
  "The reference to compare against in this refs buffer.")

(defvar-local madolt-refs--local-branches nil
  "Local branches for the current refresh cycle.")

(defvar-local madolt-refs--remote-branches nil
  "Remote branches for the current refresh cycle.")

(defvar-local madolt-refs--tags nil
  "Tags for the current refresh cycle.")

(defvar-local madolt-refs--remotes-alist nil
  "Remotes alist for the current refresh cycle.")

(defun madolt-show-refs-head ()
  "Show refs comparing against HEAD."
  (interactive)
  (madolt-refs--show "HEAD"))

(defun madolt-show-refs-current ()
  "Show refs comparing against the current branch."
  (interactive)
  (madolt-refs--show (or (madolt-current-branch) "HEAD")))

(defun madolt-show-refs-other (ref)
  "Show refs comparing against REF."
  (interactive
   (list (completing-read "Show refs for: " (madolt-branch-names))))
  (madolt-refs--show ref))

;;;; Buffer setup

(defun madolt-refs--show (upstream)
  "Show refs buffer comparing against UPSTREAM."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (db-name (file-name-nondirectory
                   (directory-file-name db-dir)))
         (buf-name (format "madolt-refs: %s" db-name))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'madolt-refs-mode)
        (madolt-refs-mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (setq madolt-refs--upstream upstream)
      (madolt-refs--restore-visibility-cache)
      (madolt-refs--setup-margin)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-refs-refresh-buffer ()
  "Refresh the refs buffer."
  (setq header-line-format
        (propertize (format " Comparing with %s"
                            (or madolt-refs--upstream "HEAD"))
                    'font-lock-face 'magit-header-line))
  ;; Populate data for section inserters
  (let ((branches (madolt-branch-list-verbose)))
    (setq madolt-refs--local-branches
          (cl-remove-if (lambda (b) (plist-get b :remote)) branches))
    (setq madolt-refs--remote-branches
          (cl-remove-if-not (lambda (b) (plist-get b :remote)) branches)))
  (setq madolt-refs--tags (madolt-tag-list-verbose))
  (setq madolt-refs--remotes-alist (madolt-remotes))
  (magit-insert-section (branchbuf)
    (magit-run-section-hook 'madolt-refs-sections-hook))
  ;; Set up margin windows after rendering
  (when (madolt-refs--margin-active-p)
    (dolist (window (get-buffer-window-list nil nil 0))
      (with-selected-window window
        (madolt-refs--set-window-margin window)
        (add-hook 'window-configuration-change-hook
                  #'madolt-refs--set-window-margin nil t)))))

;;;; Focus column

(defun madolt-refs--format-focus-column (current name)
  "Format the focus column indicator for a branch line.
CURRENT is non-nil if this is the current branch.
NAME is the branch name.
When comparing against HEAD, use @ for the current branch.
When comparing against a named ref, use * for the matching ref."
  (cond
   ;; Current branch and comparing against HEAD: use @
   ((and current (equal madolt-refs--upstream "HEAD"))
    (propertize "@ " 'font-lock-face 'magit-section-heading))
   ;; Branch matches the comparison target: use *
   ((equal name madolt-refs--upstream)
    (propertize "* " 'font-lock-face 'magit-section-heading))
   ;; Current branch (comparing against named ref): use space
   (current "  ")
   ;; Other branches: use space
   (t "  ")))

;;;; Margin support

(defvar-local madolt-refs--margin-config nil
  "Current margin configuration for this refs buffer.
A list of (ACTIVE STYLE WIDTH AUTHOR AUTHOR-WIDTH).")

(defun madolt-refs--setup-margin ()
  "Initialize the right margin for the refs buffer."
  (setq madolt-refs--margin-config (copy-sequence madolt-refs-margin)))

(defun madolt-refs--margin-active-p ()
  "Return non-nil if the right margin is active."
  (and madolt-refs--margin-config
       (car madolt-refs--margin-config)))

(defun madolt-refs--set-window-margin (&optional window)
  "Set the right margin width for WINDOW."
  (when (or window (setq window (get-buffer-window)))
    (with-selected-window window
      (set-window-margins
       nil
       (car (window-margins))
       (and (madolt-refs--margin-active-p)
            (nth 2 madolt-refs--margin-config))))))

(defun madolt-refs--format-age (date &optional abbreviate)
  "Format DATE as a relative age string.
DATE is a Unix timestamp as a number or string.
When ABBREVIATE is non-nil, use short form (e.g. \"2d\" vs \"2 days\")."
  (let* ((seconds (abs (- (float-time)
                          (if (stringp date)
                              (string-to-number date)
                            date))))
         (spec `((?Y "year"   "years"   ,(round (* 60 60 24 365.2425)))
                 (?M "month"  "months"  ,(round (* 60 60 24 30.436875)))
                 (?w "week"   "weeks"   ,(* 60 60 24 7))
                 (?d "day"    "days"    ,(* 60 60 24))
                 (?h "hour"   "hours"   ,(* 60 60))
                 (?m "minute" "minutes" 60)
                 (?s "second" "seconds" 1))))
    (cl-loop for (char unit units weight) in spec
             when (or (null (cdr (memq (assq char spec) spec)))
                      (>= (/ seconds weight) 1))
             return (let ((cnt (round (/ seconds weight 1.0))))
                      (if abbreviate
                          (format "%d%c" cnt char)
                        (format "%d %s" cnt (if (= cnt 1) unit units)))))))

(defun madolt-refs--format-margin-string (author date)
  "Format AUTHOR and DATE for the right margin overlay.
Uses `madolt-refs--margin-config' to control style and width."
  (when madolt-refs--margin-config
    (pcase-let ((`(,_active ,style ,width ,details ,details-width)
                 madolt-refs--margin-config))
      (concat (and details author
                   (concat (propertize
                            (truncate-string-to-width
                             author details-width nil ?\s)
                            'font-lock-face 'shadow)
                           " "))
              (propertize
               (if (stringp style)
                   (format-time-string
                    style
                    (seconds-to-time
                     (if (stringp date) (string-to-number date) date)))
                 (let* ((abbr (eq style 'age-abbreviated))
                        (age-str (madolt-refs--format-age date abbr)))
                   (format (format "%%-%ds"
                                   (- width
                                      (if (and details author)
                                          (1+ details-width) 0)))
                           age-str)))
               'font-lock-face 'shadow)))))

(defun madolt-refs--make-margin-overlay (&optional string)
  "Create a right-margin overlay with STRING on the previous line."
  (save-excursion
    (forward-line (if (bolp) -1 0))
    (let ((o (make-overlay (1+ (point)) (line-end-position) nil t)))
      (overlay-put o 'evaporate t)
      (overlay-put o 'before-string
                   (propertize "o" 'display
                               (list (list 'margin 'right-margin)
                                     (or string " ")))))))

(defun madolt-refs--maybe-format-margin (hash)
  "Insert a margin overlay for the commit at HASH, if margin is active."
  (when (madolt-refs--margin-active-p)
    (let* ((entry (car (madolt-log-entries 1 hash)))
           (author (and entry (plist-get entry :author)))
           (date (and entry (plist-get entry :date))))
      (if (and author date)
          (madolt-refs--make-margin-overlay
           (madolt-refs--format-margin-string author date))
        (madolt-refs--make-margin-overlay)))))

;;;; Cherry commits

(defun madolt-refs--insert-cherry-commits (ref)
  "Insert cherry commits for REF as expandable sub-section body.
Shows commits in REF that are not in the comparison upstream.
Since dolt lacks `git cherry', uses `dolt log upstream..ref' instead."
  (magit-insert-section-body
    (let* ((upstream (or madolt-refs--upstream "HEAD"))
           (range (format "%s..%s" upstream ref))
           (entries (condition-case nil
                        (madolt-log-entries 25 range)
                      (error nil))))
      (when entries
        (dolist (entry entries)
          (let* ((hash (plist-get entry :hash))
                 (msg (or (plist-get entry :message) ""))
                 (short-hash (if (> (length hash) 7)
                                 (substring hash 0 7)
                               hash)))
            (magit-insert-section (commit hash)
              (magit-insert-heading
                (concat
                 "  "
                 (propertize short-hash 'font-lock-face 'shadow)
                 " " msg "\n")))))))))

;;;; Section inserters

(defun madolt-refs--column-width (names)
  "Return the column width for displaying NAMES.
Uses `madolt-refs-primary-column-width' to determine the width.
NAMES is a list of strings whose lengths determine auto-sizing."
  (let ((width (if names
                   (apply #'max (mapcar #'length names))
                 0)))
    (if (consp madolt-refs-primary-column-width)
        (min (max width (car madolt-refs-primary-column-width))
             (cdr madolt-refs-primary-column-width))
      madolt-refs-primary-column-width)))

(defun madolt-refs--find-upstream (branch-name remote-branches)
  "Find the upstream ref for BRANCH-NAME among REMOTE-BRANCHES.
Uses the convention that origin/BRANCH-NAME is the upstream.
If no \"origin\" remote exists, tries the first remote found.
Returns the upstream display string (e.g. \"origin/main\") or nil."
  (let (first-remote match)
    (dolist (rb remote-branches)
      (when (string= (plist-get rb :name) branch-name)
        (let ((remote (plist-get rb :remote)))
          (unless first-remote
            (setq first-remote (format "%s/%s" remote branch-name)))
          (when (string= remote "origin")
            (setq match (format "%s/%s" remote branch-name))))))
    (or match first-remote)))

(defun madolt-refs--ahead-behind (branch-name upstream)
  "Return (AHEAD . BEHIND) counts for BRANCH-NAME vs UPSTREAM.
AHEAD is commits in BRANCH-NAME not in UPSTREAM.
BEHIND is commits in UPSTREAM not in BRANCH-NAME."
  (let ((ahead (length (madolt-log-entries
                        100 (format "%s..%s" upstream branch-name))))
        (behind (length (madolt-log-entries
                         100 (format "%s..%s" branch-name upstream)))))
    (cons ahead behind)))

(defun madolt-refs--format-upstream-info (upstream ahead behind)
  "Format UPSTREAM tracking info with AHEAD and BEHIND counts.
Returns a propertized string like \"origin/main\" with optional
ahead/behind indicators."
  (let ((parts (list (propertize upstream
                                 'font-lock-face 'shadow))))
    (when (and ahead (> ahead 0))
      (push (propertize (format "%d>" ahead)
                        'font-lock-face 'shadow)
            parts))
    (when (and behind (> behind 0))
      (push (propertize (format "<%d" behind)
                        'font-lock-face 'shadow)
            parts))
    (string-join (nreverse parts) " ")))

(defun madolt-refs--insert-local-branches ()
  "Insert a section listing local branches.
Uses `madolt-refs--local-branches' and `madolt-refs--remote-branches'."
  (let ((branches madolt-refs--local-branches)
        (remote-branches madolt-refs--remote-branches))
  (when branches
    (let ((col-width (madolt-refs--column-width
                      (mapcar (lambda (b) (plist-get b :name)) branches))))
      (magit-insert-section (local nil t)
        (magit-insert-heading "Branches")
        (dolist (branch branches)
          (let* ((name (plist-get branch :name))
                 (message (plist-get branch :message))
                 (current (plist-get branch :current))
                 (face (if current 'madolt-branch-current 'madolt-branch-local))
                 (padded (truncate-string-to-width name col-width nil ?\s))
                 (upstream (madolt-refs--find-upstream
                            name remote-branches))
                 (ab (when upstream
                       (madolt-refs--ahead-behind name upstream)))
                 (upstream-info
                  (when upstream
                    (madolt-refs--format-upstream-info
                     upstream (car ab) (cdr ab)))))
            (magit-insert-section (branch name t)
              (magit-insert-heading
                (concat
                 (madolt-refs--format-focus-column current name)
                 (propertize padded 'font-lock-face face)
                 (when upstream-info
                   (concat " " upstream-info))
                 " " (or message "")
                 "\n"))
              (madolt-refs--maybe-format-margin
               (plist-get branch :hash))
              (madolt-refs--insert-cherry-commits name))))
        (insert "\n"))))))

(defun madolt-refs--insert-remote-branches ()
  "Insert a section listing remote branches.
Uses `madolt-refs--remote-branches' and `madolt-refs--remotes-alist'."
  (let ((branches madolt-refs--remote-branches)
        (remotes-alist madolt-refs--remotes-alist))
  (when branches
    ;; Group by remote
    (let ((by-remote (make-hash-table :test 'equal)))
      (dolist (branch branches)
        (let ((remote (plist-get branch :remote)))
          (push branch (gethash remote by-remote))))
      ;; Iterate in sorted order for deterministic output
      (dolist (remote (sort (hash-table-keys by-remote) #'string<))
        (let* ((rbranches (nreverse (gethash remote by-remote)))
               (url (cdr (assoc remote remotes-alist #'string=)))
               (col-width (madolt-refs--column-width
                           (mapcar (lambda (b)
                                     (let ((n (plist-get b :name)))
                                       (if madolt-refs-show-remote-prefix
                                           (format "%s/%s" remote n)
                                         n)))
                                   rbranches))))
          (magit-insert-section (remote remote t)
            (magit-insert-heading
              (if url
                  (format "Remote %s (%s)" remote url)
                (format "Remote %s" remote)))
            (dolist (branch rbranches)
              (let* ((name (plist-get branch :name))
                     (message (plist-get branch :message))
                     (full-name (format "%s/%s" remote name))
                     (display-name (if madolt-refs-show-remote-prefix
                                       full-name
                                     name))
                     (padded (truncate-string-to-width
                              display-name col-width nil ?\s)))
                (magit-insert-section (branch full-name)
                  (magit-insert-heading
                    (concat
                     "  "
                     (propertize padded
                                 'font-lock-face 'madolt-branch-remote)
                     " " (or message "")
                     "\n"))
                  (madolt-refs--maybe-format-margin
                   (plist-get branch :hash)))))
            (insert "\n"))))))))

(defun madolt-refs--insert-tags ()
  "Insert a section listing tags.
Uses `madolt-refs--tags'."
  (let ((tags madolt-refs--tags))
  (when tags
    (let ((col-width (madolt-refs--column-width
                      (mapcar (lambda (tg) (plist-get tg :name)) tags))))
      (magit-insert-section (tags nil t)
        (magit-insert-heading "Tags")
        (dolist (tag tags)
          (let* ((name (plist-get tag :name))
                 (message (plist-get tag :message))
                 (padded (truncate-string-to-width name col-width nil ?\s)))
            (magit-insert-section (tag name)
              (magit-insert-heading
                (concat
                 "  "
                 (propertize padded 'font-lock-face 'madolt-tag)
                 (when message (concat " " message))
                 "\n"))
              (madolt-refs--maybe-format-margin
               (plist-get tag :hash)))))
        (insert "\n"))))))

(provide 'madolt-refs)
;;; madolt-refs.el ends here
