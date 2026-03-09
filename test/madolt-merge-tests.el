;;; madolt-merge-tests.el --- Tests for madolt-merge.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt merge transient and merge commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-merge)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-merge-is-transient ()
  "madolt-merge should be a transient prefix."
  (should (get 'madolt-merge 'transient--layout)))

(ert-deftest test-madolt-merge-has-merge-suffix ()
  "madolt-merge should have an 'm' suffix for merge."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-merge)))
    (should (assoc "m" suffixes))
    (should (eq (cdr (assoc "m" suffixes))
                'madolt-merge-command))))

(ert-deftest test-madolt-merge-has-abort-suffix ()
  "madolt-merge should have an 'a' suffix for abort."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-merge)))
    (should (assoc "a" suffixes))
    (should (eq (cdr (assoc "a" suffixes))
                'madolt-merge-abort-command))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-merge ()
  "The dispatch menu has an \"m\" binding for merge."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "m" suffixes))
    (should (eq (cdr (assoc "m" suffixes)) 'madolt-merge))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-merge ()
  "The mode map should bind 'm' to madolt-merge."
  (should (eq (keymap-lookup madolt-mode-map "m") #'madolt-merge)))

;;;; Merge command — fast-forward merge

(ert-deftest test-madolt-merge-fast-forward ()
  "Merging a branch that is ahead should fast-forward."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Create a feature branch with an extra commit
    (madolt-branch-checkout-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "add t2")
    ;; Switch back to main and merge feature
    (madolt-branch-checkout "main")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'read-string) (lambda (&rest _) "")))
      (madolt-merge-command "feature" nil))
    ;; t2 should now exist on main
    (should (madolt-dolt-success-p "sql" "-q" "SELECT 1 FROM t2 LIMIT 1"))))

;;;; Merge command — with message

(ert-deftest test-madolt-merge-with-message ()
  "Merging with --no-ff and a message should create a merge commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Create a feature branch with an extra commit
    (madolt-branch-checkout-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "add t2")
    ;; Switch back to main and merge with --no-ff and a custom message
    (madolt-branch-checkout "main")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'read-string)
               (lambda (&rest _) "Custom merge message")))
      (madolt-merge-command "feature" '("--no-ff")))
    ;; t2 should exist
    (should (madolt-dolt-success-p "sql" "-q" "SELECT 1 FROM t2 LIMIT 1"))
    ;; The latest commit message should be our custom message
    (let ((entries (madolt-log-entries 1)))
      (should (string= (plist-get (car entries) :message)
                        "Custom merge message")))))

;;;; Merge command — squash does not prompt for message

(ert-deftest test-madolt-merge-squash-no-message-prompt ()
  "Merging with --squash should not prompt for a merge message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-checkout-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "add t2")
    (madolt-branch-checkout "main")
    (let ((read-string-called nil))
      (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'read-string)
                 (lambda (&rest _)
                   (setq read-string-called t) "")))
        (madolt-merge-command "feature" '("--squash")))
      (should-not read-string-called))))

;;;; Merge command — no-commit does not prompt for message

(ert-deftest test-madolt-merge-no-commit-no-message-prompt ()
  "Merging with --no-commit should not prompt for a merge message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-checkout-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "add t2")
    (madolt-branch-checkout "main")
    (let ((read-string-called nil))
      (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'read-string)
                 (lambda (&rest _)
                   (setq read-string-called t) "")))
        (madolt-merge-command "feature" '("--no-commit")))
      (should-not read-string-called))))

;;;; Merge command — calls dolt with correct args

(ert-deftest test-madolt-merge-command-calls-dolt ()
  "madolt-merge-command should invoke dolt merge with correct args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'read-string)
                 (lambda (&rest _) "my merge")))
        (madolt-merge-command "feature" '("--no-ff"))
        (should (equal called-args
                       '("merge" "--no-ff" "-m" "my merge" "feature")))))))

;;;; Merge command — empty message omits -m flag

(ert-deftest test-madolt-merge-command-empty-message ()
  "Empty merge message should omit the -m flag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'read-string)
                 (lambda (&rest _) "")))
        (madolt-merge-command "feature" nil)
        (should (equal called-args '("merge" "feature")))))))

;;;; Abort command

(ert-deftest test-madolt-merge-abort-calls-dolt ()
  "madolt-merge-abort-command should invoke dolt merge --abort."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-merge-abort-command)
        (should (equal called-args '("merge" "--abort")))))))

;;;; Merge conflict scenario

(ert-deftest test-madolt-merge-conflict-reports-failure ()
  "Merging conflicting branches should report failure."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(100)")
    (madolt-test-insert-row "t1" "(1, 'original')")
    (madolt-test-commit "init")
    ;; Create divergent branches
    (madolt-branch-checkout-create "feature")
    (madolt-test-update-row "t1" "val = 'feature-change'" "id = 1")
    (madolt-test-commit "feature change")
    (madolt-branch-checkout "main")
    (madolt-test-update-row "t1" "val = 'main-change'" "id = 1")
    (madolt-test-commit "main change")
    ;; Attempt merge — should fail with conflict
    (let ((messages nil))
      (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'read-string) (lambda (&rest _) ""))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (madolt-merge-command "feature" nil))
      ;; Should have reported failure
      (should (cl-some (lambda (msg) (string-match-p "\\(conflict\\|failed\\)" msg))
                       messages)))))

;;;; Merge with --ff-only flag

(ert-deftest test-madolt-merge-ff-only-calls-dolt ()
  "madolt-merge-command with --ff-only should pass the flag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'read-string) (lambda (&rest _) "")))
        (madolt-merge-command "feature" '("--ff-only"))
        (should (equal called-args '("merge" "--ff-only" "feature")))))))

(provide 'madolt-merge-tests)
;;; madolt-merge-tests.el ends here
