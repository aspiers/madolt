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
  "madolt-rebase-elsewhere should invoke SQL DOLT_REBASE with correct args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-rebase-elsewhere "feature" nil)
        (should (equal called-args
                       '("sql" "-q" "CALL DOLT_REBASE('feature')")))))))

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
                       '("sql" "-q" "CALL DOLT_REBASE('--empty=keep', 'feature')")))))))

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

;;;; Interactive rebase — commit at point uses parent as base

(ert-deftest test-madolt-rebase-interactive-uses-parent-when-commit-at-point ()
  "When a commit is at point, interactive rebase uses its parent as upstream.
This ensures the pointed-at commit is included in the rebase plan."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "second")
    (let* ((head (string-trim
                  (cdr (madolt--run "sql" "-q"
                                    "SELECT commit_hash FROM dolt_log LIMIT 1"
                                    "-r" "csv"))))
           (head (car (last (split-string head "\n"))))
           (parent (madolt-rebase--commit-parent head))
           (called-upstream nil))
      (cl-letf (((symbol-function 'madolt-commit-at-point) (lambda () head))
                ((symbol-function 'madolt-branch-or-commit-at-point) (lambda () head))
                ((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args)
                   (let ((flat (madolt--flatten-args args)))
                     (when (cl-some (lambda (a) (string-match-p "DOLT_REBASE" a)) flat)
                       (let ((query (car (last flat))))
                         (when (string-match "DOLT_REBASE('-i', '\\([^']+\\)')" query)
                           (setq called-upstream (match-string 1 query))))))
                   '(0 . "")))
                ((symbol-function 'madolt-rebase--show-plan) #'ignore)
                ((symbol-function 'madolt-rebase--stash-push)
                 (lambda (_dir _name) nil)))
        (call-interactively #'madolt-rebase-interactive)
        (should (equal called-upstream parent))))))

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

(ert-deftest test-madolt-rebase-render-plan-truncates-multiline ()
  "madolt-rebase--render-plan should show only the first line of messages."
  (with-temp-buffer
    (let ((madolt-rebase--branch "main")
          (madolt-rebase--upstream "abc123")
          (plan (list (list :order 1 :action "pick" :hash "abcdef1234567890"
                            :message "First line\n\nBody line 1\nBody line 2")
                      (list :order 2 :action "pick" :hash "1234567890abcdef"
                            :message "Single line commit"))))
      (madolt-rebase--render-plan plan)
      (let ((text (buffer-string)))
        ;; First lines should appear
        (should (string-match-p "First line" text))
        (should (string-match-p "Single line commit" text))
        ;; Body lines should NOT appear
        (should-not (string-match-p "Body line 1" text))
        (should-not (string-match-p "Body line 2" text))))))

;;;; Orphan rebase stash detection (madolt-qjjm)

(ert-deftest test-madolt-rebase-check-orphan-stashes-warns-on-orphan ()
  "An untracked madolt-rebase-* stash should produce a :warning."
  (let ((warnings nil)
        (madolt-rebase--orphans-checked nil)
        (madolt-rebase--active-stashes nil))
    (cl-letf (((symbol-function 'madolt-dolt-json)
               (lambda (&rest _args)
                 '((rows . (((name . "madolt-rebase-feature-main-1700000000")
                             (branch . "feature")
                             (hash . "abcd1234")
                             (commit_message . "WIP"))))
                   (schema . nil))))
              ((symbol-function 'display-warning)
               (lambda (type message &optional level)
                 (push (list type message level) warnings))))
      (madolt-rebase--check-orphan-stashes "/tmp/db")
      (should warnings)
      (let* ((entry (car warnings))
             (msg (cadr entry)))
        (should (eq (car entry) 'madolt))
        (should (eq (caddr entry) :warning))
        (should (string-match-p "madolt-rebase-feature-main" msg))
        (should (string-match-p "Recover" msg))))))

(ert-deftest test-madolt-rebase-check-orphan-stashes-skips-known ()
  "A stash tracked in active-stashes must not produce a warning."
  (let ((warnings nil)
        (madolt-rebase--orphans-checked nil)
        (madolt-rebase--active-stashes
         '(("/tmp/db" . "madolt-rebase-feature-main-1700000000"))))
    (cl-letf (((symbol-function 'madolt-dolt-json)
               (lambda (&rest _args)
                 '((rows . (((name . "madolt-rebase-feature-main-1700000000")
                             (branch . "feature")
                             (hash . "abcd1234")
                             (commit_message . "WIP"))))
                   (schema . nil))))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (madolt-rebase--check-orphan-stashes "/tmp/db")
      (should-not warnings))))

(ert-deftest test-madolt-rebase-check-orphan-stashes-runs-once-per-db ()
  "The check must run only once per Emacs session per database directory."
  (let ((calls 0)
        (madolt-rebase--orphans-checked nil)
        (madolt-rebase--active-stashes nil))
    (cl-letf (((symbol-function 'madolt-dolt-json)
               (lambda (&rest _args)
                 (cl-incf calls)
                 '((rows . ()) (schema . nil))))
              ((symbol-function 'display-warning) #'ignore))
      (madolt-rebase--check-orphan-stashes "/tmp/db")
      (madolt-rebase--check-orphan-stashes "/tmp/db")
      (madolt-rebase--check-orphan-stashes "/tmp/db")
      (should (equal calls 1)))))

(ert-deftest test-madolt-rebase-check-orphan-stashes-silent-on-error ()
  "Query failure must not raise — orphan detection is best-effort."
  (let ((madolt-rebase--orphans-checked nil)
        (madolt-rebase--active-stashes nil))
    (cl-letf (((symbol-function 'madolt-dolt-json)
               (lambda (&rest _args) (error "boom")))
              ((symbol-function 'display-warning) #'ignore))
      ;; Should not signal
      (madolt-rebase--check-orphan-stashes "/tmp/db"))))

(ert-deftest test-madolt-rebase-check-orphan-stashes-no-orphans-silent ()
  "An empty result set should produce no warnings."
  (let ((warnings nil)
        (madolt-rebase--orphans-checked nil)
        (madolt-rebase--active-stashes nil))
    (cl-letf (((symbol-function 'madolt-dolt-json)
               (lambda (&rest _args) '((rows . ()) (schema . nil))))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (madolt-rebase--check-orphan-stashes "/tmp/db")
      (should-not warnings))))

;;;; Stash-pop: surface failure as warning (madolt-2o4o)

(ert-deftest test-madolt-rebase-stash-pop-surfaces-failure ()
  "When stash pop fails, an error-level warning must be raised."
  (let ((warnings nil))
    (cl-letf (((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) '(1 . "stash not found")))
              ((symbol-function 'madolt-connection--log) #'ignore)
              ((symbol-function 'display-warning)
               (lambda (type message &optional level)
                 (push (list type message level) warnings))))
      (madolt-rebase--stash-pop "/tmp/db" "stash-xyz")
      (should warnings)
      (let* ((entry (car warnings))
             (msg (cadr entry))
             (level (caddr entry)))
        (should (eq (car entry) 'madolt))
        (should (eq level :error))
        (should (string-match-p "stash-xyz" msg))
        (should (string-match-p "Recover with" msg))))))

(ert-deftest test-madolt-rebase-stash-pop-silent-on-success ()
  "When stash pop succeeds, no warning should be raised."
  (let ((warnings nil))
    (cl-letf (((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) '(0 . "")))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (madolt-rebase--stash-pop "/tmp/db" "stash-xyz")
      (should-not warnings))))

(ert-deftest test-madolt-rebase-stash-pop-noop-without-stash ()
  "With nil stash-name, stash-pop should do nothing — no SQL call, no warning."
  (let ((called nil)
        (warnings nil))
    (cl-letf (((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) (setq called t) '(0 . "")))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (madolt-rebase--stash-pop "/tmp/db" nil)
      (should-not called)
      (should-not warnings))))

;;;; Abort-then-pop: avoid silent corruption when abort fails

(ert-deftest test-madolt-rebase-abort-then-pop-pops-on-success ()
  "When abort succeeds, the stash should be popped."
  (let ((calls nil))
    (cl-letf (((symbol-function 'madolt-call-dolt)
               (lambda (&rest args)
                 (push args calls)
                 ;; Abort call -> success
                 '(0 . "")))
              ((symbol-function 'madolt-rebase--stash-pop)
               (lambda (db-dir stash-name)
                 (push (list 'pop db-dir stash-name) calls))))
      (madolt-rebase--abort-then-pop
       "dolt_rebase_main" "/tmp/db" "stash-xyz" "test")
      (let ((reversed (reverse calls)))
        ;; First call should be the abort
        (should (equal (car reversed)
                       '("--branch" "dolt_rebase_main"
                         "sql" "-q" "CALL DOLT_REBASE('--abort')")))
        ;; Pop must follow
        (should (equal (cadr reversed)
                       '(pop "/tmp/db" "stash-xyz")))))))

(ert-deftest test-madolt-rebase-abort-then-pop-retains-stash-on-failure ()
  "When abort fails, the stash must NOT be popped — data-loss hazard."
  (let ((pop-called nil)
        (warnings nil))
    (cl-letf (((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) '(1 . "abort error")))
              ((symbol-function 'madolt-rebase--stash-pop)
               (lambda (&rest _args) (setq pop-called t)))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (madolt-rebase--abort-then-pop
       "dolt_rebase_main" "/tmp/db" "stash-xyz" "Rollback")
      (should-not pop-called)
      ;; A warning must be surfaced mentioning the stash name
      (should warnings)
      (let ((msg (cadr (car warnings))))
        (should (string-match-p "stash-xyz" msg))
        (should (string-match-p "Rollback" msg))))))

(ert-deftest test-madolt-rebase-abort-then-pop-no-warning-without-stash ()
  "When there is no stash, abort failure should still not raise a stash warning."
  (let ((warnings nil))
    (cl-letf (((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) '(1 . "abort error")))
              ((symbol-function 'madolt-rebase--stash-pop)
               (lambda (&rest _args)
                 (error "Should not be called")))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (madolt-rebase--abort-then-pop
       "dolt_rebase_main" "/tmp/db" nil "Rollback")
      (should-not warnings))))

(ert-deftest test-madolt-rebase-continue-retains-stash-on-failure ()
  "If `--continue' fails, the stash and active-stashes entry must survive."
  (let ((pop-called nil)
        (madolt-rebase--active-stashes
         '(("/tmp/db" . "stash-xyz"))))
    (cl-letf (((symbol-function 'madolt-current-branch)
               (lambda () "main"))
              ((symbol-function 'madolt-branch-names)
               (lambda () '("dolt_rebase_main" "main")))
              ((symbol-function 'madolt-database-dir)
               (lambda () "/tmp/db"))
              ((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) '(1 . "continue conflict")))
              ((symbol-function 'madolt-rebase--stash-pop)
               (lambda (&rest _args) (setq pop-called t)))
              ((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'display-warning) #'ignore)
              ((symbol-function 'message) #'ignore))
      (madolt-rebase-continue-command)
      (should-not pop-called)
      ;; alist entry must still be there for recovery / orphan detection
      (should (equal (alist-get "/tmp/db" madolt-rebase--active-stashes
                                nil nil #'equal)
                     "stash-xyz")))))

(ert-deftest test-madolt-rebase-abort-command-retains-stash-on-failure ()
  "If `--abort' fails, the stash and active-stashes entry must survive."
  (let ((pop-called nil)
        (madolt-rebase--active-stashes
         '(("/tmp/db" . "stash-xyz"))))
    (cl-letf (((symbol-function 'madolt-current-branch)
               (lambda () "main"))
              ((symbol-function 'madolt-branch-names)
               (lambda () '("dolt_rebase_main" "main")))
              ((symbol-function 'madolt-database-dir)
               (lambda () "/tmp/db"))
              ((symbol-function 'madolt-call-dolt)
               (lambda (&rest _args) '(1 . "abort error")))
              ((symbol-function 'madolt-rebase--stash-pop)
               (lambda (&rest _args) (setq pop-called t)))
              ((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'display-warning) #'ignore)
              ((symbol-function 'message) #'ignore))
      (madolt-rebase-abort-command)
      (should-not pop-called)
      (should (equal (alist-get "/tmp/db" madolt-rebase--active-stashes
                                nil nil #'equal)
                     "stash-xyz")))))

(provide 'madolt-rebase-tests)
;;; madolt-rebase-tests.el ends here
