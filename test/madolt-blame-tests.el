;;; madolt-blame-tests.el --- Tests for madolt-blame.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt blame mode and table name completion.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-blame)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-test-helpers)

;;;; Blame mode

(ert-deftest test-madolt-blame-mode-derived ()
  "madolt-blame-mode should derive from madolt-mode."
  (with-temp-buffer
    (madolt-blame-mode)
    (should (derived-mode-p 'madolt-mode))))

;;;; Table names

(ert-deftest test-madolt-table-names-returns-list ()
  "madolt-table-names should return a list of table name strings."
  (madolt-with-test-database
    (madolt-test-create-table "users" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((names (madolt-table-names)))
      (should (listp names))
      (should (member "users" names)))))

(ert-deftest test-madolt-table-names-multiple ()
  "madolt-table-names should list multiple tables."
  (madolt-with-test-database
    (madolt-test-create-table "users" "id INT PRIMARY KEY")
    (madolt-test-create-table "orders" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((names (madolt-table-names)))
      (should (member "users" names))
      (should (member "orders" names)))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-blame ()
  "The dispatch menu should have a 'B' binding for blame."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "B" suffixes))
    (should (eq (cdr (assoc "B" suffixes)) 'madolt-blame))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-blame ()
  "The mode map should bind 'B' to madolt-blame."
  (should (eq (keymap-lookup madolt-mode-map "B") #'madolt-blame)))

;;;; Blame buffer display

(ert-deftest test-madolt-blame-creates-buffer ()
  "madolt-blame--show should create a blame buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "t1" nil)))
        (unwind-protect
            (progn
              (should (buffer-live-p buf))
              (should (string-match-p "blame" (buffer-name buf))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-blame-shows-heading ()
  "The blame buffer should show a heading with the table name."
  (madolt-with-test-database
    (madolt-test-create-table "users" "id INT PRIMARY KEY")
    (madolt-test-insert-row "users" "(1)")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "users" nil)))
        (unwind-protect
            (with-current-buffer buf
              (should (string-match-p "Blame for users:"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-blame-shows-commit-info ()
  "The blame buffer should show commit hashes and authors."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, name VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'Alice')")
    (madolt-test-commit "add Alice")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "t1" nil)))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                ;; Should show the row data
                (should (string-match-p "Alice" content))
                ;; Should show commit message
                (should (string-match-p "add Alice" content))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-blame-multiple-rows ()
  "The blame buffer should show blame for all rows."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, name VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'Alice')")
    (madolt-test-commit "add Alice")
    (madolt-test-insert-row "t1" "(2, 'Bob')")
    (madolt-test-commit "add Bob")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "t1" nil)))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "Alice" content))
                (should (string-match-p "Bob" content))
                (should (string-match-p "add Alice" content))
                (should (string-match-p "add Bob" content))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-blame-error-bad-table ()
  "Blaming a nonexistent table should show an error."
  (madolt-with-test-database
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "nonexistent" nil)))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "[Ee]rror" content))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-blame-has-sections ()
  "The blame buffer should contain magit sections."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "t1" nil)))
        (unwind-protect
            (with-current-buffer buf
              (should magit-root-section)
              (should (> (buffer-size) 10)))
          (kill-buffer buf))))))

(ert-deftest test-madolt-blame-stores-table ()
  "The table name should be stored in the buffer-local variable."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "t1" nil)))
        (unwind-protect
            (with-current-buffer buf
              (should (equal madolt-blame--table "t1")))
          (kill-buffer buf))))))

;;;; Row limit

(ert-deftest test-madolt-blame-limit-default ()
  "madolt-blame--limit should default to 200."
  (with-temp-buffer
    (madolt-blame-mode)
    (should (= madolt-blame--limit 200))))

(ert-deftest test-madolt-blame-double-limit ()
  "madolt-blame-double-limit should double the limit."
  (with-temp-buffer
    (madolt-blame-mode)
    (setq madolt-blame--limit 100)
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-blame-double-limit))
    (should (= madolt-blame--limit 200))))

(ert-deftest test-madolt-blame-no-show-more-when-under-limit ()
  "Show-more button should NOT appear when output fits within the limit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, name VARCHAR(50)")
    (madolt-test-insert-row "t1" "(1, 'Alice')")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-blame--show "t1" nil)))
        (unwind-protect
            (with-current-buffer buf
              (should-not (string-match-p "show more"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))
          (kill-buffer buf))))))

(provide 'madolt-blame-tests)
;;; madolt-blame-tests.el ends here
