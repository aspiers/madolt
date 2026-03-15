;;; madolt-branch-tests.el --- Tests for madolt-branch.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt branch transient and branch commands.

;;; Code:

(require 'ert)
(require 'madolt)
(require 'madolt-branch)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-branch-is-transient ()
  "madolt-branch should be a transient prefix."
  (should (get 'madolt-branch 'transient--layout)))

(ert-deftest test-madolt-branch-has-checkout-suffix ()
  "madolt-branch should have a 'b' suffix for checkout."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-branch)))
    (should (assoc "b" suffixes))
    (should (eq (cdr (assoc "b" suffixes))
                'madolt-branch-checkout-command))))

(ert-deftest test-madolt-branch-has-checkout-create-suffix ()
  "madolt-branch should have a 'c' suffix for create & checkout."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-branch)))
    (should (assoc "c" suffixes))
    (should (eq (cdr (assoc "c" suffixes))
                'madolt-branch-checkout-create-command))))

(ert-deftest test-madolt-branch-has-create-suffix ()
  "madolt-branch should have an 'n' suffix for create (no checkout)."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-branch)))
    (should (assoc "n" suffixes))
    (should (eq (cdr (assoc "n" suffixes))
                'madolt-branch-create-command))))

(ert-deftest test-madolt-branch-has-delete-suffix ()
  "madolt-branch should have a 'k' suffix for delete."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-branch)))
    (should (assoc "k" suffixes))
    (should (eq (cdr (assoc "k" suffixes))
                'madolt-branch-delete-command))))

(ert-deftest test-madolt-branch-has-rename-suffix ()
  "madolt-branch should have an 'm' suffix for rename."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-branch)))
    (should (assoc "m" suffixes))
    (should (eq (cdr (assoc "m" suffixes))
                'madolt-branch-rename-command))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-branch ()
  "The dispatch menu has a \"b\" binding for branch."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "b" suffixes))
    (should (eq (cdr (assoc "b" suffixes)) 'madolt-branch))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-branch ()
  "The mode map should bind 'b' to madolt-branch."
  (should (eq (keymap-lookup madolt-mode-map "b") #'madolt-branch)))

;;;; Backend functions (madolt-dolt.el)

(ert-deftest test-madolt-branch-names ()
  "madolt-branch-names should return branch names."
  (madolt-with-test-database
    (let ((names (madolt-branch-names)))
      (should (member "main" names)))))

(ert-deftest test-madolt-branch-create ()
  "madolt-branch-create should create a new branch."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let ((names (madolt-branch-names)))
      (should (member "feature" names)))
    ;; Should still be on main
    (should (string= (madolt-current-branch) "main"))))

(ert-deftest test-madolt-branch-checkout ()
  "madolt-branch-checkout should switch to the target branch."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (madolt-branch-checkout "feature")
    (should (string= (madolt-current-branch) "feature"))))

(ert-deftest test-madolt-branch-checkout-create ()
  "madolt-branch-checkout-create should create and switch to a new branch."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-checkout-create "feature")
    (should (string= (madolt-current-branch) "feature"))
    (should (member "feature" (madolt-branch-names)))))

(ert-deftest test-madolt-branch-delete ()
  "madolt-branch-delete should remove the branch."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "to-delete")
    (should (member "to-delete" (madolt-branch-names)))
    (madolt-branch-delete "to-delete")
    (should-not (member "to-delete" (madolt-branch-names)))))

(ert-deftest test-madolt-branch-delete-force ()
  "madolt-branch-delete with force should delete even unmerged branches."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Create a branch with a divergent commit
    (madolt-branch-checkout-create "divergent")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "divergent commit")
    (madolt-branch-checkout "main")
    ;; Force delete should succeed
    (madolt-branch-delete "divergent" t)
    (should-not (member "divergent" (madolt-branch-names)))))

(ert-deftest test-madolt-branch-rename ()
  "madolt-branch-rename should change the branch name."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "old-name")
    (madolt-branch-rename "old-name" "new-name")
    (should-not (member "old-name" (madolt-branch-names)))
    (should (member "new-name" (madolt-branch-names)))))

(ert-deftest test-madolt-branch-create-from-start-point ()
  "madolt-branch-create with start-point should branch from that point."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "second")
    ;; Create branch from first commit (HEAD~1)
    (madolt-branch-create "from-first" "HEAD~1")
    (madolt-branch-checkout "from-first")
    ;; t2 should not exist on this branch
    (should-not (madolt-dolt-success-p "sql" "-q"
                                       "SELECT 1 FROM t2 LIMIT 1"))))

;;;; Interactive command tests

(ert-deftest test-madolt-branch-checkout-command-switches ()
  "madolt-branch-checkout-command should switch branches."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "test-branch")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-branch-checkout-command "test-branch"))
    (should (string= (madolt-current-branch) "test-branch"))))

(ert-deftest test-madolt-branch-create-command-no-switch ()
  "madolt-branch-create-command should create without switching."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-branch-create-command "new-branch" nil))
    (should (string= (madolt-current-branch) "main"))
    (should (member "new-branch" (madolt-branch-names)))))

(ert-deftest test-madolt-branch-rename-command-renames ()
  "madolt-branch-rename-command should rename the branch."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "before")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-branch-rename-command "before" "after"))
    (should-not (member "before" (madolt-branch-names)))
    (should (member "after" (madolt-branch-names)))))

;;;; Branch reset

(ert-deftest test-madolt-branch-has-reset-suffix ()
  "madolt-branch should have an 'x' suffix for reset."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-branch)))
    (should (assoc "x" suffixes))
    (should (eq (cdr (assoc "x" suffixes))
                'madolt-branch-reset-command))))

(ert-deftest test-madolt-branch-reset-current-branch ()
  "Resetting the current branch does a hard reset."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (let ((first-hash (madolt-dolt-string "log" "-n" "1" "--oneline")))
      (madolt-test-create-table "t2" "id INT PRIMARY KEY")
      (madolt-test-commit "second")
      ;; t2 should exist
      (should (madolt-dolt-success-p "sql" "-q"
                                     "SELECT 1 FROM t2 LIMIT 1"))
      (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
        (madolt-branch-reset-command "main" "HEAD~1"))
      ;; t2 should be gone after hard reset
      (should-not (madolt-dolt-success-p "sql" "-q"
                                         "SELECT 1 FROM t2 LIMIT 1")))))

(ert-deftest test-madolt-branch-reset-other-branch ()
  "Resetting a non-current branch moves it with dolt branch -f."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (madolt-branch-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "second")
    ;; feature is still at "first", main is at "second"
    ;; Reset feature to HEAD (which is main's HEAD = "second")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-branch-reset-command "feature" "HEAD"))
    ;; Checkout feature — t2 should now exist
    (madolt-branch-checkout "feature")
    (should (madolt-dolt-success-p "sql" "-q"
                                   "SELECT 1 FROM t2 LIMIT 1"))))

(ert-deftest test-madolt-branch-reset-empty-target-errors ()
  "Resetting with empty target should error."
  (madolt-with-test-database
    (should-error (madolt-branch-reset-command "main" "")
                  :type 'user-error)))

(ert-deftest test-madolt-anything-modified-p-clean ()
  "madolt-anything-modified-p returns nil when working tree is clean."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (should-not (madolt-anything-modified-p))))

(ert-deftest test-madolt-anything-modified-p-dirty ()
  "madolt-anything-modified-p returns non-nil with uncommitted changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (should (madolt-anything-modified-p))))

(provide 'madolt-branch-tests)
;;; madolt-branch-tests.el ends here
