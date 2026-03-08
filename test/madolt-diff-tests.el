;;; madolt-diff-tests.el --- Tests for madolt-diff.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt tabular diff viewer.

;;; Code:

(require 'ert)
(require 'magit-section)
(require 'madolt-diff)
(require 'madolt-mode)
(require 'madolt-test-helpers)

;;;; Helper: collect sections of a given type from a buffer

(defun madolt-test--sections-of-type (type)
  "Return a list of sections of TYPE in the current buffer."
  (let ((result nil))
    (when magit-root-section
      (madolt-test--walk-sections
       (lambda (s) (when (eq (oref s type) type) (push s result)))
       magit-root-section))
    (nreverse result)))

;;;; Helper: set up a test database with known diff state

(defun madolt-test-setup-diff-db ()
  "Set up a database with committed data and uncommitted changes.
Creates table `items' with rows (1,Alice,alice@ex.com), (2,Bob,bob@ex.com).
Then modifies id=1 email, adds id=3, deletes id=2.  Nothing is staged."
  (madolt-test-create-table
   "items" "id INT PRIMARY KEY, name VARCHAR(100), email VARCHAR(200)")
  (madolt-test-insert-row "items" "(1, 'Alice', 'alice@ex.com')")
  (madolt-test-insert-row "items" "(2, 'Bob', 'bob@ex.com')")
  (madolt-test-commit "Initial items")
  ;; Modify
  (madolt-test-update-row "items" "email = 'alice_new@ex.com'" "id = 1")
  ;; Add
  (madolt-test-insert-row "items" "(3, 'Charlie', 'charlie@ex.com')")
  ;; Delete
  (madolt-test-delete-row "items" "id = 2"))

;;;; Faces

(ert-deftest test-madolt-diff-faces-defined ()
  "All documented diff faces should be defined."
  (dolist (face '(madolt-diff-added
                  madolt-diff-removed
                  madolt-diff-old
                  madolt-diff-new
                  madolt-diff-changed-cell
                  madolt-diff-context
                  madolt-diff-schema
                  madolt-diff-table-heading
                  madolt-diff-column-header))
    (should (facep face))))

;;;; Transient

(ert-deftest test-madolt-diff-is-transient ()
  "madolt-diff should be a transient prefix."
  (should (get 'madolt-diff 'transient--layout)))

(ert-deftest test-madolt-diff-has-suffixes ()
  "madolt-diff should have the documented suffix keys."
  (let* ((layout (get 'madolt-diff 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      ;; Each group is [CLASS PLIST SUFFIXES] where SUFFIXES is a list
      ;; of plists like (CLASS :key KEY :description DESC ...)
      (let ((suffixes (aref group 2)))
        (dolist (suffix suffixes)
          (when (listp suffix)
            (let ((key (plist-get (cdr suffix) :key)))
              (when key (push key all-keys)))))))
    (dolist (key '("d" "s" "c" "t" "r"))
      (should (member key all-keys)))))

;;;; Row change type detection

(ert-deftest test-madolt-diff-row-change-type-added ()
  "Should detect added rows (from_row empty, to_row present)."
  (let ((row '((from_row) (to_row (id . 1) (name . "Alice")))))
    (should (eq (madolt-diff--row-change-type row) 'added))))

(ert-deftest test-madolt-diff-row-change-type-deleted ()
  "Should detect deleted rows (from_row present, to_row empty)."
  (let ((row '((from_row (id . 1) (name . "Alice")) (to_row))))
    (should (eq (madolt-diff--row-change-type row) 'deleted))))

(ert-deftest test-madolt-diff-row-change-type-modified ()
  "Should detect modified rows (both present with different values)."
  (let ((row '((from_row (id . 1) (name . "Alice"))
               (to_row (id . 1) (name . "Bob")))))
    (should (eq (madolt-diff--row-change-type row) 'modified))))

;;;; Row summary formatting

(ert-deftest test-madolt-diff-row-summary-added ()
  "Added row summary should start with + and show field values."
  (let ((row '((from_row) (to_row (id . 3) (name . "Charlie")))))
    (let ((summary (madolt-diff--row-summary row 'added)))
      (should (string-prefix-p "+" summary))
      (should (string-match-p "id=3" summary))
      (should (string-match-p "name=Charlie" summary)))))

(ert-deftest test-madolt-diff-row-summary-deleted ()
  "Deleted row summary should start with - and show field values."
  (let ((row '((from_row (id . 2) (name . "Bob")) (to_row))))
    (let ((summary (madolt-diff--row-summary row 'deleted)))
      (should (string-prefix-p "-" summary))
      (should (string-match-p "id=2" summary)))))

(ert-deftest test-madolt-diff-row-summary-modified ()
  "Modified row summary should start with ~ and show changed cell count."
  (let ((row '((from_row (id . 1) (name . "Alice") (email . "old@ex.com"))
               (to_row (id . 1) (name . "Alice") (email . "new@ex.com")))))
    (let ((summary (madolt-diff--row-summary row 'modified)))
      (should (string-prefix-p "~" summary))
      (should (string-match-p "1 cell changed" summary)))))

;;;; Changed cell count

(ert-deftest test-madolt-diff-changed-cell-count ()
  "Should count only the cells that differ."
  (let ((from '((id . 1) (name . "Alice") (email . "old@ex.com")))
        (to   '((id . 1) (name . "Alice") (email . "new@ex.com"))))
    (should (= (madolt-diff--changed-cell-count from to) 1))))

(ert-deftest test-madolt-diff-changed-cell-count-all ()
  "Should count all cells when all differ."
  (let ((from '((id . 1) (name . "Alice")))
        (to   '((id . 2) (name . "Bob"))))
    (should (= (madolt-diff--changed-cell-count from to) 2))))

;;;; Raw line propertization

(ert-deftest test-madolt-diff-raw-line-added ()
  "Added row lines should get madolt-diff-added face."
  (let ((line "| + | 3  | Charlie | charlie@ex.com |"))
    (let ((result (madolt-diff--propertize-raw-line line)))
      (should (eq (get-text-property 0 'font-lock-face result)
                  'madolt-diff-added)))))

(ert-deftest test-madolt-diff-raw-line-removed ()
  "Deleted row lines should get madolt-diff-removed face."
  (let ((line "| - | 2  | Bob     | bob@ex.com     |"))
    (let ((result (madolt-diff--propertize-raw-line line)))
      (should (eq (get-text-property 0 'font-lock-face result)
                  'madolt-diff-removed)))))

(ert-deftest test-madolt-diff-raw-line-old ()
  "Old-value lines should get madolt-diff-old face."
  (let ((line "| < | 1  | Alice   | old@ex.com     |"))
    (let ((result (madolt-diff--propertize-raw-line line)))
      (should (eq (get-text-property 0 'font-lock-face result)
                  'madolt-diff-old)))))

(ert-deftest test-madolt-diff-raw-line-new ()
  "New-value lines should get madolt-diff-new face."
  (let ((line "| > | 1  | Alice   | new@ex.com     |"))
    (let ((result (madolt-diff--propertize-raw-line line)))
      (should (eq (get-text-property 0 'font-lock-face result)
                  'madolt-diff-new)))))

(ert-deftest test-madolt-diff-raw-line-header ()
  "diff --dolt header should get madolt-diff-table-heading face."
  (let ((line "diff --dolt a/items b/items"))
    (let ((result (madolt-diff--propertize-raw-line line)))
      (should (eq (get-text-property 0 'font-lock-face result)
                  'madolt-diff-table-heading)))))

(ert-deftest test-madolt-diff-raw-line-column-header ()
  "Column header lines should get madolt-diff-column-header face."
  (let ((line "|   | id | name    | email           |"))
    (let ((result (madolt-diff--propertize-raw-line line)))
      (should (eq (get-text-property 0 'font-lock-face result)
                  'madolt-diff-column-header)))))

;;;; Raw table splitting

(ert-deftest test-madolt-diff-split-raw-tables ()
  "Should split raw output into per-table blocks."
  (let ((output "diff --dolt a/foo b/foo\n--- a/foo\n+++ b/foo\ndata1\ndiff --dolt a/bar b/bar\n--- a/bar\n+++ b/bar\ndata2"))
    (let ((blocks (madolt-diff--split-raw-tables output)))
      (should (= (length blocks) 2))
      (should (equal (car (nth 0 blocks)) "foo"))
      (should (equal (car (nth 1 blocks)) "bar")))))

;;;; Table name completion

(ert-deftest test-madolt-diff-table-names ()
  "madolt--table-names should return table names from dolt ls."
  (madolt-with-test-database
    (madolt-test-create-table "alpha" "id INT PRIMARY KEY")
    (madolt-test-create-table "beta" "id INT PRIMARY KEY")
    (let ((names (madolt--table-names)))
      (should (member "alpha" names))
      (should (member "beta" names))
      ;; Should not include the header line
      (should-not (cl-find-if
                   (lambda (n) (string-match-p "Tables" n))
                   names)))))

;;;; Structured mode with real dolt database

(ert-deftest test-madolt-diff-structured-row-types ()
  "Structured diff should detect added, modified, and deleted rows."
  (madolt-with-test-database
    (madolt-test-setup-diff-db)
    (let* ((json (madolt-diff-json))
           (tables (alist-get 'tables json))
           (tbl (car tables))
           (data-diff (alist-get 'data_diff tbl))
           (types (mapcar #'madolt-diff--row-change-type data-diff)))
      (should (memq 'added types))
      (should (memq 'modified types))
      (should (memq 'deleted types)))))

(ert-deftest test-madolt-diff-structured-renders-sections ()
  "Structured diff should produce table-diff and row-diff sections."
  (madolt-with-test-database
    (madolt-test-setup-diff-db)
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (madolt-diff--refresh-structured))
      ;; Should have table-diff sections
      (let ((table-sections (madolt-test--sections-of-type 'table-diff)))
        (should (>= (length table-sections) 1)))
      ;; Should have row-diff sections
      (let ((row-sections (madolt-test--sections-of-type 'row-diff)))
        (should (>= (length row-sections) 3))))))

(ert-deftest test-madolt-diff-structured-no-diff ()
  "Structured diff should show 'No differences' when clean."
  (madolt-with-test-database
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (madolt-diff--refresh-structured))
      (should (string-match-p "No differences"
                              (buffer-substring-no-properties
                               (point-min) (point-max)))))))

(ert-deftest test-madolt-diff-staged-only ()
  "Staged diff should only show staged changes."
  (madolt-with-test-database
    ;; Set up: two committed tables
    (madolt-test-create-table "items" "id INT PRIMARY KEY, name VARCHAR(100)")
    (madolt-test-insert-row "items" "(1, 'Alice')")
    (madolt-test-create-table "other" "id INT PRIMARY KEY, val TEXT")
    (madolt-test-insert-row "other" "(1, 'hello')")
    (madolt-test-commit "Initial")
    ;; Modify both tables
    (madolt-test-update-row "items" "name = 'Bob'" "id = 1")
    (madolt-test-update-row "other" "val = 'world'" "id = 1")
    ;; Stage only items
    (madolt-test-stage-table "items")
    ;; Staged diff should show items but not other
    (let* ((json (madolt-diff-json "--staged"))
           (tables (alist-get 'tables json))
           (names (mapcar (lambda (t) (alist-get 'name t)) tables)))
      (should (member "items" names))
      (should-not (member "other" names)))))

;;;; Raw mode with real dolt database

(ert-deftest test-madolt-diff-raw-renders-sections ()
  "Raw mode should produce table-diff sections with faces."
  (madolt-with-test-database
    (madolt-test-setup-diff-db)
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t)
            (madolt-diff-raw-mode t))
        (madolt-diff--refresh-raw))
      ;; Should have table-diff sections
      (let ((table-sections (madolt-test--sections-of-type 'table-diff)))
        (should (>= (length table-sections) 1)))
      ;; Should contain raw markers in the output
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Should have some row markers
        (should (or (string-match-p "| < |" text)
                    (string-match-p "| > |" text)
                    (string-match-p "| \\+ |" text)
                    (string-match-p "| - |" text)))))))

(ert-deftest test-madolt-diff-raw-no-diff ()
  "Raw mode should show 'No differences' when clean."
  (madolt-with-test-database
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t)
            (madolt-diff-raw-mode t))
        (madolt-diff--refresh-raw))
      (should (string-match-p "No differences"
                              (buffer-substring-no-properties
                               (point-min) (point-max)))))))

;;;; Inline diff for status buffer

(ert-deftest test-madolt-diff-insert-table-at-point ()
  "madolt-diff-insert-table should insert row summaries for a table."
  (madolt-with-test-database
    (madolt-test-setup-diff-db)
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (magit-insert-section (root)
          (madolt-diff-insert-table "items")))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Should contain row change indicators
        (should (or (string-match-p "\\+" text)
                    (string-match-p "~" text)
                    (string-match-p "-" text)))))))

(ert-deftest test-madolt-diff-insert-table-creates-row-sections ()
  "madolt-diff-insert-table should create row-diff sections."
  (madolt-with-test-database
    (madolt-test-setup-diff-db)
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (magit-insert-section (root)
          (madolt-diff-insert-table "items")))
      ;; Should have row-diff sections
      (let ((row-sections (madolt-test--sections-of-type 'row-diff)))
        (should (>= (length row-sections) 3))))))

(ert-deftest test-madolt-diff-insert-table-row-details-hidden ()
  "Row-diff sections should start hidden (collapsed at level 3)."
  (madolt-with-test-database
    (madolt-test-setup-diff-db)
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (magit-insert-section (root)
          (madolt-diff-insert-table "items")))
      (let ((row-sections (madolt-test--sections-of-type 'row-diff)))
        (should (>= (length row-sections) 1))
        ;; Each row-diff section should be initially hidden
        (dolist (sec row-sections)
          (should (oref sec hidden)))))))

(ert-deftest test-madolt-diff-insert-table-no-changes ()
  "madolt-diff-insert-table should handle a table with no changes."
  (madolt-with-test-database
    (madolt-test-create-table "clean_tbl" "id INT PRIMARY KEY")
    (madolt-test-insert-row "clean_tbl" "(1)")
    (madolt-test-commit "committed")
    ;; No changes to clean_tbl
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (madolt-diff-insert-table "clean_tbl"))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "no changes" text))))))

;;;; Build args

(ert-deftest test-madolt-diff-build-args-staged ()
  "Build args should include --staged when staged is set."
  (with-temp-buffer
    (setq madolt-diff--staged t)
    (setq madolt-diff-args nil)
    (setq madolt-diff--revisions nil)
    (setq madolt-diff--table nil)
    (let ((args (madolt-diff--build-args)))
      (should (member "--staged" args)))))

(ert-deftest test-madolt-diff-build-args-revisions ()
  "Build args should include revision pair when set."
  (with-temp-buffer
    (setq madolt-diff--staged nil)
    (setq madolt-diff-args nil)
    (setq madolt-diff--revisions (cons "abc123" "def456"))
    (setq madolt-diff--table nil)
    (let ((args (madolt-diff--build-args)))
      (should (member "abc123" args))
      (should (member "def456" args)))))

(ert-deftest test-madolt-diff-build-args-table ()
  "Build args should include table name when set."
  (with-temp-buffer
    (setq madolt-diff--staged nil)
    (setq madolt-diff-args nil)
    (setq madolt-diff--revisions nil)
    (setq madolt-diff--table "users")
    (let ((args (madolt-diff--build-args)))
      (should (member "users" args)))))

;;;; Schema indentation

(ert-deftest test-madolt-diff-schema-indentation ()
  "Multi-line schema statements should be indented on every line."
  (with-temp-buffer
    (magit-section-mode)
    (let ((inhibit-read-only t)
          (table-data `((name . "test_table")
                        (schema_diff "CREATE TABLE `t` (\n  `id` int,\n  `name` text\n);")
                        (data_diff))))
      (magit-insert-section (root)
        (madolt-diff--insert-table-diff table-data))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Every non-empty line of the schema should start with 4 spaces
        (dolist (line (split-string text "\n" t))
          (when (string-match-p "`" line)
            (should (string-match-p "^    " line))))))))

(provide 'madolt-diff-tests)
;;; madolt-diff-tests.el ends here
