;;; madolt-log-tests.el --- Tests for madolt-log.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt commit log viewer.

;;; Code:

(require 'ert)
(require 'magit-section)
(require 'madolt-log)
(require 'madolt-dolt)
(require 'madolt-diff)
(require 'madolt-mode)
(require 'madolt-test-helpers)

;;;; Helper: collect sections of a given type from a buffer

(defun madolt-log-test--sections-of-type (type)
  "Return a list of sections of TYPE in the current buffer."
  (let ((result nil))
    (when magit-root-section
      (madolt-test--walk-sections
       (lambda (s) (when (eq (oref s type) type) (push s result)))
       magit-root-section))
    (nreverse result)))

;;;; Helper: set up a multi-commit database

(defun madolt-log-test-setup-multi-commit ()
  "Create a test database with multiple commits.
Returns in a state with 3 user commits plus the init commit."
  (madolt-test-create-table "t1" "id INT PRIMARY KEY, val TEXT")
  (madolt-test-insert-row "t1" "(1, 'first')")
  (madolt-test-commit "First commit")
  (madolt-test-update-row "t1" "val = 'second'" "id = 1")
  (madolt-test-commit "Second commit")
  (madolt-test-insert-row "t1" "(2, 'third')")
  (madolt-test-commit "Third commit"))

;;;; Transient

(ert-deftest test-madolt-log-is-transient ()
  "madolt-log should be a transient prefix."
  (should (get 'madolt-log 'transient--layout)))

(ert-deftest test-madolt-log-has-current-suffix ()
  "madolt-log should have an 'l' suffix for current branch."
  (let* ((layout (get 'madolt-log 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "l" all-keys))))

(ert-deftest test-madolt-log-has-other-suffix ()
  "madolt-log should have an 'o' suffix for other branch."
  (let* ((layout (get 'madolt-log 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "o" all-keys))))

(ert-deftest test-madolt-log-arguments ()
  "madolt-log should have documented argument switches."
  (let* ((layout (get 'madolt-log 'transient--layout))
         (groups (aref layout 2))
         (all-args nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((arg (plist-get (cdr suffix) :argument)))
            (when arg (push arg all-args))))))
    (dolist (arg '("--stat" "--merges" "--graph"))
      (should (member arg all-args)))))

;;;; Faces

(ert-deftest test-madolt-log-faces-defined ()
  "All log faces should be defined."
  (dolist (face '(madolt-log-date
                  madolt-log-author
                  madolt-log-refs))
    (should (facep face))))

;;;; Log refresh

(ert-deftest test-madolt-log-refresh-shows-commits ()
  "Log refresh should show commit sections."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should have commit sections
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        ;; At least 3 user commits + 1 init commit
        (should (>= (length commits) 4))))))

(ert-deftest test-madolt-log-commit-section-values ()
  "Each commit section should have the commit hash as its value."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        (dolist (section commits)
          (let ((hash (oref section value)))
            ;; Dolt hashes are 32-char base32 strings
            (should (stringp hash))
            (should (= (length hash) 32))))))))

(ert-deftest test-madolt-log-commit-shows-message ()
  "Each commit section should display its message."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "First commit" text))
        (should (string-match-p "Second commit" text))
        (should (string-match-p "Third commit" text))))))

(ert-deftest test-madolt-log-commit-shows-hash ()
  "Log should display abbreviated commit hashes."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Get the first commit hash and check abbreviated form appears
      (let* ((commits (madolt-log-test--sections-of-type 'commit))
             (hash (oref (car commits) value))
             (short (substring hash 0 8))
             (text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p (regexp-quote short) text))))))

(ert-deftest test-madolt-log-no-ansi ()
  "Log output should not contain ANSI escape sequences."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not (string-match-p "\033\\[" text))))))

(ert-deftest test-madolt-log-heading ()
  "Log buffer should show heading with branch name."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Commits on main:" text))))))

(ert-deftest test-madolt-log-single-commit ()
  "Log should work with a database that has only the init commit."
  (madolt-with-test-database
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should have at least 1 commit (init)
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        (should (>= (length commits) 1))))))

(ert-deftest test-madolt-log-limit ()
  "Log should respect the limit parameter."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 2)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        (should (= (length commits) 2))))))

(ert-deftest test-madolt-log-show-more-button-when-at-limit ()
  "Show-more button should appear when entries equal the limit."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      ;; 4 commits total (3 user + 1 init); set limit to 2
      (setq madolt-log--limit 2)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should have a longer section
      (let ((longer (madolt-log-test--sections-of-type 'longer)))
        (should (= 1 (length longer))))
      ;; Button text should mention "show more"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "show more" text))))))

(ert-deftest test-madolt-log-no-show-more-when-under-limit ()
  "Show-more button should NOT appear when entries are fewer than the limit."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      ;; 4 commits total; set limit higher
      (setq madolt-log--limit 100)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should NOT have a longer section
      (let ((longer (madolt-log-test--sections-of-type 'longer)))
        (should (= 0 (length longer)))))))

(ert-deftest test-madolt-log-double-limit ()
  "madolt-log-double-limit should double the limit."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--limit 25)
    ;; Mock madolt-refresh to avoid needing a real database
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-log-double-limit))
    (should (= madolt-log--limit 50))))

;;;; Branch name completion

(ert-deftest test-madolt-log-branch-names ()
  "madolt-branch-names should return branch names."
  (madolt-with-test-database
    (let ((names (madolt-branch-names)))
      (should (member "main" names)))))

;;;; Log helpers

(ert-deftest test-madolt-log-format-date ()
  "Should format dates as relative ages (e.g. \"3 hours\")."
  ;; Valid date produces a relative age like "N unit(s)"
  (should (string-match-p "^[0-9]+ [a-z]+$"
                          (madolt-log--format-date "2026-03-07 12:00:00")))
  ;; Dolt's native format also works
  (should (string-match-p "^[0-9]+ [a-z]+$"
                          (madolt-log--format-date
                           "Sat Mar 07 12:00:00 +0000 2026")))
  ;; nil input returns nil
  (should (null (madolt-log--format-date nil))))

(ert-deftest test-madolt-log-short-author ()
  "Should strip email from author string."
  (should (equal (madolt-log--short-author "Alice <alice@ex.com>")
                 "Alice"))
  ;; No email — return as-is
  (should (equal (madolt-log--short-author "Alice")
                 "Alice")))

(ert-deftest test-madolt-log-parent-hash ()
  "Should find parent hash of a commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First")
    (madolt-test-update-row "t1" "id = 2" "id = 1")
    (madolt-test-commit "Second")
    (let* ((entries (madolt-log-entries 2))
           (newest (car entries))
           (oldest (cadr entries))
           (parent (madolt-log--parent-hash (plist-get newest :hash))))
      (should parent)
      (should (equal parent (plist-get oldest :hash))))))

;;;; Revision buffer

(ert-deftest test-madolt-log-revision-mode ()
  "madolt-revision-mode should derive from madolt-diff-mode."
  (should (get 'madolt-revision-mode 'derived-mode-parent)))

(ert-deftest test-madolt-log-revision-shows-metadata ()
  "Revision buffer should show commit metadata."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Test revision commit")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          ;; Should show the full hash
          (should (string-match-p (regexp-quote hash) text))
          ;; Should show the message
          (should (string-match-p "Test revision commit" text))
          ;; Should show Author
          (should (string-match-p "Author:" text)))))))

(ert-deftest test-madolt-log-extract-limit ()
  "Should extract -n limit from args."
  (should (eq (madolt-log--extract-limit '("-n25")) 25))
  (should (eq (madolt-log--extract-limit '("-n10" "--stat")) 10))
  (should (eq (madolt-log--extract-limit '("--stat")) nil)))

;;;; Merge commit parsing

(ert-deftest test-madolt-log-entries-parents-nil-for-normal ()
  "Normal commits should have nil :parents."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Normal commit")
    (let* ((entry (car (madolt-log-entries 1))))
      (should-not (plist-get entry :parents)))))

(ert-deftest test-madolt-log-entries-parents-for-merge ()
  "Merge commits should have :parents with two hashes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    ;; Create divergent branch
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "-b" "feat")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "feat commit")
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "main")
    (madolt-test-insert-row "t1" "(3)")
    (madolt-test-commit "main commit")
    ;; Merge with --no-ff to force merge commit
    (call-process madolt-dolt-executable nil nil nil
                  "merge" "feat" "--no-ff" "-m" "Merge feat")
    (let* ((entry (car (madolt-log-entries 1))))
      (should (plist-get entry :parents))
      (should (= 2 (length (plist-get entry :parents))))
      (should (equal "Merge feat" (plist-get entry :message))))))

;;;; Diff statistics

(ert-deftest test-madolt-diff-table-stat-added ()
  "Should count added rows."
  (let ((table-data '((name . "t1")
                      (schema_diff)
                      (data_diff ((from_row) (to_row (id . 1)))
                                 ((from_row) (to_row (id . 2)))))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (equal "t1" (plist-get stat :name)))
      (should (= 2 (plist-get stat :added)))
      (should (= 0 (plist-get stat :deleted)))
      (should (= 0 (plist-get stat :modified))))))

(ert-deftest test-madolt-diff-table-stat-deleted ()
  "Should count deleted rows."
  (let ((table-data '((name . "t1")
                      (schema_diff)
                      (data_diff ((from_row (id . 1)) (to_row))))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (= 0 (plist-get stat :added)))
      (should (= 1 (plist-get stat :deleted)))
      (should (= 0 (plist-get stat :modified))))))

(ert-deftest test-madolt-diff-table-stat-modified ()
  "Should count modified rows."
  (let ((table-data '((name . "t1")
                      (schema_diff)
                      (data_diff ((from_row (id . 1) (val . "a"))
                                  (to_row (id . 1) (val . "b")))))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (= 0 (plist-get stat :added)))
      (should (= 0 (plist-get stat :deleted)))
      (should (= 1 (plist-get stat :modified))))))

(ert-deftest test-madolt-diff-table-stat-schema-changed ()
  "Should detect schema changes."
  (let ((table-data '((name . "t1")
                      (schema_diff "ALTER TABLE t1 ADD COLUMN x INT")
                      (data_diff))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (plist-get stat :schema-changed)))))

(ert-deftest test-madolt-diff-compute-stats-multiple-tables ()
  "Should compute stats for multiple tables."
  (let ((tables (list '((name . "t1")
                        (schema_diff)
                        (data_diff ((from_row) (to_row (id . 1)))))
                      '((name . "t2")
                        (schema_diff)
                        (data_diff ((from_row (id . 2)) (to_row)))))))
    (let ((stats (madolt-diff--compute-stats tables)))
      (should (= 2 (length stats)))
      (should (= 1 (plist-get (car stats) :added)))
      (should (= 1 (plist-get (cadr stats) :deleted))))))

;;;; Revision buffer improvements

(ert-deftest test-madolt-log-revision-shows-parent ()
  "Revision buffer should show parent hash."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "Second")
    (let* ((entries (madolt-log-entries 2))
           (newest (car entries))
           (hash (plist-get newest :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should (string-match-p "Parent:" text)))))))

(ert-deftest test-madolt-log-revision-shows-merge-parents ()
  "Revision buffer should show Merge: line for merge commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
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
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should (string-match-p "Merge:" text)))))))

(ert-deftest test-madolt-log-revision-shows-stat-summary ()
  "Revision buffer should show diff stat summary."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "add row")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          ;; Should show table name in stat
          (should (string-match-p "t1" text))
          ;; Should show row count stat
          (should (string-match-p "1 table changed" text))
          ;; Should show added count
          (should (string-match-p "1 added" text)))))))

(ert-deftest test-madolt-log-revision-full-message ()
  "Revision buffer should display the full commit message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First line of message")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should (string-match-p "First line of message" text)))))))

(ert-deftest test-madolt-log-revision-no-parent-for-initial ()
  "Revision buffer should not show Parent: for the initial commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    ;; Get the very first commit (init commits from dolt init + our commit)
    ;; Use the last entry to find one with no parent
    (let* ((entries (madolt-log-entries 100))
           ;; The last entry is the dolt init commit which has no parent
           (init-entry (car (last entries)))
           (hash (plist-get init-entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should-not (string-match-p "Parent:" text))
          (should-not (string-match-p "Merge:" text)))))))

(provide 'madolt-log-tests)
;;; madolt-log-tests.el ends here
