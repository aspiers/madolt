;;; madolt-process.el --- Process execution and logging  -*- lexical-binding:t -*-

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

;; Process execution and logging for madolt.  Provides the bridge
;; between raw dolt CLI calls (`madolt-dolt') and the UI layer.
;; Every command invocation is logged to a process buffer as a
;; collapsible `magit-section' entry.
;;
;; Synchronous only for MVP.  Modeled on `magit-process.el'.

;;; Code:

(require 'magit-section)
(require 'madolt-dolt)

;; Forward declarations for functions defined in madolt-mode.el.
;; Avoids circular require since madolt-mode depends on madolt-process.
(declare-function madolt-refresh "madolt-mode" ())
(declare-function madolt-display-buffer "madolt-mode" (buffer))

;;;; Faces

(defface madolt-process-ok
  '((t :inherit magit-section-heading :foreground "green"))
  "Face for zero exit codes in the process buffer."
  :group 'madolt-faces)

(defface madolt-process-ng
  '((t :inherit magit-section-heading :foreground "red"))
  "Face for non-zero exit codes in the process buffer."
  :group 'madolt-faces)

(defface madolt-process-heading
  '((t :inherit magit-section-heading))
  "Face for command strings in the process buffer."
  :group 'madolt-faces)

;;;; Process buffer

(defvar-local madolt-process--root-section nil
  "The root section of the current process buffer.")

(define-derived-mode madolt-process-mode magit-section-mode "Madolt Process"
  "Mode for madolt process log buffers."
  :group 'madolt
  (setq-local revert-buffer-function #'ignore)
  (setq-local magit-section-initial-visibility-alist
              '((process . hide))))

(defun madolt--process-buffer-name (&optional directory)
  "Return the process buffer name for DIRECTORY's dolt database."
  (let ((db-dir (madolt-database-dir directory)))
    (format "*madolt-process: %s*"
            (if db-dir
                (file-name-nondirectory
                 (directory-file-name db-dir))
              "unknown"))))

(defun madolt-process-buffer (&optional nodisplay)
  "Return the process buffer for the current dolt database.
Create it if it doesn't exist.  Unless NODISPLAY is non-nil,
also display the buffer, select its window, and move point to
the last process section heading."
  (interactive)
  (let* ((db-dir (or (madolt-database-dir)
                     default-directory))
         (buf-name (madolt--process-buffer-name))
         (buffer (or (get-buffer buf-name)
                     (let ((buf (generate-new-buffer buf-name)))
                       (with-current-buffer buf
                         (madolt-process-mode)
                         (setq default-directory db-dir)
                         (let ((inhibit-read-only t))
                           (magit-insert-section (processbuf)
                             (insert "\n"))
                           (setq madolt-process--root-section
                                 magit-root-section)))
                       buf))))
    (unless nodisplay
      (pop-to-buffer buffer)
      (madolt--process-goto-last))
    buffer))

(defun madolt--process-goto-last ()
  "Move point to the heading of the last process section.
Does nothing if no process sections exist."
  (when-let ((root (or madolt-process--root-section magit-root-section)))
    (let ((last-section nil))
      (dolist (child (oref root children))
        (when (eq (oref child type) 'process)
          (setq last-section child)))
      (when last-section
        (goto-char (oref last-section start))))))

;;;; Section insertion

(defun madolt--process-insert-section (args exit-code output)
  "Insert a process section into the process buffer.
ARGS is the list of dolt arguments that were run.
EXIT-CODE is the integer exit code.
OUTPUT is the string output from the command.
Layout matches magit-process: right-justified 3-char exit code,
space, then the command string."
  (let ((buf (madolt-process-buffer t)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (magit-insert-section--parent
               (or madolt-process--root-section magit-root-section)))
          (goto-char (1- (point-max)))
          (let* ((has-output (not (string-empty-p output)))
                 (section
                  (magit-insert-section (process)
                    (insert (propertize (format "%3s " exit-code)
                                        'font-lock-face
                                        (if (zerop exit-code)
                                            'madolt-process-ok
                                          'madolt-process-ng)))
                    (magit-insert-heading
                      (propertize
                       (concat (file-name-nondirectory madolt-dolt-executable)
                               " "
                               (mapconcat #'shell-quote-argument args " "))
                       'font-lock-face 'madolt-process-heading))
                    (when has-output
                      (magit-insert-section-body
                        (insert output)
                        (unless (string-suffix-p "\n" output)
                          (insert "\n"))
                        (insert "\n"))))))
            ;; Collapse all previously visible sections so only
            ;; the newest command is expanded.
            (when-let ((root (or madolt-process--root-section
                                 magit-root-section)))
              (dolist (child (oref root children))
                (when (and (eq (oref child type) 'process)
                           (not (eq child section)))
                  (magit-section-hide child))))
            (when has-output
              (magit-section-show section))))))))

;;;; Core execution functions

(defun madolt-call-dolt (&rest args)
  "Run dolt synchronously with ARGS, logging to the process buffer.
Return a cons cell (EXIT-CODE . OUTPUT-STRING)."
  (let* ((flat-args (madolt--flatten-args args))
         (result (apply #'madolt--run flat-args)))
    (madolt--process-insert-section flat-args (car result) (cdr result))
    result))

(defun madolt-run-dolt (&rest args)
  "Run dolt synchronously with ARGS, log to process buffer, and refresh.
Like `madolt-call-dolt' but also calls `madolt-refresh' afterward.
Return the exit code."
  (let ((result (apply #'madolt-call-dolt args)))
    (madolt-refresh)
    (car result)))

(provide 'madolt-process)
;;; madolt-process.el ends here
