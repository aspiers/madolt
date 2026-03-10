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

;; madolt-with-file-remote is now in madolt-test-helpers.el

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

;;;; Remote management transient

(ert-deftest test-madolt-remote-manage-is-transient ()
  "madolt-remote-manage should be a transient prefix."
  (should (get 'madolt-remote-manage 'transient--layout)))

(ert-deftest test-madolt-remote-manage-has-add-suffix ()
  "madolt-remote-manage should have an 'a' suffix for adding."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-remote-manage)))
    (should (assoc "a" suffixes))
    (should (eq (cdr (assoc "a" suffixes))
                'madolt-remote-add-command))))

(ert-deftest test-madolt-remote-manage-has-remove-suffix ()
  "madolt-remote-manage should have a 'k' suffix for removing."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-remote-manage)))
    (should (assoc "k" suffixes))
    (should (eq (cdr (assoc "k" suffixes))
                'madolt-remote-remove-command))))

(ert-deftest test-madolt-dispatch-has-remote-manage ()
  "The dispatch menu has an \"M\" binding for remote management."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-dispatch)))
    (should (assoc "M" suffixes))
    (should (eq (cdr (assoc "M" suffixes)) 'madolt-remote-manage))))

(ert-deftest test-madolt-mode-map-has-remote-manage ()
  "The mode map should bind 'M' to madolt-remote-manage."
  (should (eq (keymap-lookup madolt-mode-map "M") #'madolt-remote-manage)))

;;;; Remote add/remove backend

(ert-deftest test-madolt-remote-add-creates-remote ()
  "madolt-remote-add should create a new remote."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (let ((result (madolt-remote-add "upstream" "file:///tmp/fake-upstream")))
      (should (zerop (car result)))
      (should (member "upstream" (madolt-remote-names))))))

(ert-deftest test-madolt-remote-remove-deletes-remote ()
  "madolt-remote-remove should delete an existing remote."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-remote-add "upstream" "file:///tmp/fake-upstream")
    (should (member "upstream" (madolt-remote-names)))
    (let ((result (madolt-remote-remove "upstream")))
      (should (zerop (car result)))
      (should-not (member "upstream" (madolt-remote-names))))))

;;;; Remote add/remove commands

(ert-deftest test-madolt-remote-add-command-creates ()
  "madolt-remote-add-command should add a remote via the CLI."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-remote-add-command "test-remote" "file:///tmp/test-remote" nil))
    (should (member "test-remote" (madolt-remote-names)))))

(ert-deftest test-madolt-remote-add-command-empty-name-errors ()
  "madolt-remote-add-command should error on empty name."
  (should-error (madolt-remote-add-command "" "file:///tmp/test" nil)
                :type 'user-error))

(ert-deftest test-madolt-remote-add-command-empty-url-errors ()
  "madolt-remote-add-command should error on empty URL."
  (should-error (madolt-remote-add-command "test" "" nil)
                :type 'user-error))

(ert-deftest test-madolt-remote-remove-command-removes ()
  "madolt-remote-remove-command should remove a remote with confirmation."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-remote-add "doomed" "file:///tmp/doomed")
    (should (member "doomed" (madolt-remote-names)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'madolt-refresh) #'ignore))
      (madolt-remote-remove-command "doomed"))
    (should-not (member "doomed" (madolt-remote-names)))))

(ert-deftest test-madolt-remote-remove-command-aborts-on-deny ()
  "madolt-remote-remove-command should abort when user denies confirmation."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-remote-add "kept" "file:///tmp/kept")
    (should (member "kept" (madolt-remote-names)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil))
              ((symbol-function 'madolt-refresh) #'ignore))
      (madolt-remote-remove-command "kept"))
    (should (member "kept" (madolt-remote-names)))))

(ert-deftest test-madolt-remote-add-with-fetch-flag ()
  "madolt-remote-add-command with -f flag should also fetch."
  (madolt-with-file-remote
    (let (fetch-called)
      (cl-letf (((symbol-function 'madolt-call-dolt)
                 (lambda (&rest args)
                   (when (equal (car args) "fetch")
                     (setq fetch-called args))
                   '(0 . "")))
                ((symbol-function 'madolt-refresh) #'ignore))
        ;; Add a second remote and pass -f flag
        (madolt-remote-add-command "second" "file:///tmp/second" '("-f"))
        (should fetch-called)
        (should (equal (cadr fetch-called) "second"))))))

;;;; Remote configure URL

(ert-deftest test-madolt-remote-manage-has-configure-suffix ()
  "madolt-remote-manage should have a \\='C\\=' suffix for configuring URL."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-remote-manage)))
    (should (assoc "C" suffixes))
    (should (eq (cdr (assoc "C" suffixes))
                'madolt-remote-configure-url-command))))

(ert-deftest test-madolt-remote-configure-url-changes-url ()
  "madolt-remote-configure-url-command should change a remote's URL."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-remote-add "origin" "file:///tmp/old-url")
    (should (string= (cdr (assoc "origin" (madolt-remotes) #'string=))
                      "file:///tmp/old-url"))
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-remote-configure-url-command "origin" "file:///tmp/new-url"))
    (should (string= (cdr (assoc "origin" (madolt-remotes) #'string=))
                      "file:///tmp/new-url"))))

(ert-deftest test-madolt-remote-configure-url-empty-errors ()
  "madolt-remote-configure-url-command should error on empty URL."
  (should-error (madolt-remote-configure-url-command "origin" "")
                :type 'user-error))

(ert-deftest test-madolt-remote-configure-url-unchanged-is-noop ()
  "madolt-remote-configure-url-command should do nothing when URL unchanged."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-remote-add "origin" "file:///tmp/same-url")
    (let (remove-called)
      (cl-letf (((symbol-function 'madolt-remote-remove)
                 (lambda (name)
                   (setq remove-called name)
                   '(0 . ""))))
        (madolt-remote-configure-url-command "origin" "file:///tmp/same-url")
        ;; Should not have called remove since URL is the same
        (should-not remove-called)))))

(ert-deftest test-madolt-remote-configure-url-restores-on-failure ()
  "On add failure after remove, the old remote should be restored."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-remote-add "origin" "file:///tmp/original")
    (let (restore-called)
      (cl-letf (((symbol-function 'madolt-remote-remove)
                 (lambda (_name) '(0 . "")))
                ((symbol-function 'madolt-remote-add)
                 (lambda (name url)
                   (if (string= url "file:///tmp/bad-url")
                       '(1 . "error adding")
                     (setq restore-called (cons name url))
                     '(0 . ""))))
                ((symbol-function 'madolt-refresh) #'ignore))
        (should-error
         (madolt-remote-configure-url-command "origin" "file:///tmp/bad-url")
         :type 'user-error)
        ;; Should have tried to restore the old URL
        (should restore-called)
        (should (string= (car restore-called) "origin"))
        (should (string= (cdr restore-called) "file:///tmp/original"))))))

(provide 'madolt-remote-tests)
;;; madolt-remote-tests.el ends here
