;;; madolt-conflicts-tests.el --- Tests for madolt-conflicts.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt conflict resolution UI.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-conflicts)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Conflicts mode

(ert-deftest test-madolt-conflicts-mode-derived ()
  "madolt-conflicts-mode should derive from madolt-mode."
  (with-temp-buffer
    (madolt-conflicts-mode)
    (should (derived-mode-p 'madolt-mode))))

;;;; Transient

(ert-deftest test-madolt-conflicts-is-transient ()
  "madolt-conflicts should be a transient prefix."
  (should (get 'madolt-conflicts 'transient--layout)))

(ert-deftest test-madolt-conflicts-has-show-suffix ()
  "madolt-conflicts should have a 'c' suffix for show."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-conflicts)))
    (should (assoc "c" suffixes))
    (should (eq (cdr (assoc "c" suffixes))
                'madolt-conflicts-show))))

(ert-deftest test-madolt-conflicts-has-ours-suffix ()
  "madolt-conflicts should have an 'o' suffix for resolve ours."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-conflicts)))
    (should (assoc "o" suffixes))
    (should (eq (cdr (assoc "o" suffixes))
                'madolt-conflicts-resolve-ours))))

(ert-deftest test-madolt-conflicts-has-theirs-suffix ()
  "madolt-conflicts should have a 't' suffix for resolve theirs."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-conflicts)))
    (should (assoc "t" suffixes))
    (should (eq (cdr (assoc "t" suffixes))
                'madolt-conflicts-resolve-theirs))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-conflicts ()
  "The dispatch menu should have a 'C' binding for conflicts."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "C" suffixes))
    (should (eq (cdr (assoc "C" suffixes)) 'madolt-conflicts))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-conflicts ()
  "The mode map should bind 'C' to madolt-conflicts."
  (should (eq (keymap-lookup madolt-mode-map "C") #'madolt-conflicts)))

;;;; Conflict helper — creates a merge conflict scenario

(defun madolt-test-create-conflict ()
  "Set up a merge conflict in the current test database.
Creates table t with row (1, 'original'), then makes conflicting
changes on main ('main-change') and feature ('feature-change').
Merges feature into main, producing a conflict."
  (madolt-test-create-table "t" "id INT PRIMARY KEY, val VARCHAR(50)")
  (madolt-test-sql "INSERT INTO t VALUES (1, 'original')")
  (madolt-test-commit "init")
  ;; Feature branch changes
  (madolt--run "checkout" "-b" "feature")
  (madolt-test-sql "UPDATE t SET val='feature-change' WHERE id=1")
  (madolt-test-commit "feature change")
  ;; Main branch changes
  (madolt--run "checkout" "main")
  (madolt-test-sql "UPDATE t SET val='main-change' WHERE id=1")
  (madolt-test-commit "main change")
  ;; Merge — this will produce a conflict
  (madolt--run "merge" "feature"))

;;;; Conflict table detection

(ert-deftest test-madolt-conflicts-table-names-detects ()
  "madolt-conflicts--table-names should detect conflicted tables."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (let ((tables (madolt-conflicts--table-names)))
      (should (member "t" tables)))))

(ert-deftest test-madolt-conflicts-table-names-empty ()
  "madolt-conflicts--table-names should return nil with no conflicts."
  (madolt-with-test-database
    (madolt-test-create-table "t" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((tables (madolt-conflicts--table-names)))
      (should (null tables)))))

;;;; Conflicts buffer display

(ert-deftest test-madolt-conflicts-show-creates-buffer ()
  "madolt-conflicts--show should create a conflicts buffer."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-conflicts--show "t")))
        (unwind-protect
            (progn
              (should (buffer-live-p buf))
              (should (string-match-p "conflicts" (buffer-name buf))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-conflicts-show-heading ()
  "The conflicts buffer should show a heading with the table name."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-conflicts--show "t")))
        (unwind-protect
            (with-current-buffer buf
              (should (string-match-p "Conflicts in t:"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-conflicts-show-base-ours-theirs ()
  "The conflicts buffer should show base, ours, and theirs values."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-conflicts--show "t")))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "base" content))
                (should (string-match-p "ours" content))
                (should (string-match-p "theirs" content))
                (should (string-match-p "main-change" content))
                (should (string-match-p "feature-change" content))))
          (kill-buffer buf))))))

;;;; Resolve commands

(ert-deftest test-madolt-conflicts-resolve-ours-calls-dolt ()
  "Resolving with ours should call dolt with correct args."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-conflicts-resolve-ours "t")
        (should (equal called-args
                       '("conflicts" "resolve" "--ours" "t")))))))

(ert-deftest test-madolt-conflicts-resolve-theirs-calls-dolt ()
  "Resolving with theirs should call dolt with correct args."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-conflicts-resolve-theirs "t")
        (should (equal called-args
                       '("conflicts" "resolve" "--theirs" "t")))))))

(ert-deftest test-madolt-conflicts-resolve-ours-clears-conflicts ()
  "After resolving with ours, conflicts should be cleared."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    ;; Verify conflict exists
    (should (member "t" (madolt-conflicts--table-names)))
    ;; Resolve
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-conflicts-resolve-ours "t"))
    ;; Verify conflict is gone
    (should (null (madolt-conflicts--table-names)))))

(ert-deftest test-madolt-conflicts-resolve-theirs-clears-conflicts ()
  "After resolving with theirs, conflicts should be cleared."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (should (member "t" (madolt-conflicts--table-names)))
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-conflicts-resolve-theirs "t"))
    (should (null (madolt-conflicts--table-names)))))

;;;; No conflicts

(ert-deftest test-madolt-conflicts-no-conflicts-message ()
  "Buffer should show no-conflicts message when there are none."
  (madolt-with-test-database
    (madolt-test-create-table "t" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-conflicts--show nil)))
        (unwind-protect
            (with-current-buffer buf
              (should (string-match-p "no conflicts"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
          (kill-buffer buf))))))

;;;; Row limit

(ert-deftest test-madolt-conflicts-limit-default ()
  "madolt-conflicts--limit should default to 200."
  (with-temp-buffer
    (madolt-conflicts-mode)
    (should (= madolt-conflicts--limit 200))))

(ert-deftest test-madolt-conflicts-double-limit ()
  "madolt-conflicts-double-limit should double the limit."
  (with-temp-buffer
    (madolt-conflicts-mode)
    (setq madolt-conflicts--limit 100)
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-conflicts-double-limit))
    (should (= madolt-conflicts--limit 200))))

(ert-deftest test-madolt-conflicts-no-show-more-when-under-limit ()
  "Show-more button should NOT appear when output fits within the limit."
  (madolt-with-test-database
    (madolt-test-create-conflict)
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-conflicts--show "t")))
        (unwind-protect
            (with-current-buffer buf
              ;; With only 1 conflict row, output should be well under 200 lines
              (should-not (string-match-p "show more"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))
          (kill-buffer buf))))))

(provide 'madolt-conflicts-tests)
;;; madolt-conflicts-tests.el ends here
