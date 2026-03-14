;;; madolt-connection-tests.el --- Tests for madolt-connection.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the SQL connection manager.  These tests focus on
;; unit-testable logic (parsing, configuration) rather than requiring
;; a live dolt sql-server, which is tested interactively.

;;; Code:

(require 'ert)
(require 'madolt-connection)

;;;; Customization defaults

(ert-deftest test-madolt-connection-use-sql-server-default ()
  "SQL server usage should be disabled by default."
  (should-not madolt-use-sql-server))

(ert-deftest test-madolt-connection-host-default ()
  "Default host should be localhost."
  (should (equal madolt-sql-server-host "127.0.0.1")))

(ert-deftest test-madolt-connection-port-default ()
  "Default port should be 3306."
  (should (= madolt-sql-server-port 3306)))

(ert-deftest test-madolt-connection-user-default ()
  "Default user should be root."
  (should (equal madolt-sql-server-user "root")))

(ert-deftest test-madolt-connection-auto-start-default ()
  "Auto-start should default to prompt."
  (should (eq madolt-sql-server-auto-start 'prompt)))

;;;; Batch output parsing

(ert-deftest test-madolt-connection-parse-empty ()
  "Parsing empty output should return nil."
  (should-not (madolt-connection--parse-batch-output ""))
  (should-not (madolt-connection--parse-batch-output nil))
  (should-not (madolt-connection--parse-batch-output "  \n  ")))

(ert-deftest test-madolt-connection-parse-single-row ()
  "Parsing a single tab-separated row."
  (let ((result (madolt-connection--parse-batch-output "foo\tbar\tbaz\n")))
    (should (= 1 (length result)))
    (should (equal (car result) '("foo" "bar" "baz")))))

(ert-deftest test-madolt-connection-parse-multiple-rows ()
  "Parsing multiple tab-separated rows."
  (let ((result (madolt-connection--parse-batch-output
                 "a\t1\nb\t2\nc\t3\n")))
    (should (= 3 (length result)))
    (should (equal (nth 0 result) '("a" "1")))
    (should (equal (nth 1 result) '("b" "2")))
    (should (equal (nth 2 result) '("c" "3")))))

(ert-deftest test-madolt-connection-parse-no-trailing-newline ()
  "Parsing output without trailing newline."
  (let ((result (madolt-connection--parse-batch-output "x\ty")))
    (should (= 1 (length result)))
    (should (equal (car result) '("x" "y")))))

;;;; MySQL args construction

(ert-deftest test-madolt-connection-mysql-args-basic ()
  "MySQL args should include host, port, user, and batch mode."
  (let ((madolt-sql-server-host "127.0.0.1")
        (madolt-sql-server-port 3307)
        (madolt-sql-server-user "testuser")
        (madolt-sql-server-password ""))
    (let ((args (madolt-connection--mysql-args 3307 "mydb")))
      (should (member "--host" args))
      (should (member "--batch" args))
      (should (member "--skip-column-names" args))
      (should (member "mydb" args))
      (should (member "testuser" args)))))

(ert-deftest test-madolt-connection-mysql-args-with-password ()
  "MySQL args should include password when set."
  (let ((madolt-sql-server-host "127.0.0.1")
        (madolt-sql-server-port 3306)
        (madolt-sql-server-user "root")
        (madolt-sql-server-password "secret"))
    (let ((args (madolt-connection--mysql-args 3306 "mydb")))
      (should (cl-some (lambda (a) (string-prefix-p "--password=" a))
                       args)))))

(ert-deftest test-madolt-connection-mysql-args-no-password ()
  "MySQL args should not include password when empty."
  (let ((madolt-sql-server-host "127.0.0.1")
        (madolt-sql-server-port 3306)
        (madolt-sql-server-user "root")
        (madolt-sql-server-password ""))
    (let ((args (madolt-connection--mysql-args 3306 "mydb")))
      (should-not (cl-some (lambda (a) (string-prefix-p "--password=" a))
                           args)))))

;;;; Connection state

(ert-deftest test-madolt-connection-initially-inactive ()
  "Connection should be inactive initially."
  (let ((madolt-connection--ready nil)
        (madolt-connection--process nil))
    (should-not (madolt-connection-active-p))))

(ert-deftest test-madolt-connection-active-requires-process ()
  "Connection active check requires a live process."
  (let ((madolt-connection--ready t)
        (madolt-connection--process nil))
    (should-not (madolt-connection-active-p))))

;;;; Port finding

(ert-deftest test-madolt-connection-find-free-port ()
  "Should find a free port number."
  (let ((port (madolt-connection--find-free-port)))
    (should (integerp port))
    (should (> port 0))
    (should (<= port 65535))))

;;;; Functions exist

(ert-deftest test-madolt-connection-public-api ()
  "All public API functions should be defined."
  (dolist (fn '(madolt-connection-query
                madolt-connection-ensure
                madolt-connection-active-p
                madolt-connection-disconnect
                madolt-connection-shutdown))
    (should (fboundp fn))))

(provide 'madolt-connection-tests)
;;; madolt-connection-tests.el ends here
