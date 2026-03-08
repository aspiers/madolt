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
    (dolist (arg '("--stat" "--merges"))
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

;;;; Branch name completion

(ert-deftest test-madolt-log-branch-names ()
  "madolt--branch-names should return branch names."
  (madolt-with-test-database
    (let ((names (madolt--branch-names)))
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

(provide 'madolt-log-tests)
;;; madolt-log-tests.el ends here
