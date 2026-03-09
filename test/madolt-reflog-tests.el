;;; madolt-reflog-tests.el --- Tests for madolt-reflog.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt reflog buffer and entry parsing.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-reflog)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-log)
(require 'madolt-test-helpers)

;;;; Reflog mode

(ert-deftest test-madolt-reflog-mode-derived ()
  "madolt-reflog-mode should derive from madolt-mode."
  (with-temp-buffer
    (madolt-reflog-mode)
    (should (derived-mode-p 'madolt-mode))))

;;;; Reflog entries parsing

(ert-deftest test-madolt-reflog-entries-returns-list ()
  "madolt-reflog-entries should return a list of plists."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (let ((entries (madolt-reflog-entries)))
      (should (listp entries))
      (should (> (length entries) 0)))))

(ert-deftest test-madolt-reflog-entries-plist-keys ()
  "Each reflog entry should have :hash, :refs, and :message keys."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first commit")
    (let ((entry (car (madolt-reflog-entries))))
      (should (plist-get entry :hash))
      (should (plist-get entry :refs))
      (should (plist-get entry :message)))))

(ert-deftest test-madolt-reflog-entries-message ()
  "Reflog entries should contain the commit message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "my test commit")
    (let ((entries (madolt-reflog-entries)))
      (should (cl-some (lambda (e)
                         (string-match-p "my test commit"
                                         (plist-get e :message)))
                       entries)))))

(ert-deftest test-madolt-reflog-entries-hash-format ()
  "Reflog entry hashes should be 32-char hex strings."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (let ((hash (plist-get (car (madolt-reflog-entries)) :hash)))
      (should (string-match-p "^[a-z0-9]\\{32\\}$" hash)))))

(ert-deftest test-madolt-reflog-entries-for-ref ()
  "madolt-reflog-entries with a ref should filter to that ref."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((entries (madolt-reflog-entries "main")))
      (should (> (length entries) 0))
      ;; All entries should reference main
      (dolist (e entries)
        (should (string-match-p "main" (plist-get e :refs)))))))

(ert-deftest test-madolt-reflog-entries-all-flag ()
  "madolt-reflog-entries with ALL should include all refs."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Create another branch so there are multiple refs
    (madolt-branch-create "feature")
    (let ((entries (madolt-reflog-entries nil t)))
      (should (> (length entries) 0)))))

(ert-deftest test-madolt-reflog-entries-multiple-commits ()
  "Reflog should show entries for multiple commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "first")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "second")
    (let ((entries (madolt-reflog-entries)))
      ;; At least 3: init + first + second
      (should (>= (length entries) 3)))))

;;;; Log transient integration

(ert-deftest test-madolt-log-has-reflog-current-suffix ()
  "The log transient should have an 'O' suffix for reflog current."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log)))
    (should (assoc "O" suffixes))
    (should (eq (cdr (assoc "O" suffixes))
                'madolt-reflog-current))))

(ert-deftest test-madolt-log-has-reflog-other-suffix ()
  "The log transient should have a 'p' suffix for reflog other."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log)))
    (should (assoc "p" suffixes))
    (should (eq (cdr (assoc "p" suffixes))
                'madolt-reflog-other))))

;;;; Buffer display

(ert-deftest test-madolt-reflog-show-creates-buffer ()
  "madolt-reflog--show should create a reflog buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-reflog--show "main" nil)))
        (unwind-protect
            (progn
              (should (buffer-live-p buf))
              (should (string-match-p "reflog" (buffer-name buf))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-reflog-buffer-has-heading ()
  "The reflog buffer should contain a heading."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-reflog--show "main" nil)))
        (unwind-protect
            (with-current-buffer buf
              (should (string-match-p "Reflog for main:"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-reflog-buffer-shows-entries ()
  "The reflog buffer should contain reflog entry hashes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "my reflog test")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-reflog--show "main" nil)))
        (unwind-protect
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "my reflog test" content))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-reflog-buffer-all-heading ()
  "The reflog buffer with ALL should show an appropriate heading."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-reflog--show nil t)))
        (unwind-protect
            (with-current-buffer buf
              (should (string-match-p "Reflog (all refs):"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-reflog-buffer-has-sections ()
  "The reflog buffer should contain magit sections."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-reflog--show "main" nil)))
        (unwind-protect
            (with-current-buffer buf
              (should magit-root-section)
              (should (> (length (oref magit-root-section children)) 0)))
          (kill-buffer buf))))))

(ert-deftest test-madolt-reflog-init-entry ()
  "A freshly initialized repo should have at least one reflog entry."
  (madolt-with-test-database
    (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
      (let ((buf (madolt-reflog--show nil nil)))
        (unwind-protect
            (with-current-buffer buf
              ;; dolt init creates an "Initialize data repository" entry
              (should (string-match-p "Initialize data repository"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
          (kill-buffer buf))))))

(provide 'madolt-reflog-tests)
;;; madolt-reflog-tests.el ends here
