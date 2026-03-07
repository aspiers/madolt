;;; madolt-test-helpers.el --- Test helpers for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared test infrastructure for madolt ERT tests.
;; Provides macros for creating temporary Dolt databases and
;; helper functions for setting up common test scenarios.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'madolt-dolt)

;;;; Temporary database macro

(defmacro madolt-with-test-database (&rest body)
  "Execute BODY in a temporary Dolt database directory.
The database is initialized with `dolt init' and cleaned up afterward.
Sets NO_COLOR=1 to suppress ANSI escape codes from dolt output."
  (declare (indent 0) (debug t))
  (let ((dir (make-symbol "dir")))
    `(let ((,dir (file-name-as-directory (make-temp-file "madolt-test-" t))))
       (condition-case err
           (let ((default-directory (file-truename ,dir))
                 (process-environment
                  (append (list "NO_COLOR=1") process-environment)))
             (call-process madolt-dolt-executable nil nil nil "init")
             (call-process madolt-dolt-executable nil nil nil
                           "config" "--local" "--add" "user.name" "Test User")
             (call-process madolt-dolt-executable nil nil nil
                           "config" "--local" "--add" "user.email" "test@example.com")
             ,@body)
         (error (message "Keeping test directory:\n  %s" ,dir)
                (signal (car err) (cdr err))))
       (delete-directory ,dir t))))

;;;; Helper functions

(defun madolt-test-sql (query)
  "Execute SQL QUERY in the current test database.
Return the exit code."
  (call-process madolt-dolt-executable nil nil nil "sql" "-q" query))

(defun madolt-test-create-table (name columns-sql)
  "Create table NAME with COLUMNS-SQL in the current test database."
  (madolt-test-sql (format "CREATE TABLE %s (%s)" name columns-sql)))

(defun madolt-test-insert-row (table values-sql)
  "Insert a row into TABLE with VALUES-SQL."
  (madolt-test-sql (format "INSERT INTO %s VALUES %s" table values-sql)))

(defun madolt-test-update-row (table set-clause where-clause)
  "Update rows in TABLE matching WHERE-CLAUSE with SET-CLAUSE."
  (madolt-test-sql (format "UPDATE %s SET %s WHERE %s"
                           table set-clause where-clause)))

(defun madolt-test-delete-row (table where-clause)
  "Delete rows from TABLE matching WHERE-CLAUSE."
  (madolt-test-sql (format "DELETE FROM %s WHERE %s" table where-clause)))

(defun madolt-test-commit (message)
  "Stage all tables and commit with MESSAGE."
  (call-process madolt-dolt-executable nil nil nil "add" ".")
  (call-process madolt-dolt-executable nil nil nil "commit" "-m" message))

(defun madolt-test-stage-all ()
  "Stage all changes."
  (call-process madolt-dolt-executable nil nil nil "add" "."))

(defun madolt-test-stage-table (table)
  "Stage a single TABLE."
  (call-process madolt-dolt-executable nil nil nil "add" table))

;;;; Populated database helper

(defun madolt-test-setup-populated-db ()
  "Set up a test database with a known state for common test scenarios.
Creates:
- A committed table `users' with rows (1, Alice, alice@ex.com)
  and (2, Bob, bob@ex.com)
- A staged modification to users: Alice's email changed (staged)
- An unstaged modification to a committed table `products':
  product 1 price changed
- An untracked table `inventory'

After calling this function the dolt status will show:
- Staged: users (modified)
- Unstaged: products (modified)
- Untracked: inventory (new table)"
  ;; Create and commit users table
  (madolt-test-create-table
   "users" "id INT PRIMARY KEY, name VARCHAR(100), email VARCHAR(200)")
  (madolt-test-insert-row "users" "(1, 'Alice', 'alice@ex.com')")
  (madolt-test-insert-row "users" "(2, 'Bob', 'bob@ex.com')")
  ;; Create and commit products table
  (madolt-test-create-table
   "products" "id INT PRIMARY KEY, name VARCHAR(100), price DECIMAL(10,2)")
  (madolt-test-insert-row "products" "(1, 'Widget', 9.99)")
  (madolt-test-insert-row "products" "(2, 'Gadget', 19.99)")
  (madolt-test-commit "Initial data")
  ;; Staged change: modify users (Alice's email)
  (madolt-test-update-row "users" "email = 'alice_new@ex.com'" "id = 1")
  (madolt-test-stage-table "users")
  ;; Unstaged change: modify products (Widget price)
  (madolt-test-update-row "products" "price = 12.99" "id = 1")
  ;; Untracked table: inventory
  (madolt-test-create-table
   "inventory" "id INT PRIMARY KEY, item VARCHAR(100), qty INT")
  (madolt-test-insert-row "inventory" "(1, 'Bolts', 500)"))

(provide 'madolt-test-helpers)
;;; madolt-test-helpers.el ends here
