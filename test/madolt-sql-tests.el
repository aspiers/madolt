;;; madolt-sql-tests.el --- Tests for madolt-sql.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt SQL query interface.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-sql)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-test-helpers)

;;;; SQL mode

(ert-deftest test-madolt-sql-mode-derived ()
  "madolt-sql-mode should derive from madolt-mode."
  (with-temp-buffer
    (madolt-sql-mode)
    (should (derived-mode-p 'madolt-mode))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-sql ()
  "The dispatch menu should have an 'e' binding for SQL query."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "e" suffixes))
    (should (eq (cdr (assoc "e" suffixes)) 'madolt-sql-query))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-sql ()
  "The mode map should bind 'e' to madolt-sql-query."
  (should (eq (keymap-lookup madolt-mode-map "e") #'madolt-sql-query)))

;;;; Query execution — SELECT

(ert-deftest test-madolt-sql-select-shows-results ()
  "A SELECT query should display tabular results."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, name VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'Alice')")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT * FROM t1")))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "Alice" content))
                (should (string-match-p "SQL:.*SELECT" content))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-sql-select-multiple-rows ()
  "A SELECT query should show all matching rows."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, name VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'Alice')")
    (madolt-test-insert-row "t1" "(2, 'Bob')")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT * FROM t1")))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "Alice" content))
                (should (string-match-p "Bob" content))))
          (kill-buffer buf))))))

;;;; Query execution — DML (no output)

(ert-deftest test-madolt-sql-insert-success-message ()
  "An INSERT query should show a success message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "INSERT INTO t1 VALUES (1)")))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "successfully" content))))
          (kill-buffer buf))))))

;;;; Query execution — error

(ert-deftest test-madolt-sql-error-displayed ()
  "An invalid query should show an error message."
  (madolt-with-test-database
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT * FROM nonexistent_table")))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "[Ee]rror" content))))
          (kill-buffer buf))))))

;;;; Empty query

(ert-deftest test-madolt-sql-empty-query-errors ()
  "An empty query should signal an error."
  (should-error (madolt-sql-query "")
                :type 'user-error))

(ert-deftest test-madolt-sql-blank-query-errors ()
  "A blank (whitespace-only) query should signal an error."
  (should-error (madolt-sql-query "   ")
                :type 'user-error))

;;;; Buffer management

(ert-deftest test-madolt-sql-creates-buffer ()
  "madolt-sql-query should create a SQL result buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT 1")))
        (unwind-protect
            (progn
              (should (buffer-live-p buf))
              (should (string-match-p "sql" (buffer-name buf))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-sql-buffer-has-sections ()
  "The SQL result buffer should contain magit sections."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT 1 AS val")))
        (unwind-protect
            (with-current-buffer buf
              (should magit-root-section)
              ;; Buffer should have content beyond just a newline
              (should (> (buffer-size) 10)))
          (kill-buffer buf))))))

;;;; Query stored in buffer

(ert-deftest test-madolt-sql-query-stored ()
  "The query should be stored in the buffer-local variable."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT 42")))
        (unwind-protect
            (with-current-buffer buf
              (should (equal madolt-sql--query "SELECT 42")))
          (kill-buffer buf))))))

;;;; SHOW TABLES

(ert-deftest test-madolt-sql-show-tables ()
  "SHOW TABLES should display table names."
  (madolt-with-test-database
    (madolt-test-create-table "users" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SHOW TABLES")))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "users" content))))
          (kill-buffer buf))))))

;;;; Refresh re-executes query

(ert-deftest test-madolt-sql-refresh-re-executes ()
  "Refreshing the SQL buffer should re-execute the stored query."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT * FROM t1")))
        (unwind-protect
            (progn
              ;; Insert another row
              (madolt-test-insert-row "t1" "(2)")
              ;; Refresh
              (with-current-buffer buf (madolt-refresh))
              (with-current-buffer buf
                (let ((content (buffer-substring-no-properties
                                (point-min) (point-max))))
                  ;; Should now show the new row
                  (should (string-match-p "2" content)))))
          (kill-buffer buf))))))

;;;; Row limit

(ert-deftest test-madolt-sql-limit-default ()
  "madolt-sql--limit should default to 1000."
  (with-temp-buffer
    (madolt-sql-mode)
    (should (= madolt-sql--limit 1000))))

(ert-deftest test-madolt-sql-double-limit ()
  "madolt-sql-double-limit should double the limit."
  (with-temp-buffer
    (madolt-sql-mode)
    (setq madolt-sql--limit 500)
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-sql-double-limit))
    (should (= madolt-sql--limit 1000))))

(ert-deftest test-madolt-sql-no-show-more-when-under-limit ()
  "Show-more button should NOT appear when output fits within the limit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-sql-query "SELECT * FROM t1")))
        (unwind-protect
            (with-current-buffer buf
              (should-not (string-match-p "show more"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))
          (kill-buffer buf))))))

(provide 'madolt-sql-tests)
;;; madolt-sql-tests.el ends here
