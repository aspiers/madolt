;;; madolt-apply-tests.el --- Tests for madolt-apply.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the stage, unstage, and discard operations.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt-test-helpers)
(require 'madolt-status)
(require 'madolt-apply)

;;;; Helpers

(defun madolt-test--find-section (type &optional value root)
  "Find a section of TYPE with optional VALUE under ROOT.
ROOT defaults to `magit-root-section'."
  (let ((root (or root magit-root-section))
        (found nil))
    (madolt-test--walk-sections
     (lambda (s)
       (when (and (not found)
                  (eq (oref s type) type)
                  (or (null value)
                      (equal (oref s value) value)))
         (setq found s)))
     root)
    found))

(defun madolt-test--goto-section (type &optional value)
  "Move point to the start of a section of TYPE with optional VALUE."
  (let ((section (madolt-test--find-section type value)))
    (when section
      (goto-char (oref section start)))
    section))

(defun madolt-test--dolt-status-tables ()
  "Return the current dolt status tables alist."
  (madolt-status-tables))

(defmacro madolt-with-status-buffer (&rest body)
  "Render a status buffer for the current test database and run BODY.
The buffer is current during BODY and killed afterward."
  (declare (indent 0) (debug t))
  `(let ((buf (madolt-setup-buffer 'madolt-status-mode)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (kill-buffer buf))))

;;;; madolt-stage

(ert-deftest test-madolt-stage-table-at-point ()
  "Staging an unstaged table moves it to staged."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; products is unstaged; navigate to it and stage
      (let ((section (madolt-test--goto-section 'table "products")))
        (should section)
        (should (eq (oref (oref section parent) type) 'unstaged))
        (madolt-stage))
      ;; Verify products is now staged
      (let ((tables (madolt-test--dolt-status-tables)))
        (should (assoc "products" (alist-get 'staged tables)))
        (should-not (assoc "products" (alist-get 'unstaged tables)))))))

(ert-deftest test-madolt-stage-untracked-at-point ()
  "Staging an untracked table stages it."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; inventory is untracked
      (let ((section (madolt-test--goto-section 'table "inventory")))
        (should section)
        (should (eq (oref (oref section parent) type) 'untracked))
        (madolt-stage))
      (let ((tables (madolt-test--dolt-status-tables)))
        (should (assoc "inventory" (alist-get 'staged tables)))
        (should-not (assoc "inventory" (alist-get 'untracked tables)))))))

(ert-deftest test-madolt-stage-on-section-heading ()
  "Staging on the unstaged heading stages all unstaged tables."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (madolt-test--goto-section 'unstaged))
      (madolt-stage)
      (let ((tables (madolt-test--dolt-status-tables)))
        ;; products was the only unstaged table; should now be staged
        (should-not (alist-get 'unstaged tables))))))

;;;; madolt-stage-all

(ert-deftest test-madolt-stage-all-stages-everything ()
  "Stage-all stages all unstaged and untracked tables."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (madolt-stage-all)
      (let ((tables (madolt-test--dolt-status-tables)))
        ;; Everything should be staged
        (should-not (alist-get 'unstaged tables))
        (should-not (alist-get 'untracked tables))))))

(ert-deftest test-madolt-stage-all-no-op-when-clean ()
  "Stage-all does not error when nothing to stage."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      ;; Should not error
      (madolt-stage-all))))

;;;; madolt-unstage

(ert-deftest test-madolt-unstage-table-at-point ()
  "Unstaging a staged table moves it back."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; users is staged; navigate to it under staged section
      (let ((section (madolt-test--goto-section 'table "users")))
        (should section)
        (should (eq (oref (oref section parent) type) 'staged))
        (madolt-unstage))
      (let ((tables (madolt-test--dolt-status-tables)))
        (should-not (assoc "users" (alist-get 'staged tables)))
        (should (assoc "users" (alist-get 'unstaged tables)))))))

(ert-deftest test-madolt-unstage-on-section-heading ()
  "Unstaging on the staged heading unstages all."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (madolt-test--goto-section 'staged))
      (madolt-unstage)
      (let ((tables (madolt-test--dolt-status-tables)))
        (should-not (alist-get 'staged tables))))))

;;;; madolt-unstage-all

(ert-deftest test-madolt-unstage-all-unstages-everything ()
  "Unstage-all unstages all staged tables."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    ;; Stage everything first
    (call-process madolt-dolt-executable nil nil nil "add" ".")
    (madolt-with-status-buffer
      (madolt-unstage-all)
      (let ((tables (madolt-test--dolt-status-tables)))
        (should-not (alist-get 'staged tables))))))

(ert-deftest test-madolt-unstage-all-no-op-when-empty ()
  "Unstage-all does not error when nothing staged."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (madolt-unstage-all))))

;;;; madolt-discard

(ert-deftest test-madolt-discard-reverts-changes ()
  "Discard reverts changes to the table at point."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; products is unstaged modified; navigate to it
      (let ((section (madolt-test--goto-section 'table "products")))
        (should section)
        (should (eq (oref (oref section parent) type) 'unstaged))
        ;; Override y-or-n-p to always confirm
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (madolt-discard)))
      ;; products should no longer appear in unstaged
      (let ((tables (madolt-test--dolt-status-tables)))
        (should-not (assoc "products" (alist-get 'unstaged tables)))))))

(ert-deftest test-madolt-discard-prompts-confirmation ()
  "Discard prompts for confirmation before proceeding."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((prompted nil))
        (madolt-test--goto-section 'table "products")
        ;; Override y-or-n-p to record it was called and decline
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (setq prompted t) nil)))
          (madolt-discard))
        (should prompted)
        ;; products should still be unstaged (discard was declined)
        (let ((tables (madolt-test--dolt-status-tables)))
          (should (assoc "products" (alist-get 'unstaged tables))))))))

;;;; Buffer refresh

(ert-deftest test-madolt-stage-refreshes-buffer ()
  "After staging, the status buffer is refreshed."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; Before: products is under unstaged
      (should (string-match-p "Unstaged changes" (buffer-string)))
      (madolt-test--goto-section 'table "products")
      (madolt-stage)
      ;; After: products should appear under staged (buffer refreshed)
      (let ((text (buffer-string)))
        (should (string-match-p "Staged changes" text))))))

(ert-deftest test-madolt-unstage-refreshes-buffer ()
  "After unstaging, the status buffer is refreshed."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; Before: users is under staged (match exactly, not "Unstaged")
      (should (madolt-test--find-section 'staged))
      (madolt-test--goto-section 'table "users")
      (madolt-unstage)
      ;; After: staged section should disappear (only users was staged)
      (should-not (madolt-test--find-section 'staged)))))

(provide 'madolt-apply-tests)
;;; madolt-apply-tests.el ends here
