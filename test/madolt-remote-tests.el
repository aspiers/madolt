;;; madolt-remote-tests.el --- Tests for madolt-remote.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt push, pull, and fetch transients.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt)
(require 'madolt-remote)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient definitions

(ert-deftest test-madolt-fetch-is-transient ()
  "madolt-fetch should be a transient prefix."
  (should (get 'madolt-fetch 'transient--layout)))

(ert-deftest test-madolt-pull-is-transient ()
  "madolt-pull should be a transient prefix."
  (should (get 'madolt-pull 'transient--layout)))

(ert-deftest test-madolt-push-is-transient ()
  "madolt-push should be a transient prefix."
  (should (get 'madolt-push 'transient--layout)))

;;;; Fetch suffixes

(ert-deftest test-madolt-fetch-has-origin-suffix ()
  "madolt-fetch should have a 'p' suffix for fetching from origin."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-fetch)))
    (should (assoc "p" suffixes))
    (should (eq (cdr (assoc "p" suffixes))
                'madolt-fetch-from-origin))))

(ert-deftest test-madolt-fetch-has-elsewhere-suffix ()
  "madolt-fetch should have an 'e' suffix for fetching from elsewhere."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-fetch)))
    (should (assoc "e" suffixes))
    (should (eq (cdr (assoc "e" suffixes))
                'madolt-fetch-from-remote))))

;;;; Pull suffixes

(ert-deftest test-madolt-pull-has-origin-suffix ()
  "madolt-pull should have a 'p' suffix for pulling from origin."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-pull)))
    (should (assoc "p" suffixes))
    (should (eq (cdr (assoc "p" suffixes))
                'madolt-pull-from-origin))))

(ert-deftest test-madolt-pull-has-elsewhere-suffix ()
  "madolt-pull should have an 'e' suffix for pulling from elsewhere."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-pull)))
    (should (assoc "e" suffixes))
    (should (eq (cdr (assoc "e" suffixes))
                'madolt-pull-from-remote))))

;;;; Push suffixes

(ert-deftest test-madolt-push-has-origin-suffix ()
  "madolt-push should have a 'p' suffix for pushing to origin."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-push)))
    (should (assoc "p" suffixes))
    (should (eq (cdr (assoc "p" suffixes))
                'madolt-push-to-origin))))

(ert-deftest test-madolt-push-has-elsewhere-suffix ()
  "madolt-push should have an 'e' suffix for pushing to elsewhere."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-push)))
    (should (assoc "e" suffixes))
    (should (eq (cdr (assoc "e" suffixes))
                'madolt-push-to-remote))))

;;;; Dispatch integration

(ert-deftest test-madolt-dispatch-has-fetch ()
  "The dispatch menu has an \"f\" binding for fetch."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "f" suffixes))
    (should (eq (cdr (assoc "f" suffixes)) 'madolt-fetch))))

(ert-deftest test-madolt-dispatch-has-pull ()
  "The dispatch menu has an \"F\" binding for pull."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "F" suffixes))
    (should (eq (cdr (assoc "F" suffixes)) 'madolt-pull))))

(ert-deftest test-madolt-dispatch-has-push ()
  "The dispatch menu has a \"P\" binding for push."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "P" suffixes))
    (should (eq (cdr (assoc "P" suffixes)) 'madolt-push))))

;;;; Keybindings

(ert-deftest test-madolt-mode-map-has-fetch ()
  "The mode map should bind 'f' to madolt-fetch."
  (should (eq (keymap-lookup madolt-mode-map "f") #'madolt-fetch)))

(ert-deftest test-madolt-mode-map-has-pull ()
  "The mode map should bind 'F' to madolt-pull."
  (should (eq (keymap-lookup madolt-mode-map "F") #'madolt-pull)))

(ert-deftest test-madolt-mode-map-has-push ()
  "The mode map should bind 'P' to madolt-push."
  (should (eq (keymap-lookup madolt-mode-map "P") #'madolt-push)))

;;;; Helper: madolt-remote-names

(ert-deftest test-madolt-remote-names-empty ()
  "madolt-remote-names should return nil when no remotes configured."
  (madolt-with-test-database
    (should (null (madolt-remote-names)))))

(ert-deftest test-madolt-remote-names-with-remote ()
  "madolt-remote-names should list configured remotes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Add a remote pointing to a local dir (won't actually work for
    ;; fetch/push but is enough to test the listing)
    (madolt--run "remote" "add" "upstream" "file:///tmp/fake-remote")
    (let ((names (madolt-remote-names)))
      (should (member "upstream" names)))))

;;;; Helper: madolt-remote--read-remote

(ert-deftest test-madolt-remote-read-remote-single ()
  "With a single remote, should return it without prompting."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt--run "remote" "add" "origin" "file:///tmp/fake")
    (should (string= (madolt-remote--read-remote "Test: ") "origin"))))

(ert-deftest test-madolt-remote-read-remote-none-errors ()
  "With no remotes, should signal a user-error."
  (madolt-with-test-database
    (should-error (madolt-remote--read-remote "Test: ")
                  :type 'user-error)))

;;;; Integration tests with file:// remote
;;
;; Dolt's file:// protocol supports fetch and push but not clone or
;; pull (which requires tracking branch setup).  We test fetch and
;; push with a real local remote, and verify push/pull/fetch commands
;; invoke the CLI correctly via stubbing for the pull case.

(defmacro madolt-with-file-remote (&rest body)
  "Execute BODY in a dolt repo with a file:// origin pointing to another repo.
Binds `origin-dir' to the path of the origin repository."
  (declare (indent 0) (debug t))
  (let ((orig (make-symbol "orig"))
        (work (make-symbol "work")))
    `(let ((,orig (file-name-as-directory (make-temp-file "madolt-origin-" t)))
           (,work (file-name-as-directory (make-temp-file "madolt-work-" t))))
       (unwind-protect
           (let ((process-environment
                  (append (list "NO_COLOR=1") process-environment)))
             ;; Initialize origin repo with a commit
             (let ((default-directory (file-truename ,orig)))
               (call-process madolt-dolt-executable nil nil nil "init")
               (call-process madolt-dolt-executable nil nil nil
                             "config" "--local" "--add" "user.name" "Test User")
               (call-process madolt-dolt-executable nil nil nil
                             "config" "--local" "--add" "user.email" "test@example.com")
               (madolt-test-create-table "t1" "id INT PRIMARY KEY")
               (madolt-test-commit "origin init"))
             ;; Set up working repo with origin remote
             (let ((default-directory (file-truename ,work))
                   (origin-dir (file-truename ,orig)))
               (call-process madolt-dolt-executable nil nil nil "init")
               (call-process madolt-dolt-executable nil nil nil
                             "config" "--local" "--add" "user.name" "Test User")
               (call-process madolt-dolt-executable nil nil nil
                             "config" "--local" "--add" "user.email" "test@example.com")
               (madolt-test-create-table "t1" "id INT PRIMARY KEY")
               (madolt-test-commit "local init")
               (madolt--run "remote" "add" "origin"
                            (concat "file://" origin-dir))
               ,@body))
         (delete-directory ,orig t)
         (delete-directory ,work t)))))

(ert-deftest test-madolt-fetch-from-origin-succeeds ()
  "Fetching from origin should succeed with a file:// remote."
  (madolt-with-file-remote
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (let ((result (madolt-call-dolt "fetch" "origin")))
        (should (zerop (car result)))))))

(ert-deftest test-madolt-push-to-origin-succeeds ()
  "Pushing to origin should succeed with a file:// remote."
  (madolt-with-file-remote
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "add t2")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (let ((result (madolt-call-dolt "push" "origin" "main")))
        (should (zerop (car result)))))))

(ert-deftest test-madolt-push-command-calls-dolt ()
  "madolt-push-to-origin should invoke dolt push with correct args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt--run "remote" "add" "origin" "file:///tmp/fake")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-push-to-origin nil)
        (should (equal called-args '("push" "origin" "main")))))))

(ert-deftest test-madolt-pull-command-calls-dolt ()
  "madolt-pull-from-origin should invoke dolt pull with correct args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt--run "remote" "add" "origin" "file:///tmp/fake")
    (let (called-args)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args) (setq called-args args) '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        (madolt-pull-from-origin nil)
        (should (equal called-args '("pull" "origin")))))))

(provide 'madolt-remote-tests)
;;; madolt-remote-tests.el ends here
