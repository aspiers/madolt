;;; madolt-stash-tests.el --- Tests for madolt-stash.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt stash transient and commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-stash)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-stash-is-transient ()
  "madolt-stash should be a transient prefix."
  (should (get 'madolt-stash 'transient--layout)))

(ert-deftest test-madolt-stash-has-create-suffix ()
  "madolt-stash should have a 'z' suffix for stash create."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-stash)))
    (should (assoc "z" suffixes))
    (should (eq (cdr (assoc "z" suffixes))
                'madolt-stash-create-command))))

(ert-deftest test-madolt-stash-has-pop-suffix ()
  "madolt-stash should have a 'p' suffix for pop."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-stash)))
    (should (assoc "p" suffixes))
    (should (eq (cdr (assoc "p" suffixes))
                'madolt-stash-pop-command))))

(ert-deftest test-madolt-stash-has-drop-suffix ()
  "madolt-stash should have a 'k' suffix for drop."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-stash)))
    (should (assoc "k" suffixes))
    (should (eq (cdr (assoc "k" suffixes))
                'madolt-stash-drop-command))))

(ert-deftest test-madolt-stash-has-clear-suffix ()
  "madolt-stash should have an 'x' suffix for clear."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-stash)))
    (should (assoc "x" suffixes))
    (should (eq (cdr (assoc "x" suffixes))
                'madolt-stash-clear-command))))

(ert-deftest test-madolt-stash-has-list-suffix ()
  "madolt-stash should have an 'l' suffix for list."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-stash)))
    (should (assoc "l" suffixes))
    (should (eq (cdr (assoc "l" suffixes))
                'madolt-stash-list-command))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-stash ()
  "The dispatch menu has a \"z\" binding for stash."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "z" suffixes))
    (should (eq (cdr (assoc "z" suffixes)) 'madolt-stash))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-stash ()
  "The mode map should bind 'z' to madolt-stash."
  (should (eq (keymap-lookup madolt-mode-map "z") #'madolt-stash)))

;;;; Stash create — calls dolt correctly

(ert-deftest test-madolt-stash-create-calls-dolt ()
  "madolt-stash-create-command should invoke dolt stash."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-stash-create-command nil)
        (should (equal called-args '("stash")))))))

(ert-deftest test-madolt-stash-create-with-untracked ()
  "madolt-stash-create-command with --include-untracked should pass flag."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-stash-create-command '("--include-untracked"))
        (should (equal called-args '("stash" "--include-untracked")))))))

;;;; Stash pop — calls dolt correctly

(ert-deftest test-madolt-stash-pop-calls-dolt ()
  "madolt-stash-pop-command should invoke dolt stash pop."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-stash-pop-command "0")
        (should (equal called-args '("stash" "pop" "0")))))))

;;;; Stash drop — calls dolt correctly

(ert-deftest test-madolt-stash-drop-calls-dolt ()
  "madolt-stash-drop-command should invoke dolt stash drop with confirmation."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (madolt-stash-drop-command "0")
        (should (equal called-args '("stash" "drop" "0")))))))

(ert-deftest test-madolt-stash-drop-aborts-on-deny ()
  "madolt-stash-drop-command should not drop when user declines."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (madolt-stash-drop-command "0")
        (should (null called-args))))))

;;;; Stash clear — calls dolt correctly

(ert-deftest test-madolt-stash-clear-calls-dolt ()
  "madolt-stash-clear-command should invoke dolt stash clear."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (madolt-stash-clear-command)
        (should (equal called-args '("stash" "clear")))))))

;;;; Stash list — no stashes

(ert-deftest test-madolt-stash-list-no-stashes ()
  "madolt-stash-list-command with no stashes should say so."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let (msg)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (madolt-stash-list-command))
      (should (string= msg "No stashes")))))

;;;; Integration: stash create and pop

(ert-deftest test-madolt-stash-create-and-pop ()
  "Creating and popping a stash should save and restore changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'original')")
    (madolt-test-commit "init")
    ;; Make a change
    (madolt-test-insert-row "t1" "(2, 'new-row')")
    ;; Stash the change
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-stash-create-command nil))
    ;; Working tree should be clean — row 2 gone
    (let ((status (madolt-status-tables)))
      (should (null (cdr (assq 'unstaged status)))))
    ;; Pop the stash
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-stash-pop-command "0"))
    ;; Row 2 should be back
    (let ((status (madolt-status-tables)))
      (should (cdr (assq 'unstaged status))))))

;;;; Integration: stash list with stashes

(ert-deftest test-madolt-stash-list-with-stashes ()
  "madolt-stash-list-command should show stash entries."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'original')")
    (madolt-test-commit "init")
    (madolt-test-insert-row "t1" "(2, 'stashed')")
    (madolt--run "stash")
    (let (msg)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (madolt-stash-list-command))
      (should (stringp msg))
      (should-not (string= msg "No stashes")))))

(provide 'madolt-stash-tests)
;;; madolt-stash-tests.el ends here
