;;; madolt-refs-tests.el --- Tests for madolt-refs.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt references buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'magit-section)
(require 'madolt)
(require 'madolt-refs)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-test-helpers)

;;;; Helper: collect sections of a given type from a buffer

(defun madolt-refs-test--sections-of-type (type)
  "Return a list of sections of TYPE in the current buffer."
  (let ((result nil))
    (when magit-root-section
      (madolt-test--walk-sections
       (lambda (s) (when (eq (oref s type) type) (push s result)))
       magit-root-section))
    (nreverse result)))

;;;; Mode

(ert-deftest test-madolt-refs-mode-derived ()
  "madolt-refs-mode should derive from madolt-mode."
  (should (eq (get 'madolt-refs-mode 'derived-mode-parent) 'madolt-mode)))

;;;; Transient

(ert-deftest test-madolt-show-refs-is-transient ()
  "madolt-show-refs should be a transient prefix."
  (should (get 'madolt-show-refs 'transient--layout)))

(ert-deftest test-madolt-show-refs-has-y-suffix ()
  "madolt-show-refs should have a \\='y\\=' suffix for HEAD."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-show-refs)))
    (should (assoc "y" suffixes))
    (should (eq (cdr (assoc "y" suffixes)) 'madolt-show-refs-head))))

(ert-deftest test-madolt-show-refs-has-c-suffix ()
  "madolt-show-refs should have a \\='c\\=' suffix for current branch."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-show-refs)))
    (should (assoc "c" suffixes))
    (should (eq (cdr (assoc "c" suffixes)) 'madolt-show-refs-current))))

(ert-deftest test-madolt-show-refs-has-o-suffix ()
  "madolt-show-refs should have an \\='o\\=' suffix for other branch."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-show-refs)))
    (should (assoc "o" suffixes))
    (should (eq (cdr (assoc "o" suffixes)) 'madolt-show-refs-other))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-show-refs ()
  "The mode map should bind \\='y\\=' to madolt-show-refs."
  (should (eq (keymap-lookup madolt-mode-map "y") #'madolt-show-refs)))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-show-refs ()
  "The dispatch menu has a \\='y\\=' binding for refs."
  ;; Walk the full layout including nested column groups
  (let* ((layout (get 'madolt-dispatch 'transient--layout))
         (found nil))
    (cl-labels
        ((walk (items)
           (dolist (item items)
             (cond
              ((vectorp item)
               (walk (append (aref item 2) nil)))
              ((and (listp item)
                    (equal (plist-get (cdr item) :key) "y"))
               (setq found (plist-get (cdr item) :command)))))))
      (dolist (group (aref layout 2))
        (when (vectorp group)
          (walk (append (aref group 2) nil)))))
    (should (eq found 'madolt-show-refs))))

;;;; Faces

(ert-deftest test-madolt-refs-faces-defined ()
  "All refs faces should be defined."
  (dolist (face '(madolt-branch-local
                  madolt-branch-remote
                  madolt-branch-current
                  madolt-tag))
    (should (facep face))))

;;;; Data functions

(ert-deftest test-madolt-branch-list-verbose ()
  "madolt-branch-list-verbose should return branch plists."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((branches (madolt-branch-list-verbose)))
      ;; Should have at least main
      (should (cl-some (lambda (b) (equal (plist-get b :name) "main"))
                       branches))
      ;; Current branch should be marked
      (let ((main (cl-find-if (lambda (b) (equal (plist-get b :name) "main"))
                              branches)))
        (should (plist-get main :current))
        (should (stringp (plist-get main :hash)))
        (should (stringp (plist-get main :message)))))))

(ert-deftest test-madolt-branch-list-verbose-multiple ()
  "madolt-branch-list-verbose should list multiple branches."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (let ((branches (madolt-branch-list-verbose)))
      (should (>= (length branches) 2))
      (should (cl-some (lambda (b) (equal (plist-get b :name) "feature"))
                       branches)))))

(ert-deftest test-madolt-tag-list-verbose ()
  "madolt-tag-list-verbose should return tag plists."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0" nil "Test tag")
    (let ((tags (madolt-tag-list-verbose)))
      (should (= 1 (length tags)))
      (let ((tag (car tags)))
        (should (equal (plist-get tag :name) "v1.0"))
        (should (stringp (plist-get tag :hash)))))))

(ert-deftest test-madolt-tag-list-verbose-empty ()
  "madolt-tag-list-verbose should return nil with no tags."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (should-not (madolt-tag-list-verbose))))

;;;; Refs buffer rendering

(ert-deftest test-madolt-refs-refresh-shows-branches ()
  "Refs buffer should show branch sections."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Branches" text))
        (should (string-match-p "main" text))
        (should (string-match-p "feature" text))))))

(ert-deftest test-madolt-refs-current-branch-marked ()
  "Current branch should have * marker."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^\\* main" text))))))

(ert-deftest test-madolt-refs-shows-tags ()
  "Refs buffer should show tags when they exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0" nil "Test tag")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Tags" text))
        (should (string-match-p "v1.0" text))))))

(ert-deftest test-madolt-refs-no-tags-section-when-empty ()
  "Tags section should not appear when there are no tags."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not (string-match-p "Tags" text))))))

(ert-deftest test-madolt-refs-heading ()
  "Refs buffer should show heading with upstream reference."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "main")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "References for main:" text))))))

(ert-deftest test-madolt-refs-branch-sections ()
  "Each branch should be a section with the branch name as value."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((branch-sections (madolt-refs-test--sections-of-type 'branch)))
        (should (>= (length branch-sections) 2))
        (should (cl-some (lambda (s) (equal (oref s value) "main"))
                         branch-sections))
        (should (cl-some (lambda (s) (equal (oref s value) "feature"))
                         branch-sections))))))

(provide 'madolt-refs-tests)
;;; madolt-refs-tests.el ends here
