;;; madolt-mode-tests.el --- Tests for madolt-mode.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the major mode, buffer lifecycle, and refresh cycle.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt-test-helpers)
(require 'madolt)
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
  "g is bound to madolt-refresh in madolt-mode-map."
  (should (eq (keymap-lookup madolt-mode-map "g") #'madolt-refresh)))

(ert-deftest test-madolt-mode-map-q-quits ()
  "q is bound to quit-window in madolt-mode-map."
  (should (eq (keymap-lookup madolt-mode-map "q") #'quit-window)))

(ert-deftest test-madolt-mode-map-bindings-exist ()
  "All documented keybindings exist in madolt-mode-map."
  (let ((expected-bindings
         '(("g"   . madolt-refresh)
           ("j"   . madolt-status-jump)
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

;;;; Copy section value

(ert-deftest test-madolt-mode-map-has-copy ()
  "The mode map should bind 'w' to madolt-copy-section-value."
  (should (eq (keymap-lookup madolt-mode-map "w")
              #'madolt-copy-section-value)))

(ert-deftest test-madolt-copy-section-value-copies-table ()
  "madolt-copy-section-value copies the table name to kill ring."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (child-section nil))
      (magit-insert-section (root)
        (setq child-section
              (magit-insert-section (table "my_table")
                (insert "  modified    my_table\n"))))
      ;; Position on the child section
      (goto-char (oref child-section start))
      (should (eq (oref (magit-current-section) type) 'table))
      (madolt-copy-section-value)
      (should (equal (car kill-ring) "my_table")))))

(ert-deftest test-madolt-copy-section-value-copies-commit-hash ()
  "madolt-copy-section-value copies the commit hash to kill ring."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (child-section nil))
      (magit-insert-section (root)
        (setq child-section
              (magit-insert-section (commit "abc12345def67890")
                (insert "  abc12345  Initial commit\n"))))
      (goto-char (oref child-section start))
      (should (eq (oref (magit-current-section) type) 'commit))
      (madolt-copy-section-value)
      (should (equal (car kill-ring) "abc12345def67890")))))

(ert-deftest test-madolt-copy-section-value-errors-on-no-value ()
  "madolt-copy-section-value errors when section has no value."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (child-section nil))
      (magit-insert-section (root)
        (setq child-section
              (magit-insert-section (staged)
                (magit-insert-heading "Staged changes")
                (insert "  content\n"))))
      (goto-char (oref child-section start))
      (should-error (madolt-copy-section-value) :type 'user-error))))

;;;; Show more (row-limit expansion)

(ert-deftest test-madolt-mode-map-has-show-more ()
  "The mode map should bind '+' to madolt-show-more."
  (should (eq (keymap-lookup madolt-mode-map "+")
              #'madolt-show-more)))

(ert-deftest test-madolt-insert-show-more-button-creates-section ()
  "madolt-insert-show-more-button inserts a longer section with a button."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (longer-section nil))
      (magit-insert-section (root)
        (setq longer-section
              (madolt-insert-show-more-button
               5 10 'madolt-mode-map 'madolt-show-more)))
      (should longer-section)
      (should (eq (oref longer-section type) 'longer)))))

(ert-deftest test-madolt-insert-show-more-button-shows-counts ()
  "madolt-insert-show-more-button shows shown/total counts and next."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (root)
        (madolt-insert-show-more-button
         5 10 'madolt-mode-map 'madolt-show-more)))
    (let ((text (buffer-string)))
      (should (string-match-p "5 of 10 shown" text))
      (should (string-match-p "next: 10" text)))))

(ert-deftest test-madolt-insert-show-more-button-unknown-total ()
  "madolt-insert-show-more-button handles nil total."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (root)
        (madolt-insert-show-more-button
         5 nil 'madolt-mode-map 'madolt-show-more)))
    (let ((text (buffer-string)))
      (should (string-match-p "5 shown" text))
      (should-not (string-match-p "of" text))
      (should (string-match-p "next: 10" text)))))

(ert-deftest test-madolt-insert-show-more-button-next-capped-at-total ()
  "Next count should not exceed total."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (root)
        (madolt-insert-show-more-button
         8 12 'madolt-mode-map 'madolt-show-more)))
    (let ((text (buffer-string)))
      ;; 8*2=16 but total is 12, so next should be 12
      (should (string-match-p "next: 12" text)))))

(ert-deftest test-madolt-insert-show-more-button-keybinding-shows-plus ()
  "Button label should show the + keybinding, not M-x."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (root)
        (madolt-insert-show-more-button
         5 10 'madolt-mode-map 'madolt-show-more)))
    (let ((text (buffer-string)))
      (should (string-match-p "Type \\+" text))
      (should-not (string-match-p "M-x" text)))))

(ert-deftest test-madolt-insert-show-more-button-has-text-button ()
  "The show-more section contains an Emacs text button."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (longer-section nil))
      (magit-insert-section (root)
        (setq longer-section
              (madolt-insert-show-more-button
               5 10 'madolt-mode-map 'madolt-show-more)))
      (goto-char (oref longer-section start))
      (should (button-at (point))))))

(ert-deftest test-madolt-show-more-activates-button ()
  "madolt-show-more calls the double function via the button."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (called nil)
          (longer-section nil))
      (cl-letf (((symbol-function 'madolt-test-double-fn)
                 (lambda ()
                   (interactive)
                   (setq called t))))
        (magit-insert-section (root)
          (magit-insert-section (items)
            (insert "some content\n"))
          (setq longer-section
                (madolt-insert-show-more-button
                 5 10 'madolt-mode-map 'madolt-test-double-fn)))
        ;; Position on the longer section
        (goto-char (oref longer-section start))
        (madolt-show-more)
        (should called)))))

(ert-deftest test-madolt-show-more-errors-when-nothing-to-expand ()
  "madolt-show-more errors when there is no longer section."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (root)
        (insert "no expandable sections\n")))
    (goto-char (point-min))
    (should-error (madolt-show-more) :type 'user-error)))

(ert-deftest test-madolt-show-more-finds-longer-section ()
  "madolt-show-more finds and activates a longer section from elsewhere."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (called nil)
          (items-section nil))
      (cl-letf (((symbol-function 'madolt-test-double-fn)
                 (lambda ()
                   (interactive)
                   (setq called t))))
        (magit-insert-section (root)
          (setq items-section
                (magit-insert-section (items)
                  (insert "some content\n")))
          (madolt-insert-show-more-button
           5 10 'madolt-mode-map 'madolt-test-double-fn))
        ;; Position on the items section, not the longer section
        (goto-char (oref items-section start))
        (should-not (eq (oref (magit-current-section) type) 'longer))
        (madolt-show-more)
        (should called)))))

(ert-deftest test-madolt-maybe-show-more-respects-flag ()
  "madolt-maybe-show-more only activates when madolt-auto-show-more is set."
  (with-temp-buffer
    (madolt-mode)
    (let ((inhibit-read-only t)
          (called nil)
          (longer-section nil))
      (cl-letf (((symbol-function 'madolt-test-double-fn)
                 (lambda ()
                   (interactive)
                   (setq called t))))
        (magit-insert-section (root)
          (setq longer-section
                (madolt-insert-show-more-button
                 5 10 'madolt-mode-map 'madolt-test-double-fn)))
        (goto-char (oref longer-section start))
        ;; With flag off (default), should not activate
        (let ((madolt-auto-show-more nil))
          (madolt-maybe-show-more longer-section)
          (should-not called))
        ;; With flag on, should activate
        (let ((madolt-auto-show-more t))
          (madolt-maybe-show-more longer-section)
          (should called))))))

(ert-deftest test-madolt-auto-show-more-default-off ()
  "madolt-auto-show-more defaults to nil."
  (should-not madolt-auto-show-more))

;;;; Point preservation across refresh

(ert-deftest test-madolt-refresh-preserves-point-on-same-section ()
  "After refresh, point stays on the same section if it still exists."
  (madolt-with-test-database
    (let ((render-variant 'both))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (status)
                     (magit-insert-section (unstaged)
                       (magit-insert-heading "Unstaged changes")
                       (magit-insert-section (table "users")
                         (insert "  modified    users\n"))
                       (when (eq render-variant 'both)
                         (magit-insert-section (table "orders")
                           (insert "  modified    orders\n"))))
                     (magit-insert-section (staged)
                       (magit-insert-heading "Staged changes")
                       (magit-insert-section (table "products")
                         (insert "  modified    products\n")))))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (with-current-buffer buf
                ;; Navigate to "orders" table entry
                (goto-char (point-min))
                (let ((found nil))
                  (magit-section-show magit-root-section)
                  (while (not (eobp))
                    (when (and (magit-current-section)
                               (eq (oref (magit-current-section) type) 'table)
                               (equal (oref (magit-current-section) value) "orders"))
                      (setq found (point))
                      (goto-char (point-max)))
                    (unless found (forward-line 1)))
                  (should found)
                  (goto-char found))
                ;; Refresh — "orders" still exists
                (madolt-refresh)
                ;; Point should be on a table section with value "orders"
                (should (magit-current-section))
                (should (eq (oref (magit-current-section) type) 'table))
                (should (equal (oref (magit-current-section) value) "orders")))
            (kill-buffer buf)))))))

(ert-deftest test-madolt-refresh-falls-back-to-sibling ()
  "When section disappears, point moves to a sibling section."
  (madolt-with-test-database
    (let ((render-variant 'both))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (status)
                     (magit-insert-section (unstaged)
                       (magit-insert-heading "Unstaged changes")
                       (magit-insert-section (table "users")
                         (insert "  modified    users\n"))
                       (when (eq render-variant 'both)
                         (magit-insert-section (table "orders")
                           (insert "  modified    orders\n"))))))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (with-current-buffer buf
                ;; Navigate to "orders" table entry
                (goto-char (point-min))
                (let ((found nil))
                  (magit-section-show magit-root-section)
                  (while (not (eobp))
                    (when (and (magit-current-section)
                               (eq (oref (magit-current-section) type) 'table)
                               (equal (oref (magit-current-section) value) "orders"))
                      (setq found (point))
                      (goto-char (point-max)))
                    (unless found (forward-line 1)))
                  (should found)
                  (goto-char found))
                ;; Remove "orders" from next render
                (setq render-variant 'users-only)
                (madolt-refresh)
                ;; Point should NOT be at buffer start — should be on
                ;; a remaining section (sibling "users" or parent "unstaged")
                (should (> (point) (point-min)))
                (should (magit-current-section))
                ;; Should land on either the sibling table or the parent heading
                (let ((type (oref (magit-current-section) type)))
                  (should (memq type '(table unstaged)))))
            (kill-buffer buf)))))))

(ert-deftest test-madolt-refresh-falls-back-to-opposite-section ()
  "When unstaged section disappears, point moves to staged (opposite)."
  (madolt-with-test-database
    (let ((render-variant 'unstaged))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (status)
                     (when (eq render-variant 'unstaged)
                       (magit-insert-section (unstaged)
                         (magit-insert-heading "Unstaged changes")
                         (magit-insert-section (table "users")
                           (insert "  modified    users\n"))))
                     (magit-insert-section (staged)
                       (magit-insert-heading "Staged changes")
                       (magit-insert-section (table "products")
                         (insert "  modified    products\n")))))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (with-current-buffer buf
                ;; Navigate to the unstaged section heading
                (goto-char (point-min))
                (let ((found nil))
                  (magit-section-show magit-root-section)
                  (while (not (eobp))
                    (when (and (magit-current-section)
                               (eq (oref (magit-current-section) type) 'unstaged))
                      (setq found (point))
                      (goto-char (point-max)))
                    (unless found (forward-line 1)))
                  (should found)
                  (goto-char found))
                ;; Remove the unstaged section
                (setq render-variant 'staged-only)
                (madolt-refresh)
                ;; Point should land on the opposite section: staged
                (should (magit-current-section))
                (should (eq (oref (magit-current-section) type) 'staged)))
            (kill-buffer buf)))))))

(ert-deftest test-madolt-refresh-falls-back-to-point-min ()
  "When no sections exist after refresh, point goes to point-min."
  (madolt-with-test-database
    (let ((render-variant 'full))
      (cl-letf (((symbol-function 'madolt-status-refresh-buffer)
                 (lambda ()
                   (magit-insert-section (status)
                     (if (eq render-variant 'full)
                         (magit-insert-section (unstaged)
                           (magit-insert-heading "Unstaged changes")
                           (magit-insert-section (table "users")
                             (insert "  modified    users\n")))
                       (insert "Nothing to show\n"))))))
        (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
          (unwind-protect
              (with-current-buffer buf
                ;; Navigate to "users" table
                (goto-char (point-min))
                (let ((found nil))
                  (magit-section-show magit-root-section)
                  (while (not (eobp))
                    (when (and (magit-current-section)
                               (eq (oref (magit-current-section) type) 'table)
                               (equal (oref (magit-current-section) value) "users"))
                      (setq found (point))
                      (goto-char (point-max)))
                    (unless found (forward-line 1)))
                  (should found)
                  (goto-char found))
                ;; Refresh with empty content (no matching sections)
                (setq render-variant 'empty)
                (madolt-refresh)
                ;; Point should be at the start
                (should (= (point) (point-min))))
            (kill-buffer buf)))))))

;;;; Display

(ert-deftest test-madolt--buffer-name ()
  "Buffer names follow the expected pattern."
  (let ((name (madolt--buffer-name 'madolt-status-mode "/tmp/mydb/")))
    (should (string-match-p "\\*madolt-status: mydb\\*" name))))

(provide 'madolt-mode-tests)
;;; madolt-mode-tests.el ends here
