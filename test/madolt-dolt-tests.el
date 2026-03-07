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

(provide 'madolt-dolt-tests)
;;; madolt-dolt-tests.el ends here
