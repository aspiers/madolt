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
              (should (string-match-p "madolt-status:" (buffer-name buf)))
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

(ert-deftest test-madolt-status-prompts-outside-dolt ()
  "madolt-status prompts for a directory when invoked interactively outside a dolt DB."
  (madolt-with-test-database
    (let ((db-dir default-directory))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (root) (insert "status\n"))))
                ((symbol-function 'read-directory-name)
                 (lambda (_prompt &rest _) db-dir)))
        ;; Simulate interactive call from outside a dolt DB
        (let ((default-directory temporary-file-directory))
          (let ((buf (call-interactively #'madolt-status)))
            (unwind-protect
                (with-current-buffer buf
                  (should (equal default-directory db-dir)))
              (kill-buffer buf))))))))

(ert-deftest test-madolt-status-no-prompt-inside-dolt ()
  "madolt-status does not prompt when invoked interactively inside a dolt DB."
  (madolt-with-test-database
    (let ((prompted nil))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (root) (insert "status\n"))))
                ((symbol-function 'read-directory-name)
                 (lambda (_prompt &rest _)
                   (setq prompted t)
                   default-directory)))
        (let ((buf (call-interactively #'madolt-status)))
          (unwind-protect
              (should-not prompted)
            (kill-buffer buf)))))))

;;;; Dispatch

(ert-deftest test-madolt-dispatch-is-transient ()
  "madolt-dispatch is a transient prefix command."
  (should (get 'madolt-dispatch 'transient--prefix)))

(ert-deftest test-madolt-dispatch-has-jump ()
  "The dispatch menu has a \"j\" binding for jump."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "j" suffixes))
    (should (eq (cdr (assoc "j" suffixes)) 'madolt-status-jump))))

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

(ert-deftest test-madolt-dispatch-has-log-refresh ()
  "The dispatch menu has an \"L\" binding for log refresh."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "L" suffixes))
    (should (eq (cdr (assoc "L" suffixes)) 'madolt-log-refresh))))

(ert-deftest test-madolt-dispatch-has-commit ()
  "The dispatch menu has a \"c\" binding for commit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "c" suffixes))
    (should (eq (cdr (assoc "c" suffixes)) 'madolt-commit))))

;;;; Dispatch -- applying changes group

(ert-deftest test-madolt-dispatch-has-stage ()
  "The dispatch menu has an \"s\" binding for stage."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "s" suffixes))
    (should (eq (cdr (assoc "s" suffixes)) 'madolt-stage))))

(ert-deftest test-madolt-dispatch-has-unstage ()
  "The dispatch menu has a \"u\" binding for unstage."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "u" suffixes))
    (should (eq (cdr (assoc "u" suffixes)) 'madolt-unstage))))

(ert-deftest test-madolt-dispatch-has-discard ()
  "The dispatch menu has a \"k\" binding for discard."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "k" suffixes))
    (should (eq (cdr (assoc "k" suffixes)) 'madolt-discard))))

(ert-deftest test-madolt-dispatch-has-stage-all ()
  "The dispatch menu has an \"S\" binding for stage all."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "S" suffixes))
    (should (eq (cdr (assoc "S" suffixes)) 'madolt-stage-all))))

(ert-deftest test-madolt-dispatch-has-unstage-all ()
  "The dispatch menu has a \"U\" binding for unstage all."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "U" suffixes))
    (should (eq (cdr (assoc "U" suffixes)) 'madolt-unstage-all))))

;;;; Dispatch -- essential commands group

(ert-deftest test-madolt-dispatch-has-refresh ()
  "The dispatch menu has a \"g\" binding for refresh."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "g" suffixes))
    (should (eq (cdr (assoc "g" suffixes)) 'madolt-refresh))))

(ert-deftest test-madolt-dispatch-has-quit ()
  "The dispatch menu has a \"q\" binding for quit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "q" suffixes))
    (should (eq (cdr (assoc "q" suffixes)) 'quit-window))))

(ert-deftest test-madolt-dispatch-has-toggle ()
  "The dispatch menu has a TAB binding for section toggle."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "<tab>" suffixes))
    (should (eq (cdr (assoc "<tab>" suffixes)) 'magit-section-toggle))))

(ert-deftest test-madolt-dispatch-has-visit ()
  "The dispatch menu has a RET binding for visit thing."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "<return>" suffixes))
    (should (eq (cdr (assoc "<return>" suffixes)) 'madolt-visit-thing))))

(provide 'madolt-tests)
;;; madolt-tests.el ends here
