;;; madolt-reset-tests.el --- Tests for madolt-reset.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt reset transient and reset commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-reset)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-reset-is-transient ()
  "madolt-reset should be a transient prefix."
  (should (get 'madolt-reset 'transient--layout)))

(ert-deftest test-madolt-reset-has-soft-suffix ()
  "madolt-reset should have an 's' suffix for soft reset."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-reset)))
    (should (assoc "s" suffixes))
    (should (eq (cdr (assoc "s" suffixes))
                'madolt-reset-soft-command))))

(ert-deftest test-madolt-reset-has-hard-suffix ()
  "madolt-reset should have an 'h' suffix for hard reset."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-reset)))
    (should (assoc "h" suffixes))
    (should (eq (cdr (assoc "h" suffixes))
                'madolt-reset-hard-command))))

(ert-deftest test-madolt-reset-has-mixed-suffix ()
  "madolt-reset should have an 'm' suffix for mixed reset."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-reset)))
    (should (assoc "m" suffixes))
    (should (eq (cdr (assoc "m" suffixes))
                'madolt-reset-mixed-command))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-reset ()
  "The dispatch menu has an \"X\" binding for reset."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "X" suffixes))
    (should (eq (cdr (assoc "X" suffixes)) 'madolt-reset))))

;;;; Keybinding

(ert-deftest test-madolt-mode-map-has-reset ()
  "The mode map should bind 'X' to madolt-reset."
  (should (eq (keymap-lookup madolt-mode-map "X") #'madolt-reset)))

;;;; Soft reset — calls dolt with correct args

(ert-deftest test-madolt-reset-soft-calls-dolt ()
  "madolt-reset-soft-command should invoke dolt reset --soft REVISION."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-reset-soft-command "HEAD~1")
        (should (equal called-args '("reset" "--soft" "HEAD~1")))))))

(ert-deftest test-madolt-reset-soft-reports-success ()
  "madolt-reset-soft-command should report success."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((messages nil))
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest _args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (madolt-reset-soft-command "HEAD")
        (should (cl-some (lambda (msg)
                           (string-match-p "Soft reset to HEAD" msg))
                         messages))))))

(ert-deftest test-madolt-reset-soft-reports-failure ()
  "madolt-reset-soft-command should report failure."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((messages nil))
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest _args) '(1 . "bad revision")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (madolt-reset-soft-command "nonexistent")
        (should (cl-some (lambda (msg)
                           (string-match-p "failed" msg))
                         messages))))))

;;;; Hard reset — calls dolt with correct args

(ert-deftest test-madolt-reset-hard-calls-dolt ()
  "madolt-reset-hard-command should invoke dolt reset --hard REVISION."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (madolt-reset-hard-command "HEAD~1")
        (should (equal called-args '("reset" "--hard" "HEAD~1")))))))

(ert-deftest test-madolt-reset-hard-requires-confirmation ()
  "madolt-reset-hard-command should prompt for confirmation."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((prompted nil))
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest _args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (setq prompted t) t)))
        (madolt-reset-hard-command "HEAD")
        (should prompted)))))

(ert-deftest test-madolt-reset-hard-aborts-on-no ()
  "madolt-reset-hard-command should abort when user declines."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((dolt-called nil))
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest _args) (setq dolt-called t) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-error (madolt-reset-hard-command "HEAD")
                      :type 'user-error)
        (should-not dolt-called)))))

;;;; Mixed reset — calls dolt with correct args

(ert-deftest test-madolt-reset-mixed-calls-dolt ()
  "madolt-reset-mixed-command should invoke dolt reset . to unstage all."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-reset-mixed-command)
        (should (equal called-args '("reset" ".")))))))

(ert-deftest test-madolt-reset-mixed-reports-success ()
  "madolt-reset-mixed-command should report success."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((messages nil))
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest _args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (madolt-reset-mixed-command)
        (should (cl-some (lambda (msg)
                           (string-match-p "Reset staging area" msg))
                         messages))))))

;;;; Actual reset operations

(ert-deftest test-madolt-reset-mixed-unstages-tables ()
  "Mixed reset should unstage all staged tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Make a change and stage it
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-table "t1")
    ;; Verify t1 is staged
    (let ((status-before (madolt-status-tables)))
      (should (assoc "t1" (alist-get 'staged status-before))))
    ;; Run mixed reset
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-reset-mixed-command))
    ;; Verify t1 is no longer staged
    (let ((status-after (madolt-status-tables)))
      (should-not (assoc "t1" (alist-get 'staged status-after))))))

(ert-deftest test-madolt-reset-hard-discards-changes ()
  "Hard reset should discard working set changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    ;; Make a change
    (madolt-test-insert-row "t1" "(2)")
    ;; Verify the change exists
    (let ((result (madolt-call-dolt "sql" "-q" "SELECT COUNT(*) as c FROM t1" "-r" "json")))
      (should (string-match-p "2" (cdr result))))
    ;; Hard reset
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (madolt-reset-hard-command "HEAD"))
    ;; Verify change is gone
    (let ((result (madolt-call-dolt "sql" "-q" "SELECT COUNT(*) as c FROM t1" "-r" "json")))
      (should (string-match-p "\"c\":1" (cdr result))))))

;;;; Read revision helper

(ert-deftest test-madolt-reset-read-revision-defaults-to-head ()
  "madolt-reset--read-revision should default to HEAD."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _args)
                 ;; Return the default (last arg in the arglist)
                 "HEAD")))
      (should (equal (madolt-reset--read-revision "Soft reset to") "HEAD")))))

(provide 'madolt-reset-tests)
;;; madolt-reset-tests.el ends here
