;;; madolt-rebase-tests.el --- Tests for madolt-rebase.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt rebase transient and rebase commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-rebase)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-rebase-is-transient ()
  "madolt-rebase should be a transient prefix."
  (should (get 'madolt-rebase 'transient--layout)))

(ert-deftest test-madolt-rebase-has-elsewhere-suffix ()
  "madolt-rebase should have an 'e' suffix for rebase elsewhere."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "e" suffixes))
    (should (eq (cdr (assoc "e" suffixes))
                'madolt-rebase-elsewhere))))

(ert-deftest test-madolt-rebase-has-interactive-suffix ()
  "madolt-rebase should have an 'i' suffix for interactive rebase."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "i" suffixes))
    (should (eq (cdr (assoc "i" suffixes))
                'madolt-rebase-interactive))))

(ert-deftest test-madolt-rebase-has-continue-suffix ()
  "madolt-rebase should have an 'r' suffix for continue."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "r" suffixes))
    (should (eq (cdr (assoc "r" suffixes))
                'madolt-rebase-continue-command))))

(ert-deftest test-madolt-rebase-has-skip-suffix ()
  "madolt-rebase should have an 's' suffix for skip."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "s" suffixes))
    (should (eq (cdr (assoc "s" suffixes))
                'madolt-rebase-skip-command))))

(ert-deftest test-madolt-rebase-has-abort-suffix ()
  "madolt-rebase should have an 'a' suffix for abort."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "a" suffixes))
    (should (eq (cdr (assoc "a" suffixes))
                'madolt-rebase-abort-command))))

;;;; Conditional visibility

(ert-deftest test-madolt-rebase-in-progress-p-false ()
  "madolt-rebase-in-progress-p should return nil when no rebase active."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (should-not (madolt-rebase-in-progress-p))))

(ert-deftest test-madolt-rebase-start-group-has-if-not ()
  "The Rebase group (with \\='i\\=') should have :if-not predicate."
  (let* ((layout (get 'madolt-rebase 'transient--layout))
         (groups (aref layout 2))
         (rebase-group (cl-find-if
                        (lambda (g)
                          (and (vectorp g)
                               (cl-some (lambda (s)
                                          (and (listp s)
                                               (equal (plist-get (cdr s) :key) "i")))
                                        (aref g 2))))
                        groups)))
    (should rebase-group)
    (should (eq (plist-get (aref rebase-group 1) :if-not)
                'madolt-rebase-in-progress-p))))

(ert-deftest test-madolt-rebase-actions-group-has-if ()
  "The Actions group (with \\='r\\=' and \\='a\\=') should have :if predicate."
  (let* ((layout (get 'madolt-rebase 'transient--layout))
         (groups (aref layout 2))
         (actions-group (cl-find-if
                         (lambda (g)
                           (and (vectorp g)
                                (cl-some (lambda (s)
                                           (and (listp s)
                                                (equal (plist-get (cdr s) :key) "r")))
                                         (aref g 2))))
                         groups)))
    (should actions-group)
    (should (eq (plist-get (aref actions-group 1) :if)
                'madolt-rebase-in-progress-p))))

(ert-deftest test-madolt-rebase-args-group-has-if-not ()
  "The Arguments group should have :if-not predicate."
  (let* ((layout (get 'madolt-rebase 'transient--layout))
         (groups (aref layout 2))
         (args-group (cl-find-if
                      (lambda (g)
                        (and (vectorp g)
                             (cl-some (lambda (s)
                                        (and (listp s)
                                             (equal (plist-get (cdr s) :argument)
                                                    "--interactive")))
                                      (aref g 2))))
                      groups)))
    (should args-group)
    (should (eq (plist-get (aref args-group 1) :if-not)
                'madolt-rebase-in-progress-p))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-rebase ()
  "The dispatch menu has an \"r\" binding for rebase."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "r" suffixes))
    (should (eq (cdr (assoc "r" suffixes)) 'madolt-rebase))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-rebase ()
  "The mode map should bind 'r' to madolt-rebase."
  (should (eq (keymap-lookup madolt-mode-map "r") #'madolt-rebase)))

;;;; Rebase command — calls dolt with correct args

(ert-deftest test-madolt-rebase-elsewhere-calls-dolt ()
  "madolt-rebase-elsewhere should invoke dolt rebase with correct args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-rebase-elsewhere "feature" nil)
        (should (equal called-args '("rebase" "feature")))))))

(ert-deftest test-madolt-rebase-elsewhere-with-empty-keep ()
  "madolt-rebase-elsewhere with --empty=keep should pass the flag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-rebase-elsewhere "feature" '("--empty=keep"))
        (should (equal called-args
                       '("rebase" "--empty=keep" "feature")))))))

(ert-deftest test-madolt-rebase-interactive-calls-sql ()
  "madolt-rebase-interactive should invoke SQL DOLT_REBASE."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'madolt-rebase--show-plan) #'ignore))
        (madolt-rebase-interactive "feature" nil)
        (should (equal called-args
                       '("sql" "-q" "CALL DOLT_REBASE('-i', 'feature')")))))))

;;;; Rebase command — reports failure

(ert-deftest test-madolt-rebase-elsewhere-reports-failure ()
  "madolt-rebase-elsewhere should report failure when rebase fails."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((messages nil))
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest _args) '(1 . "rebase error")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (madolt-rebase-elsewhere "nonexistent" nil))
      (should (cl-some (lambda (msg)
                         (string-match-p "failed" msg))
                       messages)))))

;;;; Continue command

(ert-deftest test-madolt-rebase-continue-calls-dolt ()
  "madolt-rebase-continue-command should invoke dolt rebase --continue."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-rebase-continue-command)
        (should (equal called-args '("rebase" "--continue")))))))

;;;; Abort command

(ert-deftest test-madolt-rebase-abort-calls-dolt ()
  "madolt-rebase-abort-command should invoke dolt rebase --abort."
  (madolt-with-test-database
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-rebase-abort-command)
        (should (equal called-args '("rebase" "--abort")))))))

;;;; Rebase — actual rebase operation

(ert-deftest test-madolt-rebase-onto-branch ()
  "Rebasing a branch onto another should rewrite commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Create a feature branch with an extra commit
    (madolt-branch-checkout-create "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "add t2 on feature")
    ;; Add a commit on main so branches diverge
    (madolt-branch-checkout "main")
    (madolt-test-create-table "t3" "id INT PRIMARY KEY")
    (madolt-test-commit "add t3 on main")
    ;; Switch to feature and rebase onto main
    (madolt-branch-checkout "feature")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-rebase-elsewhere "main" nil))
    ;; After rebase, feature should have both t2 and t3
    (should (madolt-dolt-success-p "sql" "-q" "SELECT 1 FROM t2 LIMIT 1"))
    (should (madolt-dolt-success-p "sql" "-q" "SELECT 1 FROM t3 LIMIT 1"))))

(ert-deftest test-madolt-rebase-in-progress-p-bypasses-sql ()
  "madolt-rebase-in-progress-p should use CLI, not SQL routing."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Enable SQL server routing and verify we still get the right answer
    ;; via CLI.  If SQL were used, dolt_status returns tab-separated rows
    ;; that never contain "rebase in progress".
    (let ((madolt-use-sql-server t))
      (should-not (madolt-rebase-in-progress-p)))))

;;;; Single-commit rebase transient suffixes

(ert-deftest test-madolt-rebase-has-drop-suffix ()
  "madolt-rebase should have a 'k' suffix for dropping a commit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "k" suffixes))
    (should (eq (cdr (assoc "k" suffixes))
                'madolt-rebase-drop-commit))))

(ert-deftest test-madolt-rebase-has-edit-suffix ()
  "madolt-rebase should have an 'm' suffix for editing a commit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "m" suffixes))
    (should (eq (cdr (assoc "m" suffixes))
                'madolt-rebase-edit-commit))))

(ert-deftest test-madolt-rebase-has-reword-suffix ()
  "madolt-rebase should have a 'w' suffix for rewording a commit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-rebase)))
    (should (assoc "w" suffixes))
    (should (eq (cdr (assoc "w" suffixes))
                'madolt-rebase-reword-commit))))

;;;; Single-commit rebase operations

(defun madolt-test--setup-two-commits ()
  "Create two commits on main and return the hash of the second (HEAD)."
  (madolt-test-create-table "t1" "id INT PRIMARY KEY")
  (madolt-test-commit "first")
  (madolt-test-create-table "t2" "id INT PRIMARY KEY")
  (madolt-test-commit "second")
  (string-trim
   (cdr (madolt--run "sql" "-q"
                     "SELECT commit_hash FROM dolt_log LIMIT 1"
                     "-r" "csv"
                     ))))

(ert-deftest test-madolt-rebase-drop-commit-opens-plan ()
  "madolt-rebase-drop-commit should start a rebase with the commit set to drop."
  (madolt-with-test-database
    (let ((head (madolt-test--setup-two-commits)))
      ;; Strip CSV header
      (setq head (car (last (split-string head "\n"))))
      (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
        (madolt-rebase-drop-commit head))
      (should (madolt-rebase-in-progress-p))
      ;; The rebase plan should have action=drop for HEAD commit
      (let* ((branch (madolt-current-branch))
             (rebase-branch (concat "dolt_rebase_" branch))
             (json (madolt-dolt-json
                    "--branch" rebase-branch
                    "sql" "-q"
                    (format "SELECT action FROM dolt_rebase WHERE commit_hash='%s'"
                            head)
                    "-r" "json")))
        (should (equal "drop"
                       (alist-get 'action
                                  (car (alist-get 'rows json)))))))))

(ert-deftest test-madolt-rebase-reword-commit-opens-plan ()
  "madolt-rebase-reword-commit should start a rebase with action=reword."
  (madolt-with-test-database
    (let ((head (madolt-test--setup-two-commits)))
      (setq head (car (last (split-string head "\n"))))
      (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
        (madolt-rebase-reword-commit head))
      (should (madolt-rebase-in-progress-p))
      (let* ((branch (madolt-current-branch))
             (rebase-branch (concat "dolt_rebase_" branch))
             (json (madolt-dolt-json
                    "--branch" rebase-branch
                    "sql" "-q"
                    (format "SELECT action FROM dolt_rebase WHERE commit_hash='%s'"
                            head)
                    "-r" "json")))
        (should (equal "reword"
                       (alist-get 'action
                                  (car (alist-get 'rows json)))))))))

(ert-deftest test-madolt-rebase-edit-commit-opens-plan ()
  "madolt-rebase-edit-commit should start a rebase with action=edit."
  (madolt-with-test-database
    (let ((head (madolt-test--setup-two-commits)))
      (setq head (car (last (split-string head "\n"))))
      (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
        (madolt-rebase-edit-commit head))
      (should (madolt-rebase-in-progress-p))
      (let* ((branch (madolt-current-branch))
             (rebase-branch (concat "dolt_rebase_" branch))
             (json (madolt-dolt-json
                    "--branch" rebase-branch
                    "sql" "-q"
                    (format "SELECT action FROM dolt_rebase WHERE commit_hash='%s'"
                            head)
                    "-r" "json")))
        (should (equal "edit"
                       (alist-get 'action
                                  (car (alist-get 'rows json)))))))))

(provide 'madolt-rebase-tests)
;;; madolt-rebase-tests.el ends here
