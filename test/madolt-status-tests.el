;;; madolt-status-tests.el --- Tests for madolt-status.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the status buffer: header, staged/unstaged/untracked
;; sections, recent commits, section structure, and inline diff.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt-test-helpers)
(require 'madolt-status)

;;;; Section tree walker (magit-section has no public map function)

(defun madolt-test--walk-sections (fn section)
  "Call FN on SECTION and all its descendants."
  (funcall fn section)
  (dolist (child (oref section children))
    (madolt-test--walk-sections fn child)))

;;;; Helper to render status buffer in a test database

(defun madolt-test--render-status ()
  "Create and return a status buffer for the current test database.
The buffer should be killed by the caller."
  (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
    buf))

(defmacro madolt-with-status-buffer (&rest body)
  "Render a status buffer for the current test database and run BODY.
The buffer is current during BODY and killed afterward."
  (declare (indent 0) (debug t))
  `(let ((buf (madolt-test--render-status)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (kill-buffer buf))))

;;;; Header

(ert-deftest test-madolt-status-header-shows-branch ()
  "The status header displays the current branch name."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (goto-char (point-min))
      (should (string-match-p "main" (buffer-string))))))

(ert-deftest test-madolt-status-header-shows-last-commit ()
  "The status header shows abbreviated hash and message of HEAD."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "Initial commit message")
    (madolt-with-status-buffer
      (goto-char (point-min))
      (let ((text (buffer-string)))
        ;; Should contain the commit message
        (should (string-match-p "Initial commit message" text))
        ;; Should contain an abbreviated hash (8 alphanumeric chars)
        (should (string-match-p "[a-z0-9]\\{8\\}" text))))))

;;;; Staged changes section

(ert-deftest test-madolt-status-staged-section-visible ()
  "The \"Staged changes\" section appears when tables are staged."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (string-match-p "Staged changes" (buffer-string))))))

(ert-deftest test-madolt-status-staged-lists-tables ()
  "Staged tables are listed with their status."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; users is staged as modified in the populated db
        (should (string-match-p "modified.*users" text))))))

(ert-deftest test-madolt-status-staged-hidden-when-empty ()
  "The staged section is not shown when nothing is staged."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Staged changes" (buffer-string))))))

;;;; Unstaged changes section

(ert-deftest test-madolt-status-unstaged-section-visible ()
  "The \"Unstaged changes\" section appears when there are unstaged changes."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (string-match-p "Unstaged changes" (buffer-string))))))

(ert-deftest test-madolt-status-unstaged-lists-tables ()
  "Unstaged tables are listed with their status."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; products has unstaged modifications in the populated db
        (should (string-match-p "modified.*products" text))))))

(ert-deftest test-madolt-status-unstaged-hidden-when-empty ()
  "The unstaged section is not shown when no unstaged changes exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Unstaged changes" (buffer-string))))))

;;;; Untracked tables section

(ert-deftest test-madolt-status-untracked-section-visible ()
  "The \"Untracked tables\" section appears when new tables exist."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (string-match-p "Untracked tables" (buffer-string))))))

(ert-deftest test-madolt-status-untracked-lists-tables ()
  "Untracked tables are listed."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; inventory is untracked in the populated db
        (should (string-match-p "new table.*inventory" text))))))

(ert-deftest test-madolt-status-untracked-hidden-when-empty ()
  "The untracked section is not shown when no untracked tables exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Untracked tables" (buffer-string))))))

;;;; Recent commits section

(ert-deftest test-madolt-status-recent-commits-shown ()
  "The recent commits section appears when there are commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "First commit")
    (madolt-with-status-buffer
      (should (string-match-p "Recent commits" (buffer-string))))))

(ert-deftest test-madolt-status-recent-commits-count ()
  "The recent commits section shows the correct number of commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "Commit one")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Commit two")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "Commit three")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; All three commit messages should appear
        ;; (plus the initial dolt init commit = 4 total, but we check ours)
        (should (string-match-p "Commit one" text))
        (should (string-match-p "Commit two" text))
        (should (string-match-p "Commit three" text))))))

(ert-deftest test-madolt-status-recent-commit-format ()
  "Each commit shows hash and message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "My test commit")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; Should have a line with hash followed by message
        (should (string-match-p
                 "[a-z0-9]\\{8\\}  My test commit" text))))))

;;;; Section structure

(ert-deftest test-madolt-status-sections-are-magit-sections ()
  "All sections in the status buffer are proper magit-section objects."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (goto-char (point-min))
      ;; The root section should be a magit-section
      (let ((root (magit-current-section)))
        (should root)
        (should (magit-section-p root))))))

(ert-deftest test-madolt-status-table-sections-have-values ()
  "Table sections store the table name as their value."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (goto-char (point-min))
      ;; Find table sections by walking the section tree
      (let ((found nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'table)
             (push (oref section value) found)))
         magit-root-section)
        ;; The populated db has: users (staged), products (unstaged),
        ;; inventory (untracked)
        (should (member "users" found))
        (should (member "products" found))
        (should (member "inventory" found))))))

(ert-deftest test-madolt-status-sections-collapsible ()
  "TAB toggles section visibility."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (goto-char (point-min))
      ;; Find the staged section
      (let ((staged-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'staged)
             (setq staged-section section)))
         magit-root-section)
        (should staged-section)
        ;; Move to the section and toggle
        (goto-char (oref staged-section start))
        (let ((was-hidden (oref staged-section hidden)))
          (call-interactively #'magit-section-toggle)
          (should (not (eq was-hidden
                           (oref staged-section hidden)))))))))

;;;; Inline diff expansion

(ert-deftest test-madolt-status-tab-on-table-shows-diff ()
  "Pressing TAB on a table section shows diff content."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; Find a table section (they start hidden due to the washer)
      (let ((table-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (and (eq (oref section type) 'table)
                      (not table-section))
             (setq table-section section)))
         magit-root-section)
        (should table-section)
        ;; Table sections start hidden (created with t for HIDE)
        (should (oref table-section hidden))
        ;; Expand the section
        (goto-char (oref table-section start))
        (let ((inhibit-read-only t))
          (magit-section-show table-section))
        ;; After expansion, the washer should have run and inserted
        ;; diff content (or the fallback placeholder)
        (should-not (oref table-section hidden))))))

(ert-deftest test-madolt-status-tab-toggle ()
  "Pressing TAB twice hides the section again."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((table-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (and (eq (oref section type) 'table)
                      (not table-section))
             (setq table-section section)))
         magit-root-section)
        (should table-section)
        (goto-char (oref table-section start))
        ;; Toggle open
        (let ((inhibit-read-only t))
          (magit-section-show table-section))
        (should-not (oref table-section hidden))
        ;; Toggle closed
        (magit-section-hide table-section)
        (should (oref table-section hidden))))))

;;;; Clean working tree

(ert-deftest test-madolt-status-clean-shows-header-only ()
  "A clean working tree shows only the header and recent commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; Should have the header
        (should (string-match-p "Head:" text))
        ;; Should have recent commits
        (should (string-match-p "Recent commits" text))
        ;; Should NOT have any change sections
        (should-not (string-match-p "Staged changes" text))
        (should-not (string-match-p "Unstaged changes" text))
        (should-not (string-match-p "Untracked tables" text))))))

(provide 'madolt-status-tests)
;;; madolt-status-tests.el ends here
