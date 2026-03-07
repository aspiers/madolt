;;; madolt-commit-tests.el --- Tests for madolt-commit.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt commit transient and commit commands.

;;; Code:

(require 'ert)
(require 'ring)
(require 'madolt-commit)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-commit-is-transient ()
  "madolt-commit should be a transient prefix."
  (should (get 'madolt-commit 'transient--layout)))

(ert-deftest test-madolt-commit-has-create-suffix ()
  "madolt-commit should have a 'c' suffix for commit create."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "c" all-keys))))

(ert-deftest test-madolt-commit-has-amend-suffix ()
  "madolt-commit should have an 'a' suffix for amend."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "a" all-keys))))

(ert-deftest test-madolt-commit-has-message-suffix ()
  "madolt-commit should have an 'm' suffix for message."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "m" all-keys))))

(ert-deftest test-madolt-commit-arguments ()
  "madolt-commit should have all documented argument switches."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-args nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((arg (plist-get (cdr suffix) :argument)))
            (when arg (push arg all-args))))))
    (dolist (arg '("--all" "--ALL" "--allow-empty" "--force"
                   "--date=" "--author="))
      (should (member arg all-args)))))

;;;; Commit assertion

(ert-deftest test-madolt-commit-assert-with-staged-passes ()
  "Commit assert should pass when there are staged changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Make a change and stage it
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-stage-all)
    ;; Should return (t . ARGS) since there are staged changes
    (let ((result (madolt-commit-assert nil)))
      (should result)
      (should (eq (car result) t)))))

(ert-deftest test-madolt-commit-assert-all-flag-passes ()
  "Commit assert should pass when --all is in args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    ;; Not staged, but --all is present
    (let ((result (madolt-commit-assert '("--all"))))
      (should result)
      (should (eq (car result) t))
      (should (member "--all" (cdr result))))))

(ert-deftest test-madolt-commit-assert-nothing-staged-aborts ()
  "Commit assert should return nil when nothing staged and user says no."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    ;; No changes at all — nothing to stage either
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (let ((result (madolt-commit-assert nil)))
        (should (null result))))))

(ert-deftest test-madolt-commit-assert-offers-stage-all ()
  "Commit assert should add --all when nothing staged and user says yes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    (madolt-test-update-row "t1" "id = 2" "id = 1")
    ;; Unstaged changes, nothing staged, user says yes
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (let ((result (madolt-commit-assert nil)))
        (should result)
        (should (eq (car result) t))
        (should (member "--all" (cdr result)))))))

;;;; Quick commit (madolt-commit--do-commit)

(ert-deftest test-madolt-commit-do-commit-creates-commit ()
  "madolt-commit--do-commit should create an actual dolt commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (madolt-commit--do-commit "Test commit message" nil)
    ;; Verify the commit exists in the log
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Test commit message")))))

(ert-deftest test-madolt-commit-do-commit-with-all-flag ()
  "madolt-commit--do-commit with --all should stage and commit modified tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Modify the table (not staged)
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    ;; --all stages modified tables automatically
    (madolt-commit--do-commit "Commit with --all" '("--all"))
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Commit with --all")))))

(ert-deftest test-madolt-commit-do-commit-amend ()
  "madolt-commit--do-commit with --amend should change the last commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Original message")
    ;; Amend the commit
    (madolt-commit--do-commit "Amended message" '("--amend"))
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Amended message")))))

;;;; Message ring

(ert-deftest test-madolt-commit-message-ring-saves ()
  "Committing should save the message to the ring."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    ;; Clear the ring first
    (setq madolt-commit--message-ring (make-ring 32))
    (madolt-commit--do-commit "Ring test message" nil)
    (should (not (ring-empty-p madolt-commit--message-ring)))
    (should (equal (ring-ref madolt-commit--message-ring 0)
                   "Ring test message"))))

(ert-deftest test-madolt-commit-message-ring-multiple ()
  "Multiple commits should accumulate in the ring."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-stage-all)
    (setq madolt-commit--message-ring (make-ring 32))
    (madolt-commit--do-commit "First" nil)
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-stage-all)
    (madolt-commit--do-commit "Second" nil)
    (should (= (ring-length madolt-commit--message-ring) 2))
    ;; Most recent first
    (should (equal (ring-ref madolt-commit--message-ring 0) "Second"))
    (should (equal (ring-ref madolt-commit--message-ring 1) "First"))))

;;;; Integration: commit-create with simulated minibuffer

(ert-deftest test-madolt-commit-create-with-staged ()
  "madolt-commit-create should commit when staged changes exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Make change, stage, then commit via the create command
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-stage-all)
    ;; Simulate minibuffer input
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (_prompt &optional _initial &rest _)
                 "Automated test commit")))
      (madolt-commit-create nil))
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Automated test commit")))))

(ert-deftest test-madolt-commit-create-nothing-staged-abort ()
  "madolt-commit-create should abort when user declines staging."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    (let ((count-before (length (madolt-log-entries 10))))
      ;; No staged changes, user says no
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (madolt-commit-create nil))
      ;; Commit count should not have changed
      (should (= (length (madolt-log-entries 10)) count-before)))))

(provide 'madolt-commit-tests)
;;; madolt-commit-tests.el ends here
