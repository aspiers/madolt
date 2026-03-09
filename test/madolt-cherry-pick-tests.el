;;; madolt-cherry-pick-tests.el --- Tests for madolt-cherry-pick.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt cherry-pick and revert transients.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-cherry-pick)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transients

(ert-deftest test-madolt-cherry-pick-is-transient ()
  "madolt-cherry-pick should be a transient prefix."
  (should (get 'madolt-cherry-pick 'transient--layout)))

(ert-deftest test-madolt-revert-is-transient ()
  "madolt-revert should be a transient prefix."
  (should (get 'madolt-revert 'transient--layout)))

;;;; Cherry-pick suffixes

(ert-deftest test-madolt-cherry-pick-has-pick-suffix ()
  "madolt-cherry-pick should have an 'A' suffix for cherry-pick."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-cherry-pick)))
    (should (assoc "A" suffixes))
    (should (eq (cdr (assoc "A" suffixes))
                'madolt-cherry-pick-command))))

(ert-deftest test-madolt-cherry-pick-has-abort-suffix ()
  "madolt-cherry-pick should have an 'a' suffix for abort."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-cherry-pick)))
    (should (assoc "a" suffixes))
    (should (eq (cdr (assoc "a" suffixes))
                'madolt-cherry-pick-abort-command))))

;;;; Revert suffixes

(ert-deftest test-madolt-revert-has-revert-suffix ()
  "madolt-revert should have a 'V' suffix for revert."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-revert)))
    (should (assoc "V" suffixes))
    (should (eq (cdr (assoc "V" suffixes))
                'madolt-revert-command))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-cherry-pick ()
  "The dispatch menu has an \"A\" binding for cherry-pick."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "A" suffixes))
    (should (eq (cdr (assoc "A" suffixes)) 'madolt-cherry-pick))))

(ert-deftest test-madolt-dispatch-has-revert ()
  "The dispatch menu has a \"V\" binding for revert."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "V" suffixes))
    (should (eq (cdr (assoc "V" suffixes)) 'madolt-revert))))

;;;; Keybindings

(ert-deftest test-madolt-mode-map-has-cherry-pick ()
  "The mode map should bind 'A' to madolt-cherry-pick."
  (should (eq (keymap-lookup madolt-mode-map "A") #'madolt-cherry-pick)))

(ert-deftest test-madolt-mode-map-has-revert ()
  "The mode map should bind 'V' to madolt-revert."
  (should (eq (keymap-lookup madolt-mode-map "V") #'madolt-revert)))

;;;; Cherry-pick command — calls dolt correctly

(ert-deftest test-madolt-cherry-pick-command-calls-dolt ()
  "madolt-cherry-pick-command should invoke dolt cherry-pick with correct args."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-cherry-pick-command "abc123" nil)
        (should (equal called-args '("cherry-pick" "abc123")))))))

(ert-deftest test-madolt-cherry-pick-command-with-allow-empty ()
  "madolt-cherry-pick-command with --allow-empty passes the flag."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-cherry-pick-command "abc123" '("--allow-empty"))
        (should (equal called-args
                       '("cherry-pick" "abc123" "--allow-empty")))))))

(ert-deftest test-madolt-cherry-pick-command-empty-commit-errors ()
  "madolt-cherry-pick-command with empty commit should error."
  (should-error (madolt-cherry-pick-command "" nil)
                :type 'user-error))

;;;; Cherry-pick abort

(ert-deftest test-madolt-cherry-pick-abort-calls-dolt ()
  "madolt-cherry-pick-abort-command should invoke dolt cherry-pick --abort."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-cherry-pick-abort-command)
        (should (equal called-args '("cherry-pick" "--abort")))))))

;;;; Cherry-pick integration test

(ert-deftest test-madolt-cherry-pick-applies-commit ()
  "Cherry-picking a commit should apply its changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Create a branch with an extra table
    (madolt-branch-checkout-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t2" "(1, 'hello')")
    (madolt-test-commit "add t2")
    ;; Get the commit hash
    (let ((hash (plist-get (car (madolt-log-entries 1)) :hash)))
      ;; Switch back to main
      (madolt-branch-checkout "main")
      ;; t2 should not exist yet
      (should-not (madolt-dolt-success-p "sql" "-q" "SELECT 1 FROM t2 LIMIT 1"))
      ;; Cherry-pick the feature commit
      (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
        (madolt-cherry-pick-command hash nil))
      ;; t2 should now exist
      (should (madolt-dolt-success-p "sql" "-q" "SELECT 1 FROM t2 LIMIT 1")))))

;;;; Revert command — calls dolt correctly

(ert-deftest test-madolt-revert-command-calls-dolt ()
  "madolt-revert-command should invoke dolt revert with correct args."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-revert-command "abc123")
        (should (equal called-args '("revert" "abc123")))))))

(ert-deftest test-madolt-revert-command-empty-commit-errors ()
  "madolt-revert-command with empty commit should error."
  (should-error (madolt-revert-command "")
                :type 'user-error))

;;;; Revert integration test

(ert-deftest test-madolt-revert-undoes-commit ()
  "Reverting a commit should undo its changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'original')")
    (madolt-test-commit "init")
    ;; Make a change and commit
    (madolt-test-insert-row "t1" "(2, 'added')")
    (madolt-test-commit "add row 2")
    ;; Get the hash of the commit we want to revert
    (let ((hash (plist-get (car (madolt-log-entries 1)) :hash)))
      ;; Row 2 should exist
      (should (madolt-dolt-success-p "sql" "-q"
                                     "SELECT 1 FROM t1 WHERE id = 2"))
      ;; Revert it
      (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
        (madolt-revert-command hash))
      ;; Row 2 should be gone — the revert creates a new commit
      ;; undoing the insertion.  Check by counting rows:
      ;; before revert we had 2 rows, after we should have 1.
      (let* ((result (madolt--run "sql" "-q"
                                  "SELECT COUNT(*) as c FROM t1" "-r" "json"))
             (json (json-parse-string (cdr result)
                                      :object-type 'alist
                                      :array-type 'list))
             (count (cdr (assq 'c (car (cdr (assq 'rows json)))))))
        (should (= count 1))))))
(provide 'madolt-cherry-pick-tests)
;;; madolt-cherry-pick-tests.el ends here
