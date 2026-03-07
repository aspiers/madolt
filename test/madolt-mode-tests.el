;;; madolt-mode-tests.el --- Tests for madolt-mode.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the major mode, buffer lifecycle, and refresh cycle.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt-test-helpers)
(require 'madolt-mode)

;;;; Major mode

(ert-deftest test-madolt-mode-derived-from-magit-section-mode ()
  "madolt-mode is derived from magit-section-mode."
  (with-temp-buffer
    (madolt-mode)
    (should (derived-mode-p 'magit-section-mode))))

(ert-deftest test-madolt-status-mode-derived ()
  "madolt-status-mode derives from madolt-mode."
  (with-temp-buffer
    (madolt-status-mode)
    (should (derived-mode-p 'madolt-mode))
    (should (derived-mode-p 'magit-section-mode))))

(ert-deftest test-madolt-diff-mode-derived ()
  "madolt-diff-mode derives from madolt-mode."
  (with-temp-buffer
    (madolt-diff-mode)
    (should (derived-mode-p 'madolt-mode))))

(ert-deftest test-madolt-log-mode-derived ()
  "madolt-log-mode derives from madolt-mode."
  (with-temp-buffer
    (madolt-log-mode)
    (should (derived-mode-p 'madolt-mode))))

;;;; Buffer lifecycle

(ert-deftest test-madolt-setup-buffer-creates-buffer ()
  "madolt-setup-buffer creates a buffer with the correct name."
  (madolt-with-test-database
    ;; Define a dummy refresh function for status mode
    (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
               (lambda () (magit-insert-section (root) (insert "test\n")))))
      (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
        (unwind-protect
            (progn
              (should (bufferp buf))
              (should (string-match-p "\\*madolt-status:" (buffer-name buf))))
          (kill-buffer buf))))))

(ert-deftest test-madolt-setup-buffer-reuses-existing ()
  "madolt-setup-buffer reuses an existing buffer."
  (madolt-with-test-database
    (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
               (lambda () (magit-insert-section (root) (insert "test\n")))))
      (let ((buf1 (madolt-setup-buffer 'madolt-status-mode)))
        (unwind-protect
            (let ((buf2 (madolt-setup-buffer 'madolt-status-mode)))
              (should (eq buf1 buf2)))
          (kill-buffer buf1))))))

(ert-deftest test-madolt-setup-buffer-sets-default-directory ()
  "madolt-setup-buffer sets default-directory to database root."
  (madolt-with-test-database
    (let ((db-dir (madolt-database-dir)))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda () (magit-insert-section (root) (insert "test\n")))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (with-current-buffer buf
                (should (equal default-directory db-dir)))
            (kill-buffer buf)))))))

(ert-deftest test-madolt-setup-buffer-activates-mode ()
  "madolt-setup-buffer activates the requested mode."
  (madolt-with-test-database
    (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
               (lambda () (magit-insert-section (root) (insert "test\n")))))
      (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
        (unwind-protect
            (with-current-buffer buf
              (should (derived-mode-p 'madolt-status-mode)))
          (kill-buffer buf))))))

(ert-deftest test-madolt-setup-buffer-calls-refresh ()
  "madolt-setup-buffer triggers a refresh."
  (madolt-with-test-database
    (let ((refreshed nil))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (setq refreshed t)
                   (magit-insert-section (root) (insert "refreshed\n")))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (should refreshed)
            (kill-buffer buf)))))))

(ert-deftest test-madolt-setup-buffer-errors-outside-dolt ()
  "madolt-setup-buffer errors when not in a dolt database."
  (let ((default-directory temporary-file-directory))
    (should-error (madolt-setup-buffer 'madolt-status-mode)
                  :type 'user-error)))

;;;; Refresh

(ert-deftest test-madolt-refresh-erases-and-reinserts ()
  "madolt-refresh erases buffer content and re-inserts."
  (madolt-with-test-database
    (let ((call-count 0))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (cl-incf call-count)
                   (magit-insert-section (root)
                     (insert (format "call %d\n" call-count))))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (with-current-buffer buf
                (should (= call-count 1))
                (should (string-match-p "call 1" (buffer-string)))
                (madolt-refresh)
                (should (= call-count 2))
                (should (string-match-p "call 2" (buffer-string)))
                ;; Old content should be gone
                (should-not (string-match-p "call 1" (buffer-string))))
            (kill-buffer buf)))))))

(ert-deftest test-madolt-refresh-function-convention ()
  "madolt--refresh-function follows mode name convention."
  (with-temp-buffer
    (madolt-status-mode)
    ;; Save and restore in case madolt-status.el has been loaded
    (let ((had-fn (fboundp 'madolt-status-refresh-buffer))
          (old-fn (and (fboundp 'madolt-status-refresh-buffer)
                       (symbol-function 'madolt-status-refresh-buffer))))
      (unwind-protect
          (progn
            ;; Without the function defined, should return nil
            (fmakunbound 'madolt-status-refresh-buffer)
            (should (null (madolt--refresh-function)))
            ;; Define it
            (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                       (lambda () nil)))
              (should (eq (madolt--refresh-function)
                          'madolt-status-refresh-buffer))))
        ;; Restore original binding
        (if had-fn
            (fset 'madolt-status-refresh-buffer old-fn)
          (fmakunbound 'madolt-status-refresh-buffer))))))

;;;; Keymap

(ert-deftest test-madolt-mode-map-g-refreshes ()
  "g triggers refresh via revert-buffer (inherited from special-mode)."
  ;; g is bound to revert-buffer in special-mode-map (grandparent),
  ;; and revert-buffer-function is set to madolt-refresh-buffer
  (should (eq (keymap-lookup madolt-mode-map "g") #'revert-buffer)))

(ert-deftest test-madolt-mode-map-q-quits ()
  "q is bound to quit-window in madolt-mode-map."
  (should (eq (keymap-lookup madolt-mode-map "q") #'quit-window)))

(ert-deftest test-madolt-mode-map-bindings-exist ()
  "All documented keybindings exist in madolt-mode-map."
  (let ((expected-bindings
         '(("g"   . revert-buffer)  ; inherited from special-mode-map
           ("q"   . quit-window)
           ("$"   . madolt-process-buffer)
           ("?"   . madolt-dispatch)
           ("h"   . madolt-dispatch)
           ("s"   . madolt-stage)
           ("S"   . madolt-stage-all)
           ("u"   . madolt-unstage)
           ("U"   . madolt-unstage-all)
           ("k"   . madolt-discard)
           ("c"   . madolt-commit)
           ("d"   . madolt-diff)
           ("l"   . madolt-log))))
    (dolist (binding expected-bindings)
      (should (eq (keymap-lookup madolt-mode-map (car binding))
                  (cdr binding))))))

;;;; Display

(ert-deftest test-madolt--buffer-name ()
  "Buffer names follow the expected pattern."
  (let ((name (madolt--buffer-name 'madolt-status-mode "/tmp/mydb/")))
    (should (string-match-p "\\*madolt-status: mydb\\*" name))))

(provide 'madolt-mode-tests)
;;; madolt-mode-tests.el ends here
