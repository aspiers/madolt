;;; madolt-commit-tests.el --- Tests for madolt-commit.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt commit transient and commit commands.

;;; Code:

(require 'ert)
(require 'ring)
(require 'madolt-commit)
(require 'madolt-dolt)
(require 'madolt-mode)
(require 'madolt-process)
(require 'madolt-test-helpers)

;;;; Transient

(ert-deftest test-madolt-commit-is-transient ()
  "madolt-commit should be a transient prefix."
  (should (get 'madolt-commit 'transient--layout)))

(ert-deftest test-madolt-commit-has-create-suffix ()
  "madolt-commit should have a 'c' suffix for commit create."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "c" all-keys))))

(ert-deftest test-madolt-commit-has-amend-suffix ()
  "madolt-commit should have an 'a' suffix for amend."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "a" all-keys))))

(ert-deftest test-madolt-commit-has-message-suffix ()
  "madolt-commit should have an 'm' suffix for message."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "m" all-keys))))

(ert-deftest test-madolt-commit-arguments ()
  "madolt-commit should have all documented argument switches."
  (let* ((layout (get 'madolt-commit 'transient--layout))
         (groups (aref layout 2))
         (all-args nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((arg (plist-get (cdr suffix) :argument)))
            (when arg (push arg all-args))))))
    (dolist (arg '("--all" "--ALL" "--allow-empty" "--force"
                   "--date=" "--author="))
      (should (member arg all-args)))))

;;;; Commit assertion

(ert-deftest test-madolt-commit-assert-with-staged-passes ()
  "Commit assert should pass when there are staged changes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Make a change and stage it
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-stage-all)
    ;; Should return (t . ARGS) since there are staged changes
    (let ((result (madolt-commit-assert nil)))
      (should result)
      (should (eq (car result) t)))))

(ert-deftest test-madolt-commit-assert-all-flag-passes ()
  "Commit assert should pass when --all is in args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    ;; Not staged, but --all is present
    (let ((result (madolt-commit-assert '("--all"))))
      (should result)
      (should (eq (car result) t))
      (should (member "--all" (cdr result))))))

(ert-deftest test-madolt-commit-assert-nothing-staged-aborts ()
  "Commit assert should return nil when nothing staged and user says no."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    ;; No changes at all — nothing to stage either
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (let ((result (madolt-commit-assert nil)))
        (should (null result))))))

(ert-deftest test-madolt-commit-assert-offers-stage-all ()
  "Commit assert should add --all when nothing staged and user says yes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    (madolt-test-update-row "t1" "id = 2" "id = 1")
    ;; Unstaged changes, nothing staged, user says yes
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (let ((result (madolt-commit-assert nil)))
        (should result)
        (should (eq (car result) t))
        (should (member "--all" (cdr result)))))))

;;;; Quick commit (madolt-commit--do-commit)

(ert-deftest test-madolt-commit-do-commit-creates-commit ()
  "madolt-commit--do-commit should create an actual dolt commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (madolt-commit--do-commit "Test commit message" nil)
    ;; Verify the commit exists in the log
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Test commit message")))))

(ert-deftest test-madolt-commit-do-commit-with-all-flag ()
  "madolt-commit--do-commit with --all should stage and commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Modify the table (not staged)
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    ;; --all stages modified tables automatically
    (madolt-commit--do-commit "Commit with --all" '("--all"))
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Commit with --all")))))

(ert-deftest test-madolt-commit-do-commit-amend ()
  "madolt-commit--do-commit with --amend should change the last commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Original message")
    ;; Amend the commit
    (madolt-commit--do-commit "Amended message" '("--amend"))
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Amended message")))))

;;;; Message ring

(ert-deftest test-madolt-commit-message-ring-saves ()
  "Committing should save the message to the ring."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    ;; Clear the ring first
    (setq madolt-commit--message-ring (make-ring 32))
    (madolt-commit--do-commit "Ring test message" nil)
    (should (not (ring-empty-p madolt-commit--message-ring)))
    (should (equal (ring-ref madolt-commit--message-ring 0)
                   "Ring test message"))))

(ert-deftest test-madolt-commit-message-ring-multiple ()
  "Multiple commits should accumulate in the ring."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-stage-all)
    (setq madolt-commit--message-ring (make-ring 32))
    (madolt-commit--do-commit "First" nil)
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-stage-all)
    (madolt-commit--do-commit "Second" nil)
    (should (= (ring-length madolt-commit--message-ring) 2))
    ;; Most recent first
    (should (equal (ring-ref madolt-commit--message-ring 0) "Second"))
    (should (equal (ring-ref madolt-commit--message-ring 1) "First"))))

;;;; Minibuffer commit (madolt-commit-message)

(ert-deftest test-madolt-commit-message-with-staged ()
  "madolt-commit-message should commit via minibuffer prompt."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Make change, stage, then commit via minibuffer command
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (_prompt &optional _initial &rest _)
                 "Minibuffer commit")))
      (madolt-commit-message nil))
    (let* ((entries (madolt-log-entries 1))
           (msg (plist-get (car entries) :message)))
      (should (equal msg "Minibuffer commit")))))

(ert-deftest test-madolt-commit-create-nothing-staged-abort ()
  "madolt-commit-create should abort when user declines staging."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    (let ((count-before (length (madolt-log-entries 10))))
      ;; No staged changes, user says no
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (madolt-commit-create nil))
      ;; Commit count should not have changed
      (should (= (length (madolt-log-entries 10)) count-before)))))

;;;; Commit message mode

(ert-deftest test-madolt-commit-message-mode-exists ()
  "madolt-commit-message-mode should be defined."
  (should (fboundp 'madolt-commit-message-mode)))

(ert-deftest test-madolt-commit-message-mode-derives-from-text-mode ()
  "madolt-commit-message-mode should derive from text-mode."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (should (derived-mode-p 'text-mode))))

(ert-deftest test-madolt-commit-message-mode-keybindings ()
  "madolt-commit-message-mode should bind C-c C-c and C-c C-k."
  (should (eq (lookup-key madolt-commit-message-mode-map (kbd "C-c C-c"))
              'madolt-commit-message-finish))
  (should (eq (lookup-key madolt-commit-message-mode-map (kbd "C-c C-k"))
              'madolt-commit-message-cancel))
  (should (eq (lookup-key madolt-commit-message-mode-map (kbd "M-p"))
              'madolt-commit-message-prev-history))
  (should (eq (lookup-key madolt-commit-message-mode-map (kbd "M-n"))
              'madolt-commit-message-next-history)))

;;;; Buffer setup

(ert-deftest test-madolt-commit-buffer-name ()
  "Buffer name should follow madolt naming convention."
  (madolt-with-test-database
    (let ((name (madolt-commit--buffer-name)))
      (should (string-prefix-p "madolt-commit: " name)))))

(ert-deftest test-madolt-commit-setup-buffer-creates-buffer ()
  "Setup should create a commit message buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (progn
            (should buf)
            (with-current-buffer buf
              (should (derived-mode-p 'madolt-commit-message-mode))))
        (when buf (kill-buffer buf))))))

(ert-deftest test-madolt-commit-setup-buffer-with-initial-message ()
  "Setup should pre-populate the buffer with initial message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer "Initial text" nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (should (string-match-p "Initial text"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))
        (when buf (kill-buffer buf))))))

(ert-deftest test-madolt-commit-setup-buffer-has-separator ()
  "Buffer should contain the comment separator."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (should (string-match-p "^# ---$"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))
        (when buf (kill-buffer buf))))))

(ert-deftest test-madolt-commit-setup-buffer-has-diff-reference ()
  "Buffer should show staged changes in comment section."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (let ((contents (buffer-substring-no-properties
                             (point-min) (point-max))))
              (should (string-match-p "# Changes to be committed:" contents))
              (should (string-match-p "t1" contents))))
        (when buf (kill-buffer buf))))))

(ert-deftest test-madolt-commit-setup-buffer-stores-args ()
  "Buffer should store transient args for later use."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil '("--force") nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (should (member "--force" madolt-commit--args)))
        (when buf (kill-buffer buf))))))

(ert-deftest test-madolt-commit-setup-buffer-amend-adds-flag ()
  "Amend mode should add --amend to stored args."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer "Old message" nil t))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (should (member "--amend" madolt-commit--args)))
        (when buf (kill-buffer buf))))))

;;;; Message extraction

(ert-deftest test-madolt-commit-extract-message-simple ()
  "Should extract a simple one-line message."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "Fix the bug\n")
    (let ((sep (point)))
      (insert "# ---\n# comment\n")
      (setq madolt-commit--separator-pos sep))
    (should (equal (madolt-commit--extract-message) "Fix the bug"))))

(ert-deftest test-madolt-commit-extract-message-with-body ()
  "Should extract summary + body separated by blank line."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "Add new feature\n\nThis is the body of the commit message.\nIt spans multiple lines.\n")
    (let ((sep (point)))
      (insert "# ---\n")
      (setq madolt-commit--separator-pos sep))
    (let ((msg (madolt-commit--extract-message)))
      (should (string-match-p "Add new feature" msg))
      (should (string-match-p "This is the body" msg))
      (should (string-match-p "\n\n" msg)))))

(ert-deftest test-madolt-commit-extract-message-strips-comments ()
  "Should strip comment lines starting with #."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "Real message\n# This is a comment\nMore text\n")
    (let ((sep (point)))
      (insert "# ---\n")
      (setq madolt-commit--separator-pos sep))
    (let ((msg (madolt-commit--extract-message)))
      (should (string-match-p "Real message" msg))
      (should (string-match-p "More text" msg))
      (should-not (string-match-p "comment" msg)))))

(ert-deftest test-madolt-commit-extract-message-empty-returns-nil ()
  "Should return nil for an empty message."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "\n")
    (let ((sep (point)))
      (insert "# ---\n# comment\n")
      (setq madolt-commit--separator-pos sep))
    (should (null (madolt-commit--extract-message)))))

(ert-deftest test-madolt-commit-extract-message-only-comments-returns-nil ()
  "Should return nil when only comment lines exist."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "# just a comment\n# another\n")
    (let ((sep (point)))
      (insert "# ---\n")
      (setq madolt-commit--separator-pos sep))
    (should (null (madolt-commit--extract-message)))))

;;;; Buffer history navigation

(ert-deftest test-madolt-commit-buffer-history-prev ()
  "M-p in buffer should insert previous message from ring."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "\n")
    (let ((sep (point)))
      (insert "# ---\n")
      (setq madolt-commit--separator-pos sep))
    (setq madolt-commit--message-ring (make-ring 32))
    (ring-insert madolt-commit--message-ring "Old commit msg")
    (setq madolt-commit--message-ring-index nil)
    (goto-char (point-min))
    (madolt-commit-message-prev-history)
    (let ((msg (madolt-commit--extract-message)))
      (should (equal msg "Old commit msg")))))

(ert-deftest test-madolt-commit-buffer-history-next ()
  "M-n in buffer should navigate forward in ring."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "\n")
    (let ((sep (point)))
      (insert "# ---\n")
      (setq madolt-commit--separator-pos sep))
    (setq madolt-commit--message-ring (make-ring 32))
    (ring-insert madolt-commit--message-ring "First")
    (ring-insert madolt-commit--message-ring "Second")
    (setq madolt-commit--message-ring-index nil)
    ;; Go back twice
    (madolt-commit-message-prev-history)
    (madolt-commit-message-prev-history)
    ;; Now forward once — should get "Second"
    (madolt-commit-message-next-history)
    (let ((msg (madolt-commit--extract-message)))
      (should (equal msg "Second")))))

(ert-deftest test-madolt-commit-buffer-history-empty-ring-errors ()
  "M-p with empty ring should signal an error."
  (with-temp-buffer
    (madolt-commit-message-mode)
    (insert "\n")
    (let ((sep (point)))
      (insert "# ---\n")
      (setq madolt-commit--separator-pos sep))
    (setq madolt-commit--message-ring (make-ring 32))
    (setq madolt-commit--message-ring-index nil)
    (should-error (madolt-commit-message-prev-history)
                  :type 'user-error)))

;;;; Full integration: buffer-based commit

(ert-deftest test-madolt-commit-buffer-finish-creates-commit ()
  "C-c C-c should create a commit from the buffer message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-stage-all)
    ;; Set up the commit buffer manually (suppress display)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            ;; Type a message in the editable area
            (goto-char (point-min))
            (insert "Buffer-based commit")
            ;; Simulate C-c C-c (suppress quit-window)
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (madolt-commit-message-finish))
            ;; Verify the commit was created
            (let* ((entries (madolt-log-entries 1))
                   (msg (plist-get (car entries) :message)))
              (should (equal msg "Buffer-based commit"))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-madolt-commit-buffer-finish-with-body ()
  "Commit with summary + body should preserve both in the message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (insert "Add feature\n\nThis is the body explaining why.")
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (madolt-commit-message-finish))
            (let* ((entries (madolt-log-entries 1))
                   (msg (plist-get (car entries) :message)))
              ;; Dolt stores the full message
              (should (string-match-p "Add feature" msg))
              (should (string-match-p "body explaining why" msg))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-madolt-commit-buffer-finish-empty-errors ()
  "C-c C-c with empty message should signal an error."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (should-error (madolt-commit-message-finish)
                          :type 'user-error))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-madolt-commit-buffer-finish-saves-to-ring ()
  "C-c C-c should save the message to the ring."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (setq madolt-commit--message-ring (make-ring 32))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer nil nil nil))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (insert "Saved to ring")
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (madolt-commit-message-finish))
            (should (equal (ring-ref madolt-commit--message-ring 0)
                           "Saved to ring")))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest test-madolt-commit-buffer-cancel-no-commit ()
  "C-c C-k should not create a commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (let ((count-before (length (madolt-log-entries 10))))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (madolt-commit--setup-buffer nil nil nil))
      (let ((buf (get-buffer (madolt-commit--buffer-name))))
        (unwind-protect
            (with-current-buffer buf
              (goto-char (point-min))
              (insert "This will be canceled")
              (cl-letf (((symbol-function 'quit-window) #'ignore))
                (madolt-commit-message-cancel))
              ;; Commit count unchanged
              (should (= (length (madolt-log-entries 10))
                         count-before)))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest test-madolt-commit-buffer-amend-integration ()
  "Amend via buffer should change the last commit message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Original msg")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (madolt-commit--setup-buffer "Original msg" nil t))
    (let ((buf (get-buffer (madolt-commit--buffer-name))))
      (unwind-protect
          (with-current-buffer buf
            ;; Verify pre-populated message
            (should (string-match-p "Original msg"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            ;; Replace with new message using the provided API
            (madolt-commit--replace-message-text "Amended msg")
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (madolt-commit-message-finish))
            (let* ((entries (madolt-log-entries 1))
                   (msg (plist-get (car entries) :message)))
              (should (equal msg "Amended msg"))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; Diff reference section

(ert-deftest test-madolt-commit-diff-reference-staged ()
  "Diff reference should show staged tables."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-stage-all)
    (with-temp-buffer
      (madolt-commit--insert-diff-reference default-directory nil)
      (let ((contents (buffer-string)))
        (should (string-match-p "# Changes to be committed:" contents))
        (should (string-match-p "t1" contents))))))

(ert-deftest test-madolt-commit-diff-reference-with-all ()
  "Diff reference with --all should show unstaged changes too."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Initial")
    ;; Unstaged modification
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (with-temp-buffer
      (madolt-commit--insert-diff-reference default-directory '("--all"))
      (let ((contents (buffer-string)))
        (should (string-match-p "t1" contents))))))

(ert-deftest test-madolt-commit-diff-reference-no-changes ()
  "Diff reference should show (no changes) when nothing staged."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    ;; Clean state — nothing staged
    (with-temp-buffer
      (madolt-commit--insert-diff-reference default-directory nil)
      (let ((contents (buffer-string)))
        (should (string-match-p "(no changes)" contents))))))

(provide 'madolt-commit-tests)
;;; madolt-commit-tests.el ends here
