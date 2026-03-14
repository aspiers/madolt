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
                  madolt-branch-remote-head
                  madolt-branch-current
                  madolt-branch-upstream
                  madolt-branch-warning
                  madolt-tag
                  madolt-head))
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

(ert-deftest test-madolt-refs-current-branch-at-marker-for-head ()
  "Current branch should have @ marker when comparing against HEAD."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^@ main" text))))))

(ert-deftest test-madolt-refs-focus-star-marker-for-named-ref ()
  "Matching branch should have * marker when comparing against a named ref."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "main")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^\\* main" text))
        ;; feature should NOT have * since it's not the comparison target
        (should (string-match-p "^  feature" text))))))

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

(ert-deftest test-madolt-refs-header-line ()
  "Refs buffer should show comparison target in header-line-format."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "main")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      ;; header-line-format should contain comparison target
      (should (stringp header-line-format))
      (should (string-match-p "main"
                              (substring-no-properties
                               header-line-format))))))

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

;;;; Section type

(ert-deftest test-madolt-refs-root-section-is-branchbuf ()
  "Root section type should be branchbuf, matching magit convention."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (should magit-root-section)
      (should (eq (oref magit-root-section type) 'branchbuf)))))

;;;; Headings without colons

(ert-deftest test-madolt-refs-branches-heading-no-colon ()
  "Branches heading should not have a colon."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^Branches$" text))
        (should-not (string-match-p "Branches:" text))))))

(ert-deftest test-madolt-refs-tags-heading-no-colon ()
  "Tags heading should not have a colon."
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
        (should (string-match-p "^Tags$" text))
        (should-not (string-match-p "Tags:" text))))))

;;;; Cherry commits

(ert-deftest test-madolt-refs-cherry-commits-expandable ()
  "Branch sections should have a washer for cherry commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-branch-create "feature")
    (madolt-branch-checkout "feature")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "feature commit")
    (madolt-branch-checkout "main")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "main")
      (let ((inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      ;; Branch sections should be expandable (have a washer for lazy content)
      (let ((branch-sections (madolt-refs-test--sections-of-type 'branch)))
        ;; feature branch should have a washer
        (let ((feature (cl-find-if
                        (lambda (s) (equal (oref s value) "feature"))
                        branch-sections)))
          (should feature)
          ;; Section starts hidden and has a washer for deferred content
          (should (oref feature hidden))
          (should (oref feature washer)))))))

;;;; Visibility cache

(ert-deftest test-madolt-refs-visibility-cache-preserved ()
  "Section visibility cache should be preserved on buffer kill."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((buf (generate-new-buffer "test-refs-cache")))
      (with-current-buffer buf
        (madolt-refs-mode)
        (setq madolt-buffer-database-dir default-directory)
        (setq magit-section-visibility-cache
              '(((branch . "main") . hide)))
        (kill-buffer buf))
      ;; Cache should be stored in the global hash
      (should (gethash default-directory
                       madolt-refs--visibility-caches)))))

(ert-deftest test-madolt-refs-visibility-cache-restored ()
  "Section visibility cache should be restored in new buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Pre-populate the cache
    (puthash default-directory
             '(((branch . "main") . hide))
             madolt-refs--visibility-caches)
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-buffer-database-dir default-directory)
      (madolt-refs--restore-visibility-cache)
      (should (equal magit-section-visibility-cache
                     '(((branch . "main") . hide)))))))

;;;; Focus column

(ert-deftest test-madolt-refs-focus-column-at-for-head ()
  "Focus column should use @ for current branch when upstream is HEAD."
  (let ((madolt-refs--upstream "HEAD"))
    (should (equal (substring-no-properties
                    (madolt-refs--format-focus-column t "main"))
                   "@ "))))

(ert-deftest test-madolt-refs-focus-column-star-for-named ()
  "Focus column should use * for matching branch when upstream is named."
  (let ((madolt-refs--upstream "main"))
    (should (equal (substring-no-properties
                    (madolt-refs--format-focus-column nil "main"))
                   "* "))))

(ert-deftest test-madolt-refs-focus-column-space-for-other ()
  "Focus column should use space for non-matching branches."
  (let ((madolt-refs--upstream "HEAD"))
    (should (equal (madolt-refs--format-focus-column nil "feature")
                   "  "))))

;;;; Margin

(ert-deftest test-madolt-refs-margin-default-inactive ()
  "Margin should be inactive by default."
  (let ((madolt-refs-margin '(nil age 18 t 18)))
    (with-temp-buffer
      (madolt-refs-mode)
      (madolt-refs--setup-margin)
      (should-not (madolt-refs--margin-active-p)))))

(ert-deftest test-madolt-refs-margin-active-when-enabled ()
  "Margin should be active when INIT is t."
  (let ((madolt-refs-margin '(t age 18 t 18)))
    (with-temp-buffer
      (madolt-refs-mode)
      (madolt-refs--setup-margin)
      (should (madolt-refs--margin-active-p)))))

(ert-deftest test-madolt-refs-format-age ()
  "Age formatting should produce reasonable output."
  (let* ((now (float-time))
         (two-days-ago (- now (* 2 86400))))
    (should (equal (madolt-refs--format-age two-days-ago) "2 days"))
    (should (equal (madolt-refs--format-age two-days-ago t) "2d"))))

(ert-deftest test-madolt-refs-format-margin-string-age ()
  "Margin string should format age style correctly."
  (let* ((madolt-refs--margin-config '(t age 18 nil 18))
         (now (float-time))
         (two-days-ago (- now (* 2 86400)))
         (result (madolt-refs--format-margin-string
                  "Alice" (number-to-string two-days-ago))))
    ;; Should contain "2 days" but NOT "Alice" (author disabled)
    (should (string-match-p "2 days" (substring-no-properties result)))))

(ert-deftest test-madolt-refs-format-margin-string-with-author ()
  "Margin string should include author when enabled."
  (let* ((madolt-refs--margin-config '(t age 18 t 18))
         (now (float-time))
         (two-days-ago (- now (* 2 86400)))
         (result (madolt-refs--format-margin-string
                  "Alice" (number-to-string two-days-ago))))
    (should (string-match-p "Alice" (substring-no-properties result)))
    (should (string-match-p "2 days" (substring-no-properties result)))))

(ert-deftest test-madolt-refs-margin-defcustom ()
  "Margin defcustom should have expected structure."
  (should (listp madolt-refs-margin))
  (should (= 5 (length madolt-refs-margin))))

;;;; Section keymaps

(ert-deftest test-madolt-refs-section-keymap-commands-exist ()
  "Section keymap action commands should be defined."
  (should (fboundp 'madolt-refs-visit-branch))
  (should (fboundp 'madolt-refs-delete-branch))
  (should (fboundp 'madolt-refs-rename-branch))
  (should (fboundp 'madolt-refs-delete-tag))
  (should (fboundp 'madolt-refs-delete-remote)))

;;;; New faces

(ert-deftest test-madolt-refs-remote-head-face ()
  "Remote HEAD face should inherit from magit-branch-remote-head."
  (should (facep 'madolt-branch-remote-head))
  (should (eq (face-attribute 'madolt-branch-remote-head :inherit)
              'magit-branch-remote-head)))

(ert-deftest test-madolt-refs-upstream-face ()
  "Upstream face should have italic slant."
  (should (facep 'madolt-branch-upstream)))

(ert-deftest test-madolt-refs-warning-face ()
  "Warning face should inherit from warning."
  (should (facep 'madolt-branch-warning)))

;;;; Sections hook

(ert-deftest test-madolt-refs-sections-hook-defcustom ()
  "Sections hook should be a customizable list of functions."
  (should (listp madolt-refs-sections-hook))
  (should (= 3 (length madolt-refs-sections-hook)))
  (dolist (fn madolt-refs-sections-hook)
    (should (functionp fn))))

(ert-deftest test-madolt-refs-sections-hook-customizable ()
  "Removing a section from the hook should omit it from the buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-tag-create "v1.0" nil "Tag")
    (with-temp-buffer
      (madolt-refs-mode)
      (setq madolt-refs--upstream "HEAD")
      ;; Remove tags inserter from hook
      (let ((madolt-refs-sections-hook
             (list #'madolt-refs--insert-local-branches
                   #'madolt-refs--insert-remote-branches))
            (inhibit-read-only t))
        (madolt-refs-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Branches should still be present
        (should (string-match-p "Branches" text))
        ;; Tags should be absent
        (should-not (string-match-p "Tags" text))))))

(provide 'madolt-refs-tests)
;;; madolt-refs-tests.el ends here
