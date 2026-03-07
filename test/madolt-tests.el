;;; madolt-tests.el --- Tests for madolt.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the entry point, customization groups, and dispatch.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt-test-helpers)
(require 'madolt)

;;;; Helper to find transient suffixes

(defun madolt-test--transient-suffix-keys (prefix-sym)
  "Return an alist of (KEY . COMMAND) for transient PREFIX-SYM."
  (let ((layout (get prefix-sym 'transient--layout))
        result)
    (when (and layout (>= (length layout) 3))
      ;; layout is a vector [VERSION SPEC GROUPS] where GROUPS is a
      ;; list of vectors, each [CLASS PLIST SUFFIXES].
      (dolist (group (aref layout 2))
        (when (vectorp group)
          (let ((suffixes (aref group 2)))
            (dolist (suffix suffixes)
              (when (and (listp suffix) (plist-get (cdr suffix) :key))
                (push (cons (plist-get (cdr suffix) :key)
                            (plist-get (cdr suffix) :command))
                      result)))))))
    (nreverse result)))

;;;; Customization group

(ert-deftest test-madolt-group-exists ()
  "The `madolt' customization group exists."
  (should (get 'madolt 'custom-group)))

(ert-deftest test-madolt-group-parent ()
  "The `madolt' customization group is under `tools'."
  (let ((parents (mapcar #'car (get 'madolt 'custom-group))))
    ;; custom-group stores children, so check from the parent side:
    ;; the `tools' group should have `madolt' as a member.
    (should (assq 'madolt (get 'tools 'custom-group)))))

;;;; Entry point

(ert-deftest test-madolt-status-opens-buffer ()
  "madolt-status opens a status buffer in a dolt database."
  (madolt-with-test-database
    (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
               (lambda () (magit-insert-section (root) (insert "status\n")))))
      (let ((buf (madolt-status)))
        (unwind-protect
            (progn
              (should (bufferp buf))
              (should (string-match-p "\\*madolt-status:" (buffer-name buf)))
              (with-current-buffer buf
                (should (derived-mode-p 'madolt-status-mode))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-status-errors-outside-dolt ()
  "madolt-status signals an error outside a dolt database."
  (let ((default-directory temporary-file-directory))
    (should-error (madolt-status) :type 'user-error)))

(ert-deftest test-madolt-status-with-directory-arg ()
  "madolt-status accepts an explicit directory argument."
  (madolt-with-test-database
    (let ((db-dir default-directory))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (root) (insert "status\n")))))
        ;; Call from a non-dolt directory with explicit arg
        (let ((default-directory temporary-file-directory))
          (let ((buf (madolt-status db-dir)))
            (unwind-protect
                (with-current-buffer buf
                  (should (equal default-directory db-dir)))
              (kill-buffer buf))))))))

(ert-deftest test-madolt-status-interactive ()
  "madolt-status is an interactive command."
  (should (commandp 'madolt-status)))

;;;; Dispatch

(ert-deftest test-madolt-dispatch-is-transient ()
  "madolt-dispatch is a transient prefix command."
  (should (get 'madolt-dispatch 'transient--prefix)))

(ert-deftest test-madolt-dispatch-has-status ()
  "The dispatch menu has an \"s\" binding for status."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "s" suffixes))
    (should (eq (cdr (assoc "s" suffixes)) 'madolt-status))))

(ert-deftest test-madolt-dispatch-has-diff ()
  "The dispatch menu has a \"d\" binding for diff."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "d" suffixes))
    (should (eq (cdr (assoc "d" suffixes)) 'madolt-diff))))

(ert-deftest test-madolt-dispatch-has-log ()
  "The dispatch menu has an \"l\" binding for log."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "l" suffixes))
    (should (eq (cdr (assoc "l" suffixes)) 'madolt-log))))

(ert-deftest test-madolt-dispatch-has-commit ()
  "The dispatch menu has a \"c\" binding for commit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "c" suffixes))
    (should (eq (cdr (assoc "c" suffixes)) 'madolt-commit))))

(provide 'madolt-tests)
;;; madolt-tests.el ends here
