;;; madolt-mode.el --- Major mode, buffer lifecycle, refresh  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

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

;; Major mode definition, buffer management, and refresh cycle for
;; madolt.  Derived from `magit-section-mode' for section navigation,
;; expand/collapse, visibility levels, and highlighting.
;;
;; Modeled on `magit-mode.el'.

;;; Code:

(require 'benchmark)
(require 'magit-section)
(require 'madolt-dolt)
(require 'madolt-process)

;; Forward declarations for commands defined in other madolt files.
;; These avoid byte-compiler warnings without circular requires.
(declare-function madolt-cherry-pick "madolt-cherry-pick" ())
(declare-function madolt-clean "madolt-apply" ())
(declare-function madolt-stage "madolt-apply" ())
(declare-function madolt-stage-all "madolt-apply" ())
(declare-function madolt-unstage "madolt-apply" ())
(declare-function madolt-unstage-all "madolt-apply" ())
(declare-function madolt-discard "madolt-apply" ())
(declare-function madolt-branch "madolt-branch" ())
(declare-function madolt-commit "madolt-commit" ())
(declare-function madolt-diff "madolt-diff" ())
(declare-function madolt-fetch "madolt-remote" ())
(declare-function madolt-log "madolt-log" ())
(declare-function madolt-log-refresh "madolt-log" ())
(declare-function madolt-merge "madolt-merge" ())
(declare-function madolt-rebase "madolt-rebase" ())
(declare-function madolt-reset "madolt-reset" ())
(declare-function madolt-remote-manage "madolt-remote" ())
(declare-function madolt-pull "madolt-remote" ())
(declare-function madolt-revert "madolt-cherry-pick" ())
(declare-function madolt-stash "madolt-stash" ())
(declare-function madolt-tag "madolt-tag" ())
(declare-function madolt-push "madolt-remote" ())
(declare-function madolt-blame "madolt-blame" (table))
(declare-function madolt-conflicts "madolt-conflicts" ())
(declare-function madolt-sql-query "madolt-sql" (query))
(declare-function madolt-diff-show-or-scroll-up "madolt-log" ())
(declare-function madolt-diff-show-or-scroll-down "madolt-log" ())
(declare-function madolt-show-refs "madolt-refs" ())
(declare-function madolt-dispatch "madolt" ())
(declare-function madolt-status-jump "madolt-status" ())
(declare-function madolt-visit-thing "madolt-status" ())

;;;; Refresh verbosity

(defcustom madolt-refresh-verbose nil
  "Whether to log timing information during buffer refresh.
When non-nil, each section inserter is benchmarked and the elapsed
time is logged to *Messages*, along with total refresh time and
subprocess cache hit/miss statistics.  Toggle interactively with
`madolt-toggle-verbose-refresh'."
  :group 'madolt
  :type 'boolean)

(defun madolt-toggle-verbose-refresh ()
  "Toggle verbose refresh timing.
When enabled, each buffer refresh logs per-section timing and
subprocess cache statistics to *Messages*."
  (interactive)
  (setq madolt-refresh-verbose (not madolt-refresh-verbose))
  (message "%s verbose refreshing"
           (if madolt-refresh-verbose "Enabled" "Disabled")))

(defun madolt-run-section-hook (hook)
  "Run HOOK, benchmarking each entry when `madolt-refresh-verbose' is set.
Each function on HOOK is called in order.  When verbose, elapsed
time per function is logged to *Messages* with markers for slow
sections (!! > 0.03s, ! > 0.01s)."
  (let ((entries (symbol-value hook)))
    (unless (listp entries)
      (setq entries (list entries)))
    (dolist (entry entries)
      (when (functionp entry)
        (if madolt-refresh-verbose
            (let ((time (benchmark-elapse (funcall entry))))
              (message "  %-50s %f %s" entry time
                       (cond ((> time 0.03) "!!")
                             ((> time 0.01) "!")
                             (t ""))))
          (funcall entry))))))

;;;; Major mode

(defvar-local madolt-buffer-database-dir nil
  "The Dolt database directory for the current buffer.")

(define-derived-mode madolt-mode magit-section-mode "Madolt"
  "Parent mode for all Madolt buffers.
Derived from `magit-section-mode', which provides section
navigation, expand/collapse, visibility levels, and highlighting."
  :group 'madolt
  (setq-local revert-buffer-function #'madolt-refresh-buffer))

;;;; Sub-modes

(define-derived-mode madolt-status-mode madolt-mode "Madolt Status"
  "Mode for madolt status buffers.")

(define-derived-mode madolt-diff-mode madolt-mode "Madolt Diff"
  "Mode for madolt diff buffers.")

(define-derived-mode madolt-log-mode madolt-mode "Madolt Log"
  "Mode for madolt log buffers.")

;;;; Show more (row-limit expansion)

(defun madolt-insert-show-more-button (shown total mode-map double-fn
                                            &optional indent)
  "Insert a \"show more\" button section when results are truncated.
SHOWN is the number of items currently displayed.
TOTAL is the total number available, or nil if unknown.
MODE-MAP is the keymap symbol (e.g. \\='madolt-mode-map) used to
resolve the keybinding in the button label.
DOUBLE-FN is the symbol of the function that doubles the limit
and refreshes.
INDENT is an optional string prefix to align the button with the
items above it."
  (let ((next (min (* shown 2) (or total (* shown 2)))))
    (magit-insert-section (longer)
      (when indent (insert indent))
      (insert-text-button
       (substitute-command-keys
        (format "Type \\<%s>\\[%s] to show more%s"
                mode-map 'madolt-show-more
                (if total
                    (format " (%d of %d shown; next: %d)" shown total next)
                  (format " (%d shown; next: %d)" shown next))))
       'action (lambda (_button)
                 (call-interactively double-fn))
       'follow-link t
       'mouse-face 'magit-section-highlight)
      (insert "\n"))))

(defun madolt--find-longer-section (&optional root)
  "Find the first `longer' section in ROOT's subtree.
ROOT defaults to `magit-root-section'."
  (let ((root (or root magit-root-section)))
    (when root
      (cl-labels ((walk (s)
                    (if (eq (oref s type) 'longer) s
                      (cl-some #'walk (oref s children)))))
        (walk root)))))

(defun madolt-show-more ()
  "Show more entries in the current section.
When point is on a \"show more\" button, activate it.
Otherwise search for a `longer' section in the current buffer
and activate that."
  (interactive)
  (let ((section (magit-current-section)))
    (if (and section (eq (oref section type) 'longer))
        ;; On a show-more button — push its text button
        (push-button)
      ;; Find the longer section and activate it
      (if-let ((longer (madolt--find-longer-section)))
          (progn
            (goto-char (oref longer start))
            (push-button))
        (user-error "Nothing to expand")))))

(defun madolt-maybe-show-more (section)
  "Auto-expand when cursor lands on a show-more button SECTION.
Intended for use on `magit-section-movement-hook'."
  (when (and (eq (oref section type) 'longer)
             (bound-and-true-p madolt-auto-show-more))
    (push-button)))

(defcustom madolt-auto-show-more nil
  "When non-nil, auto-expand when navigating to a show-more button.
When cursor lands on a \"Type + to show more\" section via
section movement commands, automatically load more entries
without requiring the user to press \"+\"."
  :group 'madolt
  :type 'boolean)

(add-hook 'magit-section-movement-hook #'madolt-maybe-show-more)

;;;; Copy section value

(defun madolt-copy-section-value ()
  "Copy the value of the section at point to the kill ring.
For table sections, copies the table name.  For commit sections,
copies the full commit hash."
  (interactive)
  (if-let ((section (magit-current-section))
           (value (oref section value)))
      (let ((text (format "%s" value)))
        (kill-new text)
        (message "Copied: %s" text))
    (user-error "No section value at point")))

;;;; Keymap

;; define-derived-mode creates madolt-mode-map with the parent mode's
;; keymap.  We populate it afterward so our bindings aren't lost.
(let ((map madolt-mode-map))
  ;; Buffer
  (keymap-set map "g"   #'madolt-refresh)
  (keymap-set map "j"   #'madolt-status-jump)
  (keymap-set map "q"   #'quit-window)
  (keymap-set map "$"   #'madolt-process-buffer)
  ;; Help
  (keymap-set map "?"   #'madolt-dispatch)
  (keymap-set map "h"   #'madolt-dispatch)
  ;; Apply (autoloaded from madolt-apply.el)
  (keymap-set map "s"   #'madolt-stage)
  (keymap-set map "S"   #'madolt-stage-all)
  (keymap-set map "u"   #'madolt-unstage)
  (keymap-set map "U"   #'madolt-unstage-all)
  (keymap-set map "k"   #'madolt-discard)
  (keymap-set map "x"   #'madolt-clean)
  ;; Cherry-pick (autoloaded from madolt-cherry-pick.el)
  (keymap-set map "A"   #'madolt-cherry-pick)
  ;; Branch (autoloaded from madolt-branch.el)
  (keymap-set map "b"   #'madolt-branch)
  ;; Commit (autoloaded from madolt-commit.el)
  (keymap-set map "c"   #'madolt-commit)
  ;; Diff (autoloaded from madolt-diff.el)
  (keymap-set map "d"   #'madolt-diff)
  ;; Fetch/Pull/Push/Remote (autoloaded from madolt-remote.el)
  (keymap-set map "f"   #'madolt-fetch)
  (keymap-set map "F"   #'madolt-pull)
  (keymap-set map "M"   #'madolt-remote-manage)
  (keymap-set map "P"   #'madolt-push)
  ;; Blame (autoloaded from madolt-blame.el)
  (keymap-set map "B"   #'madolt-blame)
  ;; Conflicts (autoloaded from madolt-conflicts.el)
  (keymap-set map "C"   #'madolt-conflicts)
  ;; Log (autoloaded from madolt-log.el)
  (keymap-set map "l"   #'madolt-log)
  (keymap-set map "L"   #'madolt-log-refresh)
  ;; SQL (autoloaded from madolt-sql.el)
  (keymap-set map "e"   #'madolt-sql-query)
  ;; Merge (autoloaded from madolt-merge.el)
  (keymap-set map "m"   #'madolt-merge)
  ;; Rebase (autoloaded from madolt-rebase.el)
  (keymap-set map "r"   #'madolt-rebase)
  ;; Reset (autoloaded from madolt-reset.el)
  (keymap-set map "X"   #'madolt-reset)
  ;; Revert (autoloaded from madolt-cherry-pick.el)
  (keymap-set map "V"   #'madolt-revert)
  ;; Tag (autoloaded from madolt-tag.el)
  (keymap-set map "t"   #'madolt-tag)
  ;; Stash (autoloaded from madolt-stash.el)
  (keymap-set map "z"   #'madolt-stash)
  ;; Refs (autoloaded from madolt-refs.el)
  (keymap-set map "y"   #'madolt-show-refs)
  ;; Copy
  (keymap-set map "w"   #'madolt-copy-section-value)
  ;; Show more
  (keymap-set map "+"   #'madolt-show-more)
  ;; Navigation
  (keymap-set map "RET" #'madolt-visit-thing)
  ;; Show commit / scroll (like magit SPC/DEL)
  (keymap-set map "SPC"   #'madolt-diff-show-or-scroll-up)
  (keymap-set map "S-SPC" #'madolt-diff-show-or-scroll-down)
  (keymap-set map "DEL"   #'madolt-diff-show-or-scroll-down))

;;;; Buffer lifecycle

(defun madolt-setup-buffer (mode &optional directory)
  "Set up a madolt buffer for MODE.
DIRECTORY is the Dolt database root directory.  If nil, it is
determined from `default-directory'.

Create or reuse a buffer for MODE, set `default-directory' to the
database root, activate MODE, and call `madolt-refresh'."
  (let* ((db-dir (or directory
                     (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (madolt--buffer-name mode db-dir))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p mode)
        (funcall mode))
      (setq default-directory db-dir)
      (setq madolt-buffer-database-dir db-dir)
      (madolt-refresh))
    (madolt-display-buffer buffer)
    buffer))

(defun madolt--buffer-name (mode directory)
  "Return the buffer name for MODE and DIRECTORY."
  (let ((db-name (file-name-nondirectory
                  (directory-file-name directory))))
    (format "madolt-%s: %s"
            (replace-regexp-in-string
             "^madolt-\\|-mode$" ""
             (symbol-name mode))
            db-name)))

(defun madolt-display-buffer (buffer)
  "Display BUFFER in a window and select it.
Delegates to `magit-display-buffer' when available, so that the
user's `magit-display-buffer-function' setting is respected.
Falls back to `display-buffer' otherwise."
  (if (fboundp 'magit-display-buffer)
      (magit-display-buffer buffer)
    (let ((window (display-buffer buffer)))
      (when window
        (select-window window)))))

;;;; Refresh

(defun madolt-refresh (&rest _args)
  "Refresh the current madolt buffer.
Erase the buffer, re-run the mode-specific refresh function, and
restore cursor position.  When `madolt-refresh-verbose' is non-nil,
log per-section timing and cache statistics to *Messages*."
  (interactive)
  (when (derived-mode-p 'madolt-mode)
    (let* ((start (current-time))
           (madolt--refresh-cache (or madolt--refresh-cache
                                      (list (cons 0 0))))
           (refresh-fn (madolt--refresh-function))
           (section (magit-current-section))
           (rel-pos (and section
                         (magit-section-get-relative-position section))))
      (when madolt-refresh-verbose
        (message "Refreshing buffer `%s'..." (buffer-name)))
      (when refresh-fn
        ;; Set up SQL connection before erasing the buffer so that
        ;; any prompt (y-or-n-p) appears while the old content is
        ;; still visible.
        (when (fboundp 'madolt-connection-setup)
          (madolt-connection-setup))
        ;; Reset magit-section highlight state before erasing the
        ;; buffer.  Without this, stale section objects from the
        ;; previous render cause wrong-type-argument errors in
        ;; magit-section-post-command-hook.  Mirrors what
        ;; magit-refresh-buffer does in magit-mode.el.
        (deactivate-mark)
        (setq magit-section-pre-command-section nil)
        (setq magit-section-highlight-overlays nil)
        (setq magit-section-selection-overlays nil)
        (setq magit-section-highlighted-sections nil)
        (setq magit-section-focused-sections nil)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (save-excursion
            (funcall refresh-fn)))
        ;; Restore position: delegate to magit-section-goto-successor
        ;; which tries --same (find identical section) then --related
        ;; (opposite section, sibling, or parent).
        (unless (and section rel-pos
                     (apply #'magit-section-goto-successor
                            section rel-pos))
          (goto-char (point-min)))
        ;; Apply section visibility: show/hide overlays based on
        ;; the `hidden' slot (which was set from the visibility
        ;; cache during section creation).  Bind
        ;; `magit-section-cache-visibility' to nil so this pass
        ;; doesn't overwrite the cache.  This mirrors what
        ;; `magit-refresh-buffer' does in magit-mode.el.
        (when magit-root-section
          (let ((magit-section-cache-visibility nil))
            (magit-section-show magit-root-section)))
        ;; Update highlighting on the freshly built sections, then
        ;; mark this buffer as refreshed so
        ;; magit-section-post-command-hook skips its redundant
        ;; highlight pass (which would operate on stale state).
        ;; Guard on magit-root-section being set, which won't be
        ;; the case if the refresh function errored before
        ;; magit-insert-section could complete.
        (when magit-root-section
          (magit-section-update-highlight))
        (set-buffer-modified-p nil)
        (push (current-buffer) magit-section--refreshed-buffers)
        (when madolt-refresh-verbose
          (let* ((c (caar madolt--refresh-cache))
                 (a (+ c (cdar madolt--refresh-cache))))
            (message "Refreshing buffer `%s'...done (%.3fs, cached %s/%s (%.0f%%))"
                     (buffer-name)
                     (float-time (time-since start))
                     c a
                     (if (> a 0)
                         (* (/ c (* a 1.0)) 100)
                       0))))))))

(defun madolt-refresh-buffer (&rest _args)
  "Revert buffer function for madolt buffers.
Used as `revert-buffer-function'."
  (madolt-refresh))

(defun madolt--refresh-function ()
  "Return the refresh function for the current mode.
Convention: for `madolt-foo-mode', the refresh function is
`madolt-foo-refresh-buffer'."
  (let* ((mode-name (symbol-name major-mode))
         (fn-name (concat (substring mode-name 0 (- (length mode-name) 5))
                          "-refresh-buffer"))
         (fn (intern fn-name)))
    (and (functionp fn) fn)))

;;;; Section toggle caching

(defun madolt--section-toggle-with-cache (orig-fn &rest args)
  "Activate `madolt--refresh-cache' around ORIG-FN for madolt buffers.
ARGS are passed to ORIG-FN.
When expanding a section (e.g. Tab on a commit or table diff),
the washer may make multiple dolt CLI calls for the same data.
Without a cache each call costs ~170ms of process startup.  This
advice ensures duplicate queries within a single toggle are
served from cache."
  (if (and (derived-mode-p 'madolt-mode)
           (not madolt--refresh-cache))
      (let ((madolt--refresh-cache (list (cons 0 0))))
        (apply orig-fn args))
    (apply orig-fn args)))

(advice-add 'magit-section-toggle :around
            #'madolt--section-toggle-with-cache)

(provide 'madolt-mode)
;;; madolt-mode.el ends here
