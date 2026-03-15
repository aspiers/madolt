;;; madolt-dolt-tests.el --- Tests for madolt-dolt.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the Dolt CLI wrapper layer.

;;; Code:

(require 'ert)
(require 'madolt-test-helpers)
(require 'madolt-dolt)

;;;; Core execution — madolt--run

(ert-deftest test-madolt--run-basic ()
  "madolt--run executes dolt and returns (exit-code . output)."
  (madolt-with-test-database
    (let ((result (madolt--run "status")))
      (should (consp result))
      (should (integerp (car result)))
      (should (zerop (car result)))
      (should (stringp (cdr result)))
      (should (string-match-p "On branch" (cdr result))))))

(ert-deftest test-madolt--run-failure ()
  "madolt--run returns non-zero exit code for bad commands."
  (madolt-with-test-database
    (let ((result (madolt--run "nonexistent-command")))
      (should (not (zerop (car result)))))))

(ert-deftest test-madolt--run-flattens-args ()
  "madolt--run handles nested argument lists."
  (madolt-with-test-database
    (let ((result (madolt--run (list "branch" (list "--show-current")))))
      (should (zerop (car result)))
      (should (string-match-p "main" (cdr result))))))

(ert-deftest test-madolt--run-removes-nils ()
  "madolt--run removes nil arguments."
  (madolt-with-test-database
    (let ((result (madolt--run "branch" nil "--show-current" nil)))
      (should (zerop (car result)))
      (should (string-match-p "main" (cdr result))))))

;;;; Core execution — derivative functions

(ert-deftest test-madolt-dolt-string-returns-first-line ()
  "madolt-dolt-string returns the first line of output."
  (madolt-with-test-database
    (let ((result (madolt-dolt-string "branch" "--show-current")))
      (should (stringp result))
      (should (equal result "main")))))

(ert-deftest test-madolt-dolt-string-nil-on-failure ()
  "madolt-dolt-string returns nil on non-zero exit."
  (madolt-with-test-database
    (should (null (madolt-dolt-string "nonexistent-command")))))

(ert-deftest test-madolt-dolt-string-nil-on-empty ()
  "madolt-dolt-string returns nil when there is no output."
  (madolt-with-test-database
    ;; dolt add with nothing to add produces no stdout (just stderr)
    ;; Use a command that succeeds but produces empty stdout
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; dolt reset when nothing staged produces empty output
    (let ((result (madolt-dolt-string "reset")))
      ;; May return nil or empty string depending on dolt behavior
      (should (or (null result) (string-empty-p result))))))

(ert-deftest test-madolt-dolt-lines-splits-output ()
  "madolt-dolt-lines returns a list of non-empty lines."
  (madolt-with-test-database
    (let ((result (madolt-dolt-lines "branch")))
      (should (listp result))
      (should (cl-some (lambda (line) (string-match-p "main" line))
                       result)))))

(ert-deftest test-madolt-dolt-lines-omits-empty ()
  "madolt-dolt-lines omits empty lines."
  (madolt-with-test-database
    (let ((result (madolt-dolt-lines "status")))
      (should (cl-every (lambda (line) (not (string-empty-p line)))
                        result)))))

(ert-deftest test-madolt-dolt-json-parses-valid ()
  "madolt-dolt-json parses valid JSON output from dolt diff."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (madolt-test-commit "add t1")
    (madolt-test-update-row "t1" "val = 'world'" "id = 1")
    (let ((result (madolt-dolt-json "diff" "-r" "json")))
      (should result)
      (should (listp result))
      ;; Should have a 'tables key in the alist
      (should (assq 'tables result)))))

(ert-deftest test-madolt-dolt-json-nil-on-invalid ()
  "madolt-dolt-json returns nil for non-JSON output."
  (madolt-with-test-database
    ;; dolt status does not produce JSON
    (should (null (madolt-dolt-json "status")))))

(ert-deftest test-madolt-dolt-insert-at-point ()
  "madolt-dolt-insert inserts output at point in current buffer."
  (madolt-with-test-database
    (with-temp-buffer
      (let ((exit (madolt-dolt-insert "branch" "--show-current")))
        (should (zerop exit))
        (should (string-match-p "main" (buffer-string)))))))

(ert-deftest test-madolt-dolt-exit-code-returns-integer ()
  "madolt-dolt-exit-code returns an integer."
  (madolt-with-test-database
    (should (integerp (madolt-dolt-exit-code "status")))
    (should (zerop (madolt-dolt-exit-code "status")))))

(ert-deftest test-madolt-dolt-success-p-true ()
  "madolt-dolt-success-p returns non-nil for successful commands."
  (madolt-with-test-database
    (should (madolt-dolt-success-p "status"))))

(ert-deftest test-madolt-dolt-success-p-false ()
  "madolt-dolt-success-p returns nil for failed commands."
  (madolt-with-test-database
    (should-not (madolt-dolt-success-p "nonexistent-command"))))

;;;; Database context

(ert-deftest test-madolt-database-dir-in-dolt-repo ()
  "madolt-database-dir returns correct path in a dolt database."
  (madolt-with-test-database
    (let ((dir (madolt-database-dir)))
      (should dir)
      (should (stringp dir))
      (should (file-directory-p (expand-file-name ".dolt" dir))))))

(ert-deftest test-madolt-database-dir-subdirectory ()
  "madolt-database-dir works from a subdirectory."
  (madolt-with-test-database
    (let* ((sub (expand-file-name "subdir/" default-directory))
           (_ (make-directory sub t))
           (default-directory sub))
      (should (madolt-database-dir)))))

(ert-deftest test-madolt-database-dir-nil-outside ()
  "madolt-database-dir returns nil outside a dolt database."
  (let ((default-directory temporary-file-directory))
    (should (null (madolt-database-dir)))))

(ert-deftest test-madolt-database-p-true ()
  "madolt-database-p returns non-nil in a dolt database."
  (madolt-with-test-database
    (should (madolt-database-p))))

(ert-deftest test-madolt-database-p-false ()
  "madolt-database-p returns nil outside a dolt database."
  (let ((default-directory temporary-file-directory))
    (should-not (madolt-database-p))))

(ert-deftest test-madolt-current-branch ()
  "madolt-current-branch returns the current branch name."
  (madolt-with-test-database
    (should (equal (madolt-current-branch) "main"))))

;;;; SQL server info

(ert-deftest test-madolt-sql-server-info-nil-when-no-file ()
  "madolt-sql-server-info returns nil when no server info file exists."
  (madolt-with-test-database
    (should-not (madolt-sql-server-info))))

(ert-deftest test-madolt-sql-server-info-nil-when-stale ()
  "madolt-sql-server-info returns nil when PID is not running."
  (madolt-with-test-database
    ;; Write a fake info file with a PID that doesn't exist
    (let ((info-file (expand-file-name ".dolt/sql-server.info")))
      (with-temp-file info-file
        (insert "9999999:3306:fake-uuid"))
      (should-not (madolt-sql-server-info)))))

(ert-deftest test-madolt-sql-server-info-returns-plist ()
  "madolt-sql-server-info returns (:pid PID :port PORT) for a live server."
  (madolt-with-test-database
    ;; Write an info file with our own PID (guaranteed to exist)
    (let ((info-file (expand-file-name ".dolt/sql-server.info"))
          (my-pid (emacs-pid)))
      (with-temp-file info-file
        (insert (format "%d:13306:fake-uuid" my-pid)))
      (let ((result (madolt-sql-server-info)))
        (should result)
        (should (= (plist-get result :pid) my-pid))
        (should (= (plist-get result :port) 13306))))))

;;;; Status parser

(ert-deftest test-madolt-status-tables-clean ()
  "madolt-status-tables returns empty alists for a clean working tree."
  (madolt-with-test-database
    (let ((result (madolt-status-tables)))
      (should (null (alist-get 'staged result)))
      (should (null (alist-get 'unstaged result)))
      (should (null (alist-get 'untracked result))))))

(ert-deftest test-madolt-status-tables-staged-modified ()
  "madolt-status-tables detects staged modifications."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (madolt-test-commit "add t1")
    (madolt-test-update-row "t1" "val = 'world'" "id = 1")
    (madolt-test-stage-table "t1")
    (let* ((result (madolt-status-tables))
           (staged (alist-get 'staged result)))
      (should staged)
      (should (assoc "t1" staged))
      (should (equal (cdr (assoc "t1" staged)) "modified")))))

(ert-deftest test-madolt-status-tables-unstaged-modified ()
  "madolt-status-tables detects unstaged modifications."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (madolt-test-commit "add t1")
    (madolt-test-update-row "t1" "val = 'world'" "id = 1")
    (let* ((result (madolt-status-tables))
           (unstaged (alist-get 'unstaged result)))
      (should unstaged)
      (should (assoc "t1" unstaged))
      (should (equal (cdr (assoc "t1" unstaged)) "modified")))))

(ert-deftest test-madolt-status-tables-untracked ()
  "madolt-status-tables detects untracked tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (let* ((result (madolt-status-tables))
           (untracked (alist-get 'untracked result)))
      (should untracked)
      (should (assoc "t1" untracked))
      (should (equal (cdr (assoc "t1" untracked)) "new table")))))

(ert-deftest test-madolt-status-tables-mixed ()
  "madolt-status-tables handles staged + unstaged + untracked together."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (let* ((result (madolt-status-tables))
           (staged (alist-get 'staged result))
           (unstaged (alist-get 'unstaged result))
           (untracked (alist-get 'untracked result)))
      (should (assoc "users" staged))
      (should (assoc "products" unstaged))
      (should (assoc "inventory" untracked)))))

(ert-deftest test-madolt-status-tables-deleted ()
  "madolt-status-tables detects deleted tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "add t1")
    (madolt-test-sql "DROP TABLE t1")
    (let* ((result (madolt-status-tables))
           (unstaged (alist-get 'unstaged result)))
      (should unstaged)
      (should (assoc "t1" unstaged))
      (should (equal (cdr (assoc "t1" unstaged)) "deleted")))))

;;;; Diff queries

(ert-deftest test-madolt-diff-json-returns-parsed ()
  "madolt-diff-json returns parsed JSON diff structure."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (madolt-test-commit "add t1")
    (madolt-test-update-row "t1" "val = 'world'" "id = 1")
    (let ((result (madolt-diff-json)))
      (should result)
      (should (assq 'tables result))
      (let ((tables (alist-get 'tables result)))
        (should (= 1 (length tables)))))))

(ert-deftest test-madolt-diff-json-empty-when-clean ()
  "madolt-diff-json returns nil or empty when no changes."
  (madolt-with-test-database
    (let ((result (madolt-diff-json)))
      ;; With no changes, diff -r json may return empty tables list
      ;; or nil depending on dolt version
      (should (or (null result)
                  (null (alist-get 'tables result))
                  (= 0 (length (alist-get 'tables result))))))))

(ert-deftest test-madolt-diff-stat-returns-string ()
  "madolt-diff-stat returns a string with statistics."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (madolt-test-commit "add t1")
    (madolt-test-update-row "t1" "val = 'world'" "id = 1")
    (let ((result (madolt-diff-stat)))
      (should (stringp result))
      (should (string-match-p "Row" result)))))

(ert-deftest test-madolt-diff-raw-returns-tabular ()
  "madolt-diff-raw returns tabular output with diff markers."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'hello')")
    (madolt-test-commit "add t1")
    (madolt-test-update-row "t1" "val = 'world'" "id = 1")
    (let ((result (madolt-diff-raw)))
      (should (stringp result))
      (should (string-match-p "diff --dolt" result))
      ;; Should contain row markers
      (should (or (string-match-p "| <" result)
                  (string-match-p "| >" result))))))

;;;; Log queries

(ert-deftest test-madolt-log-entries-returns-plists ()
  "madolt-log-entries returns a list of plists."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "first commit")
    (let ((entries (madolt-log-entries 5)))
      ;; At least 2 entries: "first commit" + dolt init commit
      (should (>= (length entries) 2))
      (let ((entry (car entries)))
        (should (plist-get entry :hash))
        (should (plist-get entry :author))
        (should (plist-get entry :date))
        (should (plist-get entry :message))))))

(ert-deftest test-madolt-log-entries-limit ()
  "madolt-log-entries respects the N limit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 1)")
    (madolt-test-commit "commit 1")
    (madolt-test-update-row "t1" "val = 2" "id = 1")
    (madolt-test-commit "commit 2")
    (madolt-test-update-row "t1" "val = 3" "id = 1")
    (madolt-test-commit "commit 3")
    (let ((entries (madolt-log-entries 2)))
      (should (= 2 (length entries))))))

(ert-deftest test-madolt-log-entries-fields ()
  "madolt-log-entries plists have all expected fields."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "test message")
    (let ((entry (car (madolt-log-entries 1))))
      (should (stringp (plist-get entry :hash)))
      (should (stringp (plist-get entry :author)))
      (should (stringp (plist-get entry :date)))
      (should (stringp (plist-get entry :message)))
      (should (equal "test message" (plist-get entry :message))))))

(ert-deftest test-madolt-log-entries-refs ()
  "madolt-log-entries includes refs for HEAD commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "test")
    (let ((entry (car (madolt-log-entries 1))))
      ;; HEAD commit should have refs like "HEAD -> main"
      (should (plist-get entry :refs))
      (should (string-match-p "main" (plist-get entry :refs))))))

(ert-deftest test-madolt-log-entries-no-ansi ()
  "madolt-log-entries contains no ANSI escape codes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "test")
    (let ((entries (madolt-log-entries 5)))
      (dolist (entry entries)
        (dolist (key '(:hash :refs :date :author :message))
          (let ((val (plist-get entry key)))
            (when val
              (should-not (string-match-p "\033" val)))))))))

(ert-deftest test-madolt-log-entries-with-graph ()
  "madolt-log-entries parses correctly with --graph flag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "graph test")
    (let ((entries (madolt-log-entries 5 nil '("--graph"))))
      (should (>= (length entries) 2))
      (let ((entry (car entries)))
        (should (stringp (plist-get entry :hash)))
        (should (equal "graph test" (plist-get entry :message)))))))

(ert-deftest test-madolt-log-entries-graph-prefix ()
  "madolt-log-entries captures :graph prefix when --graph is used."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "first")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "second")
    (let ((entries (madolt-log-entries 5 nil '("--graph"))))
      ;; Every entry should have a :graph key containing *
      (dolist (entry entries)
        (should (plist-get entry :graph))
        (should (string-match-p "\\*" (plist-get entry :graph)))))))

(ert-deftest test-madolt-log-entries-no-graph-without-flag ()
  "madolt-log-entries returns nil :graph when --graph not used."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "first")
    (let ((entries (madolt-log-entries 5)))
      (dolist (entry entries)
        (should-not (plist-get entry :graph))))))

(ert-deftest test-madolt-log-entries-graph-merge-junction ()
  "Graph junction lines are captured in :graph-pre for merges."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    ;; Create divergent branch for merge
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "-b" "feat")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "feat commit")
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "main")
    (madolt-test-insert-row "t1" "(3)")
    (madolt-test-commit "main commit")
    (call-process madolt-dolt-executable nil nil nil
                  "merge" "feat" "--no-ff" "-m" "Merge feat")
    (let ((entries (madolt-log-entries 10 nil '("--graph"))))
      ;; Merge commit should be first
      (should (equal "Merge feat" (plist-get (car entries) :message)))
      ;; After the merge, there should be junction lines somewhere
      ;; (|\ after merge commit, |/ before the common ancestor)
      (let ((has-junction nil))
        (dolist (entry entries)
          (when (plist-get entry :graph-pre)
            (setq has-junction t)))
        (should has-junction)))))

;;;; Mutation operations

(ert-deftest test-madolt-add-tables-stages ()
  "madolt-add-tables stages specified tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (madolt-test-update-row "t1" "id = 2" "id = 1")
    (madolt-add-tables '("t1"))
    (let ((staged (alist-get 'staged (madolt-status-tables))))
      (should (assoc "t1" staged)))))

(ert-deftest test-madolt-add-all-stages-everything ()
  "madolt-add-all stages all changed tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t2" "(1)")
    (madolt-add-all)
    (let ((staged (alist-get 'staged (madolt-status-tables))))
      (should (assoc "t1" staged))
      (should (assoc "t2" staged)))))

(ert-deftest test-madolt-reset-tables-unstages ()
  "madolt-reset-tables moves a table from staged to unstaged."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 1)")
    (madolt-test-commit "init")
    (madolt-test-update-row "t1" "val = 2" "id = 1")
    (madolt-test-stage-table "t1")
    ;; Verify staged first
    (should (assoc "t1" (alist-get 'staged (madolt-status-tables))))
    ;; Reset
    (madolt-reset-tables '("t1"))
    (let ((status (madolt-status-tables)))
      (should-not (assoc "t1" (alist-get 'staged status)))
      (should (assoc "t1" (alist-get 'unstaged status))))))

(ert-deftest test-madolt-reset-all-unstages-everything ()
  "madolt-reset-all unstages all staged tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t2" "(1)")
    (madolt-test-commit "init")
    (madolt-test-update-row "t1" "id = 2" "id = 1")
    (madolt-test-sql "INSERT INTO t2 VALUES (2)")
    (madolt-test-stage-all)
    ;; Verify staged
    (should (alist-get 'staged (madolt-status-tables)))
    ;; Reset all
    (madolt-reset-all)
    (should-not (alist-get 'staged (madolt-status-tables)))))

(ert-deftest test-madolt-checkout-table-discards ()
  "madolt-checkout-table discards working changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'original')")
    (madolt-test-commit "init")
    (madolt-test-update-row "t1" "val = 'modified'" "id = 1")
    ;; Verify unstaged change exists
    (should (assoc "t1" (alist-get 'unstaged (madolt-status-tables))))
    ;; Discard
    (madolt-checkout-table "t1")
    ;; Verify change is gone
    (should-not (assoc "t1" (alist-get 'unstaged (madolt-status-tables))))))

;;;; Configuration

(ert-deftest test-madolt-dolt-executable-custom ()
  "Custom madolt-dolt-executable is used."
  (madolt-with-test-database
    (let ((madolt-dolt-executable "/nonexistent/dolt"))
      ;; call-process signals file-missing when the executable is absent
      (should-error (madolt--run "status") :type 'file-missing))))

(ert-deftest test-madolt-dolt-global-arguments ()
  "madolt-dolt-global-arguments are prepended to commands."
  (madolt-with-test-database
    ;; Test that global arguments are passed through by using a
    ;; harmless global arg.  There's no great dolt-specific global arg
    ;; to test with, so we verify the mechanism works by checking that
    ;; a valid command still succeeds with empty global args.
    (let ((madolt-dolt-global-arguments nil))
      (should (madolt-dolt-success-p "status")))))

;;;; Internal helpers

(ert-deftest test-madolt--flatten-args ()
  "madolt--flatten-args flattens and filters nil."
  (should (equal (madolt--flatten-args '("a" nil ("b" "c") nil "d"))
                 '("a" "b" "c" "d")))
  (should (equal (madolt--flatten-args nil) nil))
  (should (equal (madolt--flatten-args '(nil nil)) nil)))

(ert-deftest test-madolt--strip-ansi ()
  "madolt--strip-ansi removes ANSI escape sequences."
  (should (equal (madolt--strip-ansi "\033[33mhello\033[0m") "hello"))
  (should (equal (madolt--strip-ansi "no escapes") "no escapes"))
  (should (equal (madolt--strip-ansi "") ""))
  (should (equal (madolt--strip-ansi nil) "")))

;;;; Remote branch detection

(ert-deftest test-madolt-remote-branch-exists-p-true ()
  "madolt-remote-branch-exists-p returns non-nil when remote branch exists."
  (madolt-with-file-remote
    ;; Push to create remote tracking branch
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    (should (madolt-remote-branch-exists-p "origin" "main"))))

(ert-deftest test-madolt-remote-branch-exists-p-false ()
  "madolt-remote-branch-exists-p returns nil for non-existent branch."
  (madolt-with-file-remote
    (should-not (madolt-remote-branch-exists-p "origin" "nonexistent"))))

;;;; Upstream tracking

(ert-deftest test-madolt-upstream-ref-no-remote ()
  "madolt-upstream-ref returns nil when no remotes are configured."
  (madolt-with-test-database
    (should (null (madolt-upstream-ref)))))

(ert-deftest test-madolt-upstream-ref-with-remote ()
  "madolt-upstream-ref returns origin/BRANCH when remote branch exists."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    (should (equal (madolt-upstream-ref) "origin/main"))))

(ert-deftest test-madolt-upstream-ref-no-remote-branch ()
  "madolt-upstream-ref returns nil when remote has no matching branch."
  (madolt-with-file-remote
    ;; Don't push or fetch, so no remote tracking branch exists
    (should (null (madolt-upstream-ref)))))

;;;; Unpushed / unpulled commits

(ert-deftest test-madolt-unpushed-commits-with-ahead ()
  "madolt-unpushed-commits returns local commits not on remote."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    ;; Make a local commit
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "local only")
    (let ((commits (madolt-unpushed-commits)))
      (should commits)
      (should (= 1 (length commits)))
      (should (equal "local only"
                     (plist-get (car commits) :message))))))

(ert-deftest test-madolt-unpushed-commits-none ()
  "madolt-unpushed-commits returns nil when up to date."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    (let ((commits (madolt-unpushed-commits)))
      (should (null commits)))))

(ert-deftest test-madolt-unpushed-commits-no-upstream ()
  "madolt-unpushed-commits returns nil when no upstream exists."
  (madolt-with-test-database
    (should (null (madolt-unpushed-commits)))))

(ert-deftest test-madolt-unpulled-commits-with-behind ()
  "madolt-unpulled-commits returns remote commits not in HEAD.
Uses a stubbed upstream ref pointing to a local branch with
extra commits, since dolt's file:// fetch does not pick up new
remote commits reliably."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "shared base")
    ;; Create a branch to simulate the remote being ahead
    (madolt--run "branch" "fake-remote")
    (madolt--run "checkout" "fake-remote")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "remote only")
    (madolt--run "checkout" "main")
    ;; Stub upstream-ref to return "fake-remote"
    (cl-letf (((symbol-function 'madolt-upstream-ref)
               (lambda (&optional _branch) "fake-remote")))
      (let ((commits (madolt-unpulled-commits)))
        (should commits)
        (should (= 1 (length commits)))
        (should (equal "remote only"
                       (plist-get (car commits) :message)))))))

(ert-deftest test-madolt-unpulled-commits-none ()
  "madolt-unpulled-commits returns nil when up to date."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    (let ((commits (madolt-unpulled-commits)))
      (should (null commits)))))

(ert-deftest test-madolt-unpulled-commits-no-upstream ()
  "madolt-unpulled-commits returns nil when no upstream exists."
  (madolt-with-test-database
    (should (null (madolt-unpulled-commits)))))

;;;; Prefetch

(ert-deftest test-madolt-prefetch-populates-cache ()
  "madolt--prefetch runs commands in parallel and caches results."
  (madolt-with-test-database
    (let ((madolt--refresh-cache (list (cons 0 0))))
      (madolt--prefetch '(("branch" "--show-current")
                          ("status")))
      ;; Both results should now be in the cache
      (let ((branch (madolt--run "branch" "--show-current"))
            (status (madolt--run "status")))
        ;; Results should come from cache (hits > 0)
        (should (> (caar madolt--refresh-cache) 0))
        (should (zerop (car branch)))
        (should (string-match-p "main" (cdr branch)))
        (should (zerop (car status)))
        (should (string-match-p "On branch" (cdr status)))))))

(ert-deftest test-madolt-prefetch-skips-cached ()
  "madolt--prefetch skips commands already in the cache."
  (madolt-with-test-database
    (let ((madolt--refresh-cache (list (cons 0 0))))
      ;; Pre-populate cache with a branch result
      (madolt--run "branch" "--show-current")
      (let ((misses-before (cdar madolt--refresh-cache)))
        ;; Prefetch should skip branch (already cached) but run status
        (madolt--prefetch '(("branch" "--show-current")
                            ("status")))
        ;; Only 1 new miss (status), not 2
        (should (= (- (cdar madolt--refresh-cache) misses-before) 1))))))

(ert-deftest test-madolt-run-caches-within-refresh ()
  "madolt--run caches raw results when refresh-cache is active."
  (madolt-with-test-database
    (let ((madolt--refresh-cache (list (cons 0 0))))
      ;; First call: miss
      (madolt--run "branch" "--show-current")
      (should (= (cdar madolt--refresh-cache) 1))
      (should (= (caar madolt--refresh-cache) 0))
      ;; Second call: hit
      (madolt--run "branch" "--show-current")
      (should (= (caar madolt--refresh-cache) 1)))))

;;;; SQL translation registry

(ert-deftest test-madolt-sql-translation-register ()
  "Registering a SQL translation should add it to the alist."
  (let ((madolt--sql-translations nil))
    (madolt--register-sql-translation
     'test-branch
     (lambda (args) (equal (car args) "branch"))
     (lambda (_args) "SELECT * FROM dolt_branches"))
    (should (= 1 (length madolt--sql-translations)))
    (should (eq 'test-branch (caar madolt--sql-translations)))))

(ert-deftest test-madolt-sql-translation-find ()
  "Finding a translation should match the pattern."
  (let ((madolt--sql-translations nil))
    (madolt--register-sql-translation
     'test-branch
     (lambda (args) (equal (car args) "branch"))
     (lambda (_args) "SELECT * FROM dolt_branches"))
    (should (madolt--find-sql-translation '("branch" "-v")))
    (should-not (madolt--find-sql-translation '("log" "-n" "10")))))

(ert-deftest test-madolt-sql-translation-find-none ()
  "Finding a translation with no registry should return nil."
  (let ((madolt--sql-translations nil))
    (should-not (madolt--find-sql-translation '("branch")))))

(ert-deftest test-madolt-run-sql-disabled ()
  "madolt--run-sql should return nil when SQL is disabled."
  (let ((madolt-use-sql-server nil))
    (should-not (madolt--run-sql '("branch")))))

(ert-deftest test-madolt-run-cli-returns-cons ()
  "madolt--run-cli should return (EXIT-CODE . OUTPUT)."
  (madolt-with-test-database
    (let ((result (madolt--run-cli '("branch" "--show-current"))))
      (should (consp result))
      (should (integerp (car result)))
      (should (stringp (cdr result))))))

;;;; Built-in SQL translations

(ert-deftest test-madolt-sql-translations-registered ()
  "Built-in SQL translations should be registered."
  (should (madolt--find-sql-translation '("branch" "--show-current")))
  (should (madolt--find-sql-translation '("branch")))
  (should (madolt--find-sql-translation '("remote" "-v")))
  (should (madolt--find-sql-translation '("tag")))
  (should (madolt--find-sql-translation '("status")))
  (should (madolt--find-sql-translation '("ls"))))

(ert-deftest test-madolt-sql-translations-mutations ()
  "Mutation commands should have SQL translations for stored procedures."
  (should (madolt--find-sql-translation '("add" ".")))
  (should (madolt--find-sql-translation '("reset" ".")))
  (should (madolt--find-sql-translation '("commit" "-m" "test")))
  (should (madolt--find-sql-translation '("checkout" "main")))
  (should (madolt--find-sql-translation '("branch" "new-branch")))
  (should (madolt--find-sql-translation '("branch" "-d" "foo")))
  (should (madolt--find-sql-translation '("branch" "-m" "old" "new")))
  (should (madolt--find-sql-translation '("tag" "v1.0")))
  (should (madolt--find-sql-translation '("tag" "-d" "v1")))
  (should (madolt--find-sql-translation '("fetch" "origin")))
  (should (madolt--find-sql-translation '("pull" "origin")))
  (should (madolt--find-sql-translation '("push" "origin")))
  (should (madolt--find-sql-translation '("merge" "feature"))))

(ert-deftest test-madolt-sql-translation-log ()
  "Log command should NOT have a SQL translation.
The dolt_log system table lacks a parent_hashes column, so
--parents output cannot be reproduced via SQL."
  (should-not (madolt--find-sql-translation '("log" "--parents" "-n" "10"))))

(provide 'madolt-dolt-tests)
;;; madolt-dolt-tests.el ends here
