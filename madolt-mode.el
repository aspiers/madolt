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

(require 'magit-section)
(require 'madolt-dolt)
(require 'madolt-process)

;; Forward declarations for commands defined in other madolt files.
;; These avoid byte-compiler warnings without circular requires.
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
(declare-function madolt-pull "madolt-remote" ())
(declare-function madolt-push "madolt-remote" ())
(declare-function madolt-dispatch "madolt" ())
(declare-function madolt-visit-thing "madolt-status" ())

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

;;;; Keymap

;; define-derived-mode creates madolt-mode-map with the parent mode's
;; keymap.  We populate it afterward so our bindings aren't lost.
(let ((map madolt-mode-map))
  ;; Buffer
  (keymap-set map "g"   #'madolt-refresh)
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
  ;; Branch (autoloaded from madolt-branch.el)
  (keymap-set map "b"   #'madolt-branch)
  ;; Commit (autoloaded from madolt-commit.el)
  (keymap-set map "c"   #'madolt-commit)
  ;; Diff (autoloaded from madolt-diff.el)
  (keymap-set map "d"   #'madolt-diff)
  ;; Fetch/Pull/Push (autoloaded from madolt-remote.el)
  (keymap-set map "f"   #'madolt-fetch)
  (keymap-set map "F"   #'madolt-pull)
  (keymap-set map "P"   #'madolt-push)
  ;; Log (autoloaded from madolt-log.el)
  (keymap-set map "l"   #'madolt-log)
  ;; Navigation
  (keymap-set map "RET" #'madolt-visit-thing))

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
    (format "*madolt-%s: %s*"
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
restore cursor position."
  (interactive)
  (when (derived-mode-p 'madolt-mode)
    (let* ((refresh-fn (madolt--refresh-function))
           (section (magit-current-section))
           (section-ident (and section (magit-section-ident section)))
           (rel-pos (and section
                         (magit-section-get-relative-position section))))
      (when refresh-fn
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
        ;; Restore position
        (when section-ident
          (if-let ((target (magit-get-section section-ident)))
              (progn
                (goto-char (oref target start))
                (when rel-pos
                  (apply #'magit-section-goto-successor
                         section rel-pos)))
            ;; Section not found; go to beginning
            (goto-char (point-min))))
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
        (push (current-buffer) magit-section--refreshed-buffers)))))

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

(provide 'madolt-mode)
;;; madolt-mode.el ends here
