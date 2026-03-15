;;; madolt-tag-tests.el --- Tests for madolt-tag.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt tag transient and tag commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-tag)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-tag-is-transient ()
  "madolt-tag should be a transient prefix."
  (should (get 'madolt-tag 'transient--layout)))

(ert-deftest test-madolt-tag-has-create-suffix ()
  "madolt-tag should have a 't' suffix for create."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-tag)))
    (should (assoc "t" suffixes))
    (should (eq (cdr (assoc "t" suffixes))
                'madolt-tag-create-command))))

(ert-deftest test-madolt-tag-has-delete-suffix ()
  "madolt-tag should have a 'k' suffix for delete."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-tag)))
    (should (assoc "k" suffixes))
    (should (eq (cdr (assoc "k" suffixes))
                'madolt-tag-delete-command))))

(ert-deftest test-madolt-tag-has-list-suffix ()
  "madolt-tag should have an 'l' suffix for list."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-tag)))
    (should (assoc "l" suffixes))
    (should (eq (cdr (assoc "l" suffixes))
                'madolt-tag-list-command))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-tag ()
  "The dispatch menu has a \"t\" binding for tag."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "t" suffixes))
    (should (eq (cdr (assoc "t" suffixes)) 'madolt-tag))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-tag ()
  "The mode map should bind 't' to madolt-tag."
  (should (eq (keymap-lookup madolt-mode-map "t") #'madolt-tag)))

;;;; Backend: madolt-tag-names

(ert-deftest test-madolt-tag-names-empty ()
  "madolt-tag-names should return nil when no tags exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (should (null (madolt-tag-names)))))

(ert-deftest test-madolt-tag-names-lists-tags ()
  "madolt-tag-names should return existing tags."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0")
    (let ((tags (madolt-tag-names)))
      (should (member "v1.0" tags)))))

;;;; Backend: madolt-tag-create

(ert-deftest test-madolt-tag-create-lightweight ()
  "madolt-tag-create should create a lightweight tag at HEAD."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((result (madolt-tag-create "v1.0")))
      (should (zerop (car result))))
    (should (member "v1.0" (madolt-tag-names)))))

(ert-deftest test-madolt-tag-create-at-ref ()
  "madolt-tag-create with ref should tag a specific commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "second")
    ;; Tag the first commit
    (let ((result (madolt-tag-create "v1.0" "HEAD~1")))
      (should (zerop (car result))))
    (should (member "v1.0" (madolt-tag-names)))))

(ert-deftest test-madolt-tag-create-annotated ()
  "madolt-tag-create with message should create an annotated tag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((result (madolt-tag-create "v1.0" nil "Release 1.0")))
      (should (zerop (car result))))
    (should (member "v1.0" (madolt-tag-names)))))

;;;; Backend: madolt-tag-delete

(ert-deftest test-madolt-tag-delete-removes-tag ()
  "madolt-tag-delete should remove an existing tag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0")
    (should (member "v1.0" (madolt-tag-names)))
    (let ((result (madolt-tag-delete "v1.0")))
      (should (zerop (car result))))
    (should-not (member "v1.0" (madolt-tag-names)))))

;;;; Interactive: create command

(ert-deftest test-madolt-tag-create-command-creates ()
  "madolt-tag-create-command should create a tag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'read-string) (lambda (&rest _) ""))
              ((symbol-function 'completing-read) (lambda (&rest _) "HEAD"))
              ((symbol-function 'madolt-branch-or-commit-at-point)
               (lambda () nil)))
      (madolt-tag-create-command "v2.0" nil))
    (should (member "v2.0" (madolt-tag-names)))))

(ert-deftest test-madolt-tag-create-command-empty-name-errors ()
  "madolt-tag-create-command with empty name should error."
  (madolt-with-test-database
    (should-error (madolt-tag-create-command "" nil)
                  :type 'user-error)))

(ert-deftest test-madolt-tag-create-command-with-message ()
  "madolt-tag-create-command with -m flag should create annotated tag."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'read-string) (lambda (&rest _) ""))
              ((symbol-function 'completing-read) (lambda (&rest _) "HEAD"))
              ((symbol-function 'madolt-branch-or-commit-at-point)
               (lambda () nil)))
      (madolt-tag-create-command "v3.0" '("-mRelease 3.0")))
    (should (member "v3.0" (madolt-tag-names)))))

;;;; Interactive: delete command

(ert-deftest test-madolt-tag-delete-command-deletes ()
  "madolt-tag-delete-command should delete a tag after confirmation."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (madolt-tag-delete-command "v1.0"))
    (should-not (member "v1.0" (madolt-tag-names)))))

(ert-deftest test-madolt-tag-delete-command-aborts-on-deny ()
  "madolt-tag-delete-command should not delete when user declines."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (madolt-tag-delete-command "v1.0"))
    (should (member "v1.0" (madolt-tag-names)))))

;;;; Interactive: list command

(ert-deftest test-madolt-tag-list-command-no-tags ()
  "madolt-tag-list-command with no tags should message 'No tags'."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let (msg)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (madolt-tag-list-command))
      (should (string= msg "No tags")))))

(ert-deftest test-madolt-tag-list-command-shows-tags ()
  "madolt-tag-list-command should list existing tags."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0")
    (madolt-tag-create "v2.0")
    (let (msg)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (madolt-tag-list-command))
      (should (string-match-p "v1\\.0" msg))
      (should (string-match-p "v2\\.0" msg)))))

;;;; Multiple tags

(ert-deftest test-madolt-tag-multiple-create-delete ()
  "Creating and deleting multiple tags should work correctly."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "alpha")
    (madolt-tag-create "beta")
    (madolt-tag-create "gamma")
    (should (= (length (madolt-tag-names)) 3))
    (madolt-tag-delete "beta")
    (let ((tags (madolt-tag-names)))
      (should (= (length tags) 2))
      (should (member "alpha" tags))
      (should-not (member "beta" tags))
      (should (member "gamma" tags)))))

(provide 'madolt-tag-tests)
;;; madolt-tag-tests.el ends here
