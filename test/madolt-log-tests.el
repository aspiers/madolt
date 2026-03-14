;;; madolt-log-tests.el --- Tests for madolt-log.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the madolt commit log viewer.

;;; Code:

(require 'ert)
(require 'magit-section)
(require 'madolt-log)
(require 'madolt-dolt)
(require 'madolt-diff)
(require 'madolt-mode)
(require 'madolt-test-helpers)

;;;; Helper: collect sections of a given type from a buffer

(defun madolt-log-test--sections-of-type (type)
  "Return a list of sections of TYPE in the current buffer."
  (let ((result nil))
    (when magit-root-section
      (madolt-test--walk-sections
       (lambda (s) (when (eq (oref s type) type) (push s result)))
       magit-root-section))
    (nreverse result)))

;;;; Helper: set up a multi-commit database

(defun madolt-log-test-setup-multi-commit ()
  "Create a test database with multiple commits.
Returns in a state with 3 user commits plus the init commit."
  (madolt-test-create-table "t1" "id INT PRIMARY KEY, val TEXT")
  (madolt-test-insert-row "t1" "(1, 'first')")
  (madolt-test-commit "First commit")
  (madolt-test-update-row "t1" "val = 'second'" "id = 1")
  (madolt-test-commit "Second commit")
  (madolt-test-insert-row "t1" "(2, 'third')")
  (madolt-test-commit "Third commit"))

;;;; Transient

(ert-deftest test-madolt-log-is-transient ()
  "madolt-log should be a transient prefix."
  (should (get 'madolt-log 'transient--layout)))

(ert-deftest test-madolt-log-has-current-suffix ()
  "madolt-log should have an 'l' suffix for current branch."
  (let* ((layout (get 'madolt-log 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "l" all-keys))))

(ert-deftest test-madolt-log-has-other-suffix ()
  "madolt-log should have an 'o' suffix for other branch."
  (let* ((layout (get 'madolt-log 'transient--layout))
         (groups (aref layout 2))
         (all-keys nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((key (plist-get (cdr suffix) :key)))
            (when key (push key all-keys))))))
    (should (member "o" all-keys))))

(ert-deftest test-madolt-log-arguments ()
  "madolt-log should have documented argument switches."
  (let* ((layout (get 'madolt-log 'transient--layout))
         (groups (aref layout 2))
         (all-args nil))
    (dolist (group groups)
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((arg (plist-get (cdr suffix) :argument)))
            (when arg (push arg all-args))))))
    (dolist (arg '("--stat" "--merges" "--graph"))
      (should (member arg all-args)))))

(ert-deftest test-madolt-log-has-all-suffix ()
  "madolt-log should have an \\='a\\=' suffix for all branches."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log)))
    (should (assoc "a" suffixes))
    (should (eq (cdr (assoc "a" suffixes)) 'madolt-log-all))))

(ert-deftest test-madolt-log-all-shows-commits ()
  "madolt-log-all should show commits from all branches."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (let (called-rev called-args)
      (cl-letf (((symbol-function 'madolt-log--show)
                 (lambda (rev args)
                   (setq called-rev rev)
                   (setq called-args args))))
        (madolt-log-all nil)
        (should (string= called-rev "--all"))
        (should (member "--all" called-args))))))

(ert-deftest test-madolt-log-all-no-duplicate-flag ()
  "madolt-log-all should not duplicate --all if already in args."
  (let (called-args)
    (cl-letf (((symbol-function 'madolt-log--show)
               (lambda (_rev args)
                 (setq called-args args))))
      (madolt-log-all '("--all" "--stat"))
      (should (equal (cl-count "--all" called-args :test #'string=) 1)))))

;;;; Log auto-refresh

(ert-deftest test-madolt-log-show-always-refreshes ()
  "madolt-log--show should refresh even when buffer already exists."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (let ((refresh-count 0))
      (cl-letf (((symbol-function 'madolt-display-buffer) #'ignore))
        ;; Open log first time — should refresh
        (advice-add 'madolt-log-refresh-buffer :before
                    (lambda () (cl-incf refresh-count))
                    '((name . test-counter)))
        (unwind-protect
            (progn
              (madolt-log--show "main" nil)
              (should (= refresh-count 1))
              ;; Open again with same params — should still refresh
              (madolt-log--show "main" nil)
              (should (= refresh-count 2)))
          (advice-remove 'madolt-log-refresh-buffer 'test-counter))))))

;;;; Faces

(ert-deftest test-madolt-log-faces-defined ()
  "All log faces should be defined."
  (dolist (face '(madolt-log-date
                  madolt-log-author
                  madolt-log-graph))
    (should (facep face))))

;;;; Ref label formatting

(ert-deftest test-madolt-format-ref-labels-local-branch ()
  "Local branch names should use madolt-branch-local face."
  (let ((result (madolt-format-ref-labels "main")))
    (should (string-match-p "main" result))
    (should (eq (get-text-property 1 'font-lock-face result)
                'madolt-branch-local))))

(ert-deftest test-madolt-format-ref-labels-head-current ()
  "HEAD -> branch should show @ with madolt-head and branch with madolt-branch-current."
  (let ((result (madolt-format-ref-labels "HEAD -> main")))
    ;; Should contain @ for HEAD
    (should (string-match-p "@" result))
    ;; Find the @ character and check its face
    (let ((at-pos (string-match "@" result)))
      (should (eq (get-text-property at-pos 'font-lock-face result)
                  'madolt-head)))
    ;; Find "main" and check its face
    (let ((main-pos (string-match "main" result)))
      (should (eq (get-text-property main-pos 'font-lock-face result)
                  'madolt-branch-current)))))

(ert-deftest test-madolt-format-ref-labels-tag ()
  "Tags should use madolt-tag face."
  (let ((result (madolt-format-ref-labels "tag: v1.0")))
    (should (string-match-p "v1.0" result))
    ;; tag: prefix should be stripped; v1.0 should have tag face
    (should-not (string-match-p "tag:" result))
    (let ((pos (string-match "v1.0" result)))
      (should (eq (get-text-property pos 'font-lock-face result)
                  'madolt-tag)))))

(ert-deftest test-madolt-format-ref-labels-remote ()
  "Remote branches should use madolt-branch-remote face."
  (let ((result (madolt-format-ref-labels "origin/main" '("origin"))))
    (should (string-match-p "origin/main" result))
    (let ((pos (string-match "origin/main" result)))
      (should (eq (get-text-property pos 'font-lock-face result)
                  'madolt-branch-remote)))))

(ert-deftest test-madolt-format-ref-labels-multiple ()
  "Multiple refs should each get their own face."
  (let ((result (madolt-format-ref-labels
                 "HEAD -> main, tag: v1.0, origin/main"
                 '("origin"))))
    ;; Should contain all refs
    (should (string-match-p "@" result))
    (should (string-match-p "main" result))
    (should (string-match-p "v1.0" result))
    (should (string-match-p "origin/main" result))
    ;; Should be wrapped in parens
    (should (string-prefix-p "(" result))
    (should (string-suffix-p ")" result))))

(ert-deftest test-madolt-format-ref-labels-head-detached ()
  "Detached HEAD should show @ with madolt-head face."
  (let ((result (madolt-format-ref-labels "HEAD")))
    (let ((at-pos (string-match "@" result)))
      (should at-pos)
      (should (eq (get-text-property at-pos 'font-lock-face result)
                  'madolt-head)))))

(ert-deftest test-madolt-format-ref-labels-slash-branch-is-local ()
  "Branches with slashes like feature/foo should be local, not remote."
  (let ((result (madolt-format-ref-labels "feature/foo")))
    (let ((pos (string-match "feature/foo" result)))
      (should (eq (get-text-property pos 'font-lock-face result)
                  'madolt-branch-local))))
  ;; Even with remotes configured, feature/ is not a known remote
  (let ((result (madolt-format-ref-labels "feature/foo" '("origin"))))
    (let ((pos (string-match "feature/foo" result)))
      (should (eq (get-text-property pos 'font-lock-face result)
                  'madolt-branch-local)))))

(ert-deftest test-madolt-format-ref-labels-wrapped-in-parens ()
  "Result should be wrapped in parentheses."
  (let ((result (madolt-format-ref-labels "main")))
    (should (string-prefix-p "(" result))
    (should (string-suffix-p ")" result))))

(ert-deftest test-madolt-format-ref-labels-ordering ()
  "Refs should be ordered: HEAD, tags, local branches, remotes."
  (let ((result (madolt-format-ref-labels
                 "origin/main, tag: v1.0, feature, HEAD -> main"
                 '("origin"))))
    ;; @ (HEAD) should come before v1.0 (tag)
    (should (< (string-match "@" result)
               (string-match "v1.0" result)))
    ;; v1.0 (tag) should come before feature (local branch)
    (should (< (string-match "v1.0" result)
               (string-match "feature" result)))
    ;; feature (local) should come before origin/main (remote)
    (should (< (string-match "feature" result)
               (string-match "origin/main" result)))))

;;;; Log refresh

(ert-deftest test-madolt-log-refresh-shows-commits ()
  "Log refresh should show commit sections."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should have commit sections
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        ;; At least 3 user commits + 1 init commit
        (should (>= (length commits) 4))))))

(ert-deftest test-madolt-log-commit-section-values ()
  "Each commit section should have the commit hash as its value."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        (dolist (section commits)
          (let ((hash (oref section value)))
            ;; Dolt hashes are 32-char base32 strings
            (should (stringp hash))
            (should (= (length hash) 32))))))))

(ert-deftest test-madolt-log-commit-shows-message ()
  "Each commit section should display its message."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "First commit" text))
        (should (string-match-p "Second commit" text))
        (should (string-match-p "Third commit" text))))))

(ert-deftest test-madolt-log-commit-shows-hash ()
  "Log should display abbreviated commit hashes."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Get the first commit hash and check abbreviated form appears
      (let* ((commits (madolt-log-test--sections-of-type 'commit))
             (hash (oref (car commits) value))
             (short (substring hash 0 8))
             (text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p (regexp-quote short) text))))))

(ert-deftest test-madolt-log-no-ansi ()
  "Log output should not contain ANSI escape sequences."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not (string-match-p "\033\\[" text))))))

(ert-deftest test-madolt-log-heading ()
  "Log buffer should show heading with branch name."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Commits on main:" text))))))

(ert-deftest test-madolt-log-single-commit ()
  "Log should work with a database that has only the init commit."
  (madolt-with-test-database
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should have at least 1 commit (init)
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        (should (>= (length commits) 1))))))

(ert-deftest test-madolt-log-limit ()
  "Log should respect the limit parameter."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 2)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      (let ((commits (madolt-log-test--sections-of-type 'commit)))
        (should (= (length commits) 2))))))

(ert-deftest test-madolt-log-show-more-button-when-at-limit ()
  "Show-more button should appear when entries equal the limit."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      ;; 4 commits total (3 user + 1 init); set limit to 2
      (setq madolt-log--limit 2)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should have a longer section
      (let ((longer (madolt-log-test--sections-of-type 'longer)))
        (should (= 1 (length longer))))
      ;; Button text should mention "show more"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "show more" text))))))

(ert-deftest test-madolt-log-no-show-more-when-under-limit ()
  "Show-more button should NOT appear when entries are fewer than the limit."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      ;; 4 commits total; set limit higher
      (setq madolt-log--limit 100)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Should NOT have a longer section
      (let ((longer (madolt-log-test--sections-of-type 'longer)))
        (should (= 0 (length longer)))))))

(ert-deftest test-madolt-log-double-limit ()
  "madolt-log-double-limit should double the limit."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--limit 25)
    ;; Mock madolt-refresh to avoid needing a real database
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-log-double-limit))
    (should (= madolt-log--limit 50))))

;;;; Graph rendering

(ert-deftest test-madolt-log-graph-shows-asterisks ()
  "Log with --graph should show * graph markers in the buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "first")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "second")
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--args '("--graph"))
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Each commit line should start with graph decoration containing *
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^\\* " text))))))

(ert-deftest test-madolt-log-graph-absent-without-flag ()
  "Log without --graph should not show * graph markers."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "first")
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--args nil)
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; No line should start with "* "
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not (string-match-p "^\\* " text))))))

(ert-deftest test-madolt-log-graph-face ()
  "Graph decoration should use madolt-log-graph face."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "first")
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--args '("--graph"))
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Find the * character and check its face
      (goto-char (point-min))
      ;; Skip the heading line
      (forward-line 1)
      (let ((face (get-text-property (point) 'font-lock-face)))
        (should (eq face 'madolt-log-graph))))))

;;;; Margin alignment

(ert-deftest test-madolt-log-margin-author-padded ()
  "Author in margin should be padded to madolt-log-author-width."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Check that margin overlays exist with proper alignment
      (let ((overlays (overlays-in (point-min) (point-max))))
        (should (cl-some
                 (lambda (o)
                   (let ((before (overlay-get o 'before-string)))
                     (and before (get-text-property 0 'display before))))
                 overlays))))))

(ert-deftest test-madolt-log-margin-date-right-aligned ()
  "Dates in margin should be right-aligned within the margin width.
All margin strings should have the same total width."
  (madolt-with-test-database
    (madolt-log-test-setup-multi-commit)
    (with-temp-buffer
      (madolt-log-mode)
      (setq madolt-log--rev "main")
      (setq madolt-log--limit 25)
      (let ((inhibit-read-only t))
        (madolt-log-refresh-buffer))
      ;; Collect margin text widths — they should all be equal
      ;; (each margin string is padded to madolt-log-margin-width)
      (let ((widths nil))
        (dolist (o (overlays-in (point-min) (point-max)))
          (let* ((before (overlay-get o 'before-string))
                 (display (and before (get-text-property 0 'display before))))
            (when (and (listp display)
                       (eq (caar display) 'margin))
              (push (length (cadr display)) widths))))
        ;; All widths should be equal (right-aligned = same total width)
        (when (> (length widths) 1)
          (should (= 1 (length (delete-dups widths)))))))))

;;;; Branch name completion

(ert-deftest test-madolt-log-branch-names ()
  "madolt-branch-names should return branch names."
  (madolt-with-test-database
    (let ((names (madolt-branch-names)))
      (should (member "main" names)))))

;;;; Log helpers

(ert-deftest test-madolt-log-format-date ()
  "Should format dates as relative ages (e.g. \"3 hours\")."
  ;; Valid date produces a relative age like "N unit(s)"
  (should (string-match-p "^[0-9]+ [a-z]+$"
                          (madolt-log--format-date "2026-03-07 12:00:00")))
  ;; Dolt's native format also works
  (should (string-match-p "^[0-9]+ [a-z]+$"
                          (madolt-log--format-date
                           "Sat Mar 07 12:00:00 +0000 2026")))
  ;; nil input returns nil
  (should (null (madolt-log--format-date nil))))

(ert-deftest test-madolt-log-short-author ()
  "Should strip email from author string."
  (should (equal (madolt-log--short-author "Alice <alice@ex.com>")
                 "Alice"))
  ;; No email — return as-is
  (should (equal (madolt-log--short-author "Alice")
                 "Alice")))

(ert-deftest test-madolt-log-parent-hash ()
  "Should find parent hash of a commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First")
    (madolt-test-update-row "t1" "id = 2" "id = 1")
    (madolt-test-commit "Second")
    (let* ((entries (madolt-log-entries 2))
           (newest (car entries))
           (oldest (cadr entries))
           (parent (madolt-log--parent-hash (plist-get newest :hash))))
      (should parent)
      (should (equal parent (plist-get oldest :hash))))))

;;;; Revision buffer

(ert-deftest test-madolt-log-revision-mode ()
  "madolt-revision-mode should derive from madolt-diff-mode."
  (should (get 'madolt-revision-mode 'derived-mode-parent)))

(ert-deftest test-madolt-log-revision-default-visibility ()
  "Revision mode should default to level 2 (table-diffs shown, row-diffs hidden)."
  (with-temp-buffer
    (madolt-revision-mode)
    (let ((alist magit-section-initial-visibility-alist))
      (should (eq (alist-get 'table-diff alist) 'show))
      (should (eq (alist-get 'row-diff alist) 'hide)))))

(ert-deftest test-madolt-log-revision-shows-metadata ()
  "Revision buffer should show commit metadata."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "Test revision commit")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          ;; Should show the full hash
          (should (string-match-p (regexp-quote hash) text))
          ;; Should show the message
          (should (string-match-p "Test revision commit" text))
          ;; Should show Author
          (should (string-match-p "Author:" text)))))))

(ert-deftest test-madolt-log-extract-limit ()
  "Should extract -n limit from args."
  (should (eq (madolt-log--extract-limit '("-n25")) 25))
  (should (eq (madolt-log--extract-limit '("-n10" "--stat")) 10))
  (should (eq (madolt-log--extract-limit '("--stat")) nil)))

;;;; Merge commit parsing

(ert-deftest test-madolt-log-entries-parents-for-normal ()
  "Normal commits should have a single parent hash in :parents.
The initial commit (from dolt init) should have nil :parents."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "Second")
    ;; Get enough entries to include the dolt init commit
    (let* ((entries (madolt-log-entries 10))
           (newest (car entries))
           (second (cadr entries))
           (initial (car (last entries))))
      ;; Normal commit has exactly one parent
      (should (= 1 (length (plist-get newest :parents))))
      (should (equal (car (plist-get newest :parents))
                     (plist-get second :hash)))
      ;; Initial commit (dolt init) has no parents
      (should-not (plist-get initial :parents)))))

(ert-deftest test-madolt-log-entries-parents-for-merge ()
  "Merge commits should have :parents with two hashes."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    ;; Create divergent branch
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "-b" "feat")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "feat commit")
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "main")
    (madolt-test-insert-row "t1" "(3)")
    (madolt-test-commit "main commit")
    ;; Merge with --no-ff to force merge commit
    (call-process madolt-dolt-executable nil nil nil
                  "merge" "feat" "--no-ff" "-m" "Merge feat")
    (let* ((entry (car (madolt-log-entries 1))))
      (should (plist-get entry :parents))
      (should (= 2 (length (plist-get entry :parents))))
      (should (equal "Merge feat" (plist-get entry :message))))))

;;;; Diff statistics

(ert-deftest test-madolt-diff-table-stat-added ()
  "Should count added rows."
  (let ((table-data '((name . "t1")
                      (schema_diff)
                      (data_diff ((from_row) (to_row (id . 1)))
                                 ((from_row) (to_row (id . 2)))))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (equal "t1" (plist-get stat :name)))
      (should (= 2 (plist-get stat :added)))
      (should (= 0 (plist-get stat :deleted)))
      (should (= 0 (plist-get stat :modified))))))

(ert-deftest test-madolt-diff-table-stat-deleted ()
  "Should count deleted rows."
  (let ((table-data '((name . "t1")
                      (schema_diff)
                      (data_diff ((from_row (id . 1)) (to_row))))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (= 0 (plist-get stat :added)))
      (should (= 1 (plist-get stat :deleted)))
      (should (= 0 (plist-get stat :modified))))))

(ert-deftest test-madolt-diff-table-stat-modified ()
  "Should count modified rows."
  (let ((table-data '((name . "t1")
                      (schema_diff)
                      (data_diff ((from_row (id . 1) (val . "a"))
                                  (to_row (id . 1) (val . "b")))))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (= 0 (plist-get stat :added)))
      (should (= 0 (plist-get stat :deleted)))
      (should (= 1 (plist-get stat :modified))))))

(ert-deftest test-madolt-diff-table-stat-schema-changed ()
  "Should detect schema changes."
  (let ((table-data '((name . "t1")
                      (schema_diff "ALTER TABLE t1 ADD COLUMN x INT")
                      (data_diff))))
    (let ((stat (madolt-diff--table-stat table-data)))
      (should (plist-get stat :schema-changed)))))

(ert-deftest test-madolt-diff-compute-stats-multiple-tables ()
  "Should compute stats for multiple tables."
  (let ((tables (list '((name . "t1")
                        (schema_diff)
                        (data_diff ((from_row) (to_row (id . 1)))))
                      '((name . "t2")
                        (schema_diff)
                        (data_diff ((from_row (id . 2)) (to_row)))))))
    (let ((stats (madolt-diff--compute-stats tables)))
      (should (= 2 (length stats)))
      (should (= 1 (plist-get (car stats) :added)))
      (should (= 1 (plist-get (cadr stats) :deleted))))))

;;;; Revision buffer improvements

(ert-deftest test-madolt-log-revision-shows-parent ()
  "Revision buffer should show parent hash."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "Second")
    (let* ((entries (madolt-log-entries 2))
           (newest (car entries))
           (hash (plist-get newest :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should (string-match-p "Parent:" text)))))))

(ert-deftest test-madolt-log-revision-shows-merge-parents ()
  "Revision buffer should show Merge: line for merge commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "-b" "feat")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "feat commit")
    (call-process madolt-dolt-executable nil nil nil
                  "checkout" "main")
    (madolt-test-insert-row "t1" "(3)")
    (madolt-test-commit "main commit")
    (call-process madolt-dolt-executable nil nil nil
                  "merge" "feat" "--no-ff" "-m" "Merge feat")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should (string-match-p "Merge:" text)))))))

(ert-deftest test-madolt-log-revision-shows-stat-summary ()
  "Revision buffer should show diff stat summary."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "init")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "add row")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          ;; Should show table name in stat
          (should (string-match-p "t1" text))
          ;; Should show row count stat
          (should (string-match-p "1 table changed" text))
          ;; Should show added count
          (should (string-match-p "1 added" text)))))))

(ert-deftest test-madolt-log-revision-full-message ()
  "Revision buffer should display the full commit message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "First line of message")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should (string-match-p "First line of message" text)))))))

(ert-deftest test-madolt-log-revision-no-parent-for-initial ()
  "Revision buffer should not show Parent: for the initial commit."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Initial")
    ;; Get the very first commit (init commits from dolt init + our commit)
    ;; Use the last entry to find one with no parent
    (let* ((entries (madolt-log-entries 100))
           ;; The last entry is the dolt init commit which has no parent
           (init-entry (car (last entries)))
           (hash (plist-get init-entry :hash)))
      (with-temp-buffer
        (madolt-revision-mode)
        (setq madolt-revision--hash hash)
        (let ((inhibit-read-only t))
          (madolt-revision-refresh-buffer))
        (let ((text (buffer-substring-no-properties
                     (point-min) (point-max))))
          (should-not (string-match-p "Parent:" text))
          (should-not (string-match-p "Merge:" text)))))))

;;;; Show-or-scroll (SPC / DEL)

(ert-deftest test-madolt-diff-show-or-scroll-up-defined ()
  "madolt-diff-show-or-scroll-up should be a command."
  (should (commandp 'madolt-diff-show-or-scroll-up)))

(ert-deftest test-madolt-diff-show-or-scroll-down-defined ()
  "madolt-diff-show-or-scroll-down should be a command."
  (should (commandp 'madolt-diff-show-or-scroll-down)))

(ert-deftest test-madolt-spc-bound-in-mode-map ()
  "SPC should be bound to madolt-diff-show-or-scroll-up."
  (should (eq (keymap-lookup madolt-mode-map "SPC")
              'madolt-diff-show-or-scroll-up)))

(ert-deftest test-madolt-del-bound-in-mode-map ()
  "DEL should be bound to madolt-diff-show-or-scroll-down."
  (should (eq (keymap-lookup madolt-mode-map "DEL")
              'madolt-diff-show-or-scroll-down)))

(ert-deftest test-madolt-show-or-scroll-errors-without-commit ()
  "show-or-scroll should error when not on a commit section."
  (with-temp-buffer
    (madolt-log-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (log)
        (magit-insert-heading "Log:")
        (insert "no commits\n")))
    (goto-char (point-min))
    (should-error (madolt-diff-show-or-scroll-up)
                  :type 'user-error)))

(ert-deftest test-madolt-show-or-scroll-shows-commit ()
  "SPC on a commit should display revision buffer without selecting."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Test SPC")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash))
           (displayed-buf nil)
           (displayed-noselect nil))
      ;; Mock madolt-show-commit to capture the call
      (cl-letf (((symbol-function 'madolt-show-commit)
                 (lambda (h &optional noselect)
                   (setq displayed-buf h)
                   (setq displayed-noselect noselect))))
        (with-temp-buffer
          (madolt-log-mode)
          (let ((inhibit-read-only t))
            (magit-insert-section (log)
              (magit-insert-heading "Log:")
              (magit-insert-section (commit hash)
                (magit-insert-heading hash "\n"))))
          ;; Position on the commit section
          (goto-char (point-min))
          (magit-section-forward)
          (madolt-diff-show-or-scroll-up)
          (should (equal displayed-buf hash))
          (should displayed-noselect))))))

(ert-deftest test-madolt-show-commit-noselect ()
  "madolt-show-commit with NOSELECT should use display-buffer."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Test noselect")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash))
           (display-buffer-called nil))
      ;; Mock display-buffer to track the call
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buf &optional _action)
                   (setq display-buffer-called t)
                   ;; Return a window to satisfy callers
                   (selected-window)))
                ((symbol-function 'madolt-display-buffer)
                 (lambda (_buf) (error "Should not call madolt-display-buffer"))))
        (madolt-show-commit hash t)
        (should display-buffer-called)))))

(ert-deftest test-madolt-revision-buffer-lookup ()
  "madolt--revision-buffer-for-hash should find visible revision buffers."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Test lookup")
    (let* ((entry (car (madolt-log-entries 1)))
           (hash (plist-get entry :hash)))
      ;; No buffer exists yet
      (should-not (madolt--revision-buffer-for-hash hash)))))

;;;; Log refresh transient (L)

(ert-deftest test-madolt-log-refresh-is-transient ()
  "madolt-log-refresh should be a transient prefix."
  (should (get 'madolt-log-refresh 'transient--prefix)))

(ert-deftest test-madolt-log-refresh-has-graph-arg ()
  "madolt-log-refresh should have --graph argument."
  (let* ((layout (get 'madolt-log-refresh 'transient--layout))
         (all-args nil))
    (dolist (group (aref layout 2))
      (dolist (suffix (aref group 2))
        (when (listp suffix)
          (let ((arg (plist-get (cdr suffix) :argument)))
            (when arg (push arg all-args))))))
    (should (member "--graph" all-args))))

(ert-deftest test-madolt-log-refresh-has-refresh-suffix ()
  "madolt-log-refresh should have a `g' suffix for refreshing."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log-refresh)))
    (should (assoc "g" suffixes))
    (should (eq (cdr (assoc "g" suffixes)) 'madolt-log-refresh-apply))))

(ert-deftest test-madolt-log-refresh-has-set-suffix ()
  "madolt-log-refresh should have an `s' suffix for set-and-exit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log-refresh)))
    (should (assoc "s" suffixes))
    (should (eq (cdr (assoc "s" suffixes)) 'madolt-log-refresh-set))))

(ert-deftest test-madolt-log-refresh-has-save-suffix ()
  "madolt-log-refresh should have a `w' suffix for save-and-exit."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log-refresh)))
    (should (assoc "w" suffixes))
    (should (eq (cdr (assoc "w" suffixes)) 'madolt-log-refresh-save))))

(ert-deftest test-madolt-log-refresh-bound-in-mode-map ()
  "L should be bound to madolt-log-refresh in madolt-mode-map."
  (should (eq (keymap-lookup madolt-mode-map "L")
              'madolt-log-refresh)))

(ert-deftest test-madolt-log-refresh-current-args ()
  "madolt-log-refresh--current-args should return current buffer args."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--args '("--graph" "--stat"))
    (setq madolt-log--limit 50)
    (let ((args (madolt-log-refresh--current-args)))
      (should (member "--graph" args))
      (should (member "--stat" args))
      (should (cl-some (lambda (a) (string-prefix-p "-n" a)) args)))))

(ert-deftest test-madolt-log-refresh-current-args-includes-limit ()
  "madolt-log-refresh--current-args should include -n<limit>."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--args nil)
    (setq madolt-log--limit 42)
    (let ((args (madolt-log-refresh--current-args)))
      (should (member "-n42" args)))))

(ert-deftest test-madolt-log-refresh-current-args-no-duplicate-limit ()
  "madolt-log-refresh--current-args should not duplicate -n if already in args."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--args '("-n100"))
    (setq madolt-log--limit 100)
    (let ((args (madolt-log-refresh--current-args)))
      (should (= 1 (cl-count-if (lambda (a) (string-prefix-p "-n" a)) args))))))

(ert-deftest test-madolt-log-refresh-apply-updates-args ()
  "madolt-log-refresh--apply-args should update buffer-local args."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--rev "main")
    (setq madolt-log--args nil)
    (setq madolt-log--limit 25)
    (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
      (madolt-log-refresh--apply-args '("-n50" "--graph" "--stat")))
    (should (= madolt-log--limit 50))
    (should (member "--graph" madolt-log--args))
    (should (member "--stat" madolt-log--args))
    ;; -n should be stripped from args (handled by limit)
    (should-not (cl-some (lambda (a) (string-prefix-p "-n" a))
                         madolt-log--args))))

(ert-deftest test-madolt-log-refresh-apply-errors-outside-log ()
  "madolt-log-refresh--apply-args should error outside a log buffer."
  (with-temp-buffer
    (madolt-mode)
    (should-error (madolt-log-refresh--apply-args '("--graph"))
                  :type 'user-error)))

;;;; Margin configuration

(ert-deftest test-madolt-log-margin-defcustom ()
  "madolt-log-margin should be a 5-element list."
  (should (listp madolt-log-margin))
  (should (= 5 (length madolt-log-margin))))

(ert-deftest test-madolt-log-margin-default-values ()
  "madolt-log-margin should default to (t age 36 t 16)."
  (should (eq t (nth 0 madolt-log-margin)))
  (should (eq 'age (nth 1 madolt-log-margin)))
  (should (= 36 (nth 2 madolt-log-margin)))
  (should (eq t (nth 3 madolt-log-margin)))
  (should (= 16 (nth 4 madolt-log-margin))))

(ert-deftest test-madolt-log-ensure-margin-config ()
  "madolt-log--ensure-margin-config should initialize from defcustom."
  (with-temp-buffer
    (madolt-log-mode)
    (should-not madolt-log--margin-config)
    (madolt-log--ensure-margin-config)
    (should madolt-log--margin-config)
    (should (equal madolt-log--margin-config
                   (copy-sequence madolt-log-margin)))))

(ert-deftest test-madolt-log-ensure-margin-config-idempotent ()
  "madolt-log--ensure-margin-config should not overwrite existing config."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config '(nil age-abbreviated 40 nil 20))
    (madolt-log--ensure-margin-config)
    (should (equal madolt-log--margin-config
                   '(nil age-abbreviated 40 nil 20)))))

;;;; Margin toggle/cycle commands

(ert-deftest test-madolt-toggle-margin-is-command ()
  "madolt-toggle-margin should be a command."
  (should (commandp 'madolt-toggle-margin)))

(ert-deftest test-madolt-cycle-margin-style-is-command ()
  "madolt-cycle-margin-style should be a command."
  (should (commandp 'madolt-cycle-margin-style)))

(ert-deftest test-madolt-toggle-margin-details-is-command ()
  "madolt-toggle-margin-details should be a command."
  (should (commandp 'madolt-toggle-margin-details)))

(ert-deftest test-madolt-toggle-margin-flips-visibility ()
  "madolt-toggle-margin should toggle the INIT flag."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list t 'age 36 t 16))
    (cl-letf (((symbol-function 'madolt-log--apply-margin-config) #'ignore))
      (madolt-toggle-margin))
    (should-not (car madolt-log--margin-config))
    (cl-letf (((symbol-function 'madolt-log--apply-margin-config) #'ignore))
      (madolt-toggle-margin))
    (should (car madolt-log--margin-config))))

(ert-deftest test-madolt-cycle-margin-style-cycles ()
  "madolt-cycle-margin-style should cycle age -> abbreviated -> string -> age."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list t 'age 36 t 16))
    (cl-letf (((symbol-function 'madolt-log--apply-margin-config) #'ignore))
      ;; age -> age-abbreviated
      (madolt-cycle-margin-style)
      (should (eq 'age-abbreviated (cadr madolt-log--margin-config)))
      ;; age-abbreviated -> format string
      (madolt-cycle-margin-style)
      (should (stringp (cadr madolt-log--margin-config)))
      ;; format string -> age
      (madolt-cycle-margin-style)
      (should (eq 'age (cadr madolt-log--margin-config))))))

(ert-deftest test-madolt-toggle-margin-details-flips-author ()
  "madolt-toggle-margin-details should toggle the AUTHOR flag."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list t 'age 36 t 16))
    (cl-letf (((symbol-function 'madolt-log--apply-margin-config) #'ignore))
      (madolt-toggle-margin-details))
    (should-not (nth 3 madolt-log--margin-config))
    (cl-letf (((symbol-function 'madolt-log--apply-margin-config) #'ignore))
      (madolt-toggle-margin-details))
    (should (nth 3 madolt-log--margin-config))))

(ert-deftest test-madolt-toggle-margin-errors-outside-log ()
  "Margin commands should error outside a log buffer."
  (with-temp-buffer
    (madolt-mode)
    (should-error (madolt-toggle-margin) :type 'user-error)
    (should-error (madolt-cycle-margin-style) :type 'user-error)
    (should-error (madolt-toggle-margin-details) :type 'user-error)))

;;;; Date formatting with styles

(ert-deftest test-madolt-log-format-date-age ()
  "Format date with age style should produce 'N unit' format."
  (should (string-match-p "^[0-9]+ [a-z]+$"
                          (madolt-log--format-date "2026-03-07 12:00:00" 'age))))

(ert-deftest test-madolt-log-format-date-abbreviated ()
  "Format date with age-abbreviated should produce 'Nc' format."
  (let ((result (madolt-log--format-date "2026-03-07 12:00:00"
                                         'age-abbreviated)))
    (should (string-match-p "^[0-9]+[a-zA-Z]$" result))))

(ert-deftest test-madolt-log-format-date-format-string ()
  "Format date with a format string should produce absolute date."
  (let ((result (madolt-log--format-date "2026-03-07 12:00:00"
                                         "%Y-%m-%d")))
    (should (string= "2026-03-07" result))))

(ert-deftest test-madolt-log-format-date-nil-style-defaults-to-age ()
  "Format date with nil style should default to age."
  (let ((result (madolt-log--format-date "2026-03-07 12:00:00" nil)))
    (should (string-match-p "^[0-9]+ [a-z]+$" result))))

;;;; Margin rendering with config

(ert-deftest test-madolt-log-margin-hidden-no-overlay ()
  "When margin is hidden, madolt-log--insert-margin should not create overlays."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list nil 'age 36 t 16))
    (let ((inhibit-read-only t))
      (insert "test line\n")
      (madolt-log--insert-margin "Alice" "2026-03-07 12:00:00"))
    (should-not (overlays-in (point-min) (point-max)))))

(ert-deftest test-madolt-log-margin-visible-creates-overlay ()
  "When margin is visible, madolt-log--insert-margin should create overlays."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list t 'age 36 t 16))
    (let ((inhibit-read-only t))
      (insert "test line\n")
      (madolt-log--insert-margin "Alice" "2026-03-07 12:00:00"))
    (should (overlays-in (point-min) (point-max)))))

(ert-deftest test-madolt-log-margin-no-author ()
  "When AUTHOR is nil, margin should not include author text."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list t 'age 36 nil 16))
    (let ((inhibit-read-only t))
      (insert "test line\n")
      (madolt-log--insert-margin "Alice" "2026-03-07 12:00:00"))
    (let* ((ovs (overlays-in (point-min) (point-max)))
           (before (overlay-get (car ovs) 'before-string))
           (display (get-text-property 0 'display before))
           (margin-text (cadr display)))
      ;; Should NOT contain "Alice"
      (should-not (string-match-p "Alice" margin-text)))))

(ert-deftest test-madolt-log-margin-effective-width-hidden ()
  "Effective width should be 0 when margin is hidden."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list nil 'age 36 t 16))
    (should (= 0 (madolt-log--margin-effective-width)))))

(ert-deftest test-madolt-log-margin-effective-width-visible ()
  "Effective width should be the configured width when visible."
  (with-temp-buffer
    (madolt-log-mode)
    (setq madolt-log--margin-config (list t 'age 42 t 16))
    (should (= 42 (madolt-log--margin-effective-width)))))

;;;; Margin suffixes in transient

(ert-deftest test-madolt-log-refresh-has-margin-toggle ()
  "madolt-log-refresh should have an L suffix for margin toggle."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log-refresh)))
    (should (assoc "L" suffixes))))

(ert-deftest test-madolt-log-refresh-has-margin-cycle ()
  "madolt-log-refresh should have an l suffix for margin cycle."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log-refresh)))
    (should (assoc "l" suffixes))))

(ert-deftest test-madolt-log-refresh-has-margin-details ()
  "madolt-log-refresh should have a d suffix for margin details."
  (let ((suffixes (madolt-test--transient-suffix-keys 'madolt-log-refresh)))
    (should (assoc "d" suffixes))))

(provide 'madolt-log-tests)
;;; madolt-log-tests.el ends here
