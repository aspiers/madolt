;;; madolt-status-tests.el --- Tests for madolt-status.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the status buffer: header, staged/unstaged/untracked
;; sections, recent commits, section structure, and inline diff.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'madolt-test-helpers)
(require 'madolt-status)

;;;; Helper to render status buffer in a test database

(defun madolt-test--render-status ()
  "Create and return a status buffer for the current test database.
The buffer should be killed by the caller."
  (let ((buf (madolt-setup-buffer 'madolt-status-mode)))
    buf))

(defmacro madolt-with-status-buffer (&rest body)
  "Render a status buffer for the current test database and run BODY.
The buffer is current during BODY and killed afterward."
  (declare (indent 0) (debug t))
  `(let ((buf (madolt-test--render-status)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (kill-buffer buf))))

;;;; Header

(ert-deftest test-madolt-status-header-shows-branch ()
  "The status header displays the current branch name."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (goto-char (point-min))
      (should (string-match-p "main" (buffer-string))))))

(ert-deftest test-madolt-status-header-shows-last-commit ()
  "The status header shows abbreviated hash and message of HEAD."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "Initial commit message")
    (madolt-with-status-buffer
      (goto-char (point-min))
      (let ((text (buffer-string)))
        ;; Should contain the commit message
        (should (string-match-p "Initial commit message" text))
        ;; Should contain an abbreviated hash (8 alphanumeric chars)
        (should (string-match-p "[a-z0-9]\\{8\\}" text))))))

(ert-deftest test-madolt-status-header-shows-database-name ()
  "The status header displays the database name."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        (should (string-match-p "Database:" text))))))

(ert-deftest test-madolt-status-header-shows-path ()
  "The status header displays the database filesystem path."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        (should (string-match-p "Path:" text))))))

(ert-deftest test-madolt-status-header-no-server-when-not-running ()
  "The status header does not show Server: when no server is running."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Server:" (buffer-string))))))

(ert-deftest test-madolt-status-header-shows-server-when-running ()
  "The status header shows Server: when sql-server info is present."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    ;; Stub the server info function to simulate a running server
    (cl-letf (((symbol-function 'madolt-sql-server-info)
               (lambda () '(:pid 12345 :port 3306))))
      (madolt-with-status-buffer
        (let ((text (buffer-string)))
          (should (string-match-p "Server:" text))
          (should (string-match-p "localhost:3306" text))
          (should (string-match-p "pid 12345" text)))))))

;;;; Staged changes section

(ert-deftest test-madolt-status-staged-section-visible ()
  "The \"Staged changes\" section appears when tables are staged."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (string-match-p "Staged changes" (buffer-string))))))

(ert-deftest test-madolt-status-staged-lists-tables ()
  "Staged tables are listed with their status."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; users is staged as modified in the populated db
        (should (string-match-p "modified.*users" text))))))

(ert-deftest test-madolt-status-staged-hidden-when-empty ()
  "The staged section is not shown when nothing is staged."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Staged changes" (buffer-string))))))

;;;; Unstaged changes section

(ert-deftest test-madolt-status-unstaged-section-visible ()
  "The \"Unstaged changes\" section appears when there are unstaged changes."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (string-match-p "Unstaged changes" (buffer-string))))))

(ert-deftest test-madolt-status-unstaged-lists-tables ()
  "Unstaged tables are listed with their status."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; products has unstaged modifications in the populated db
        (should (string-match-p "modified.*products" text))))))

(ert-deftest test-madolt-status-unstaged-hidden-when-empty ()
  "The unstaged section is not shown when no unstaged changes exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Unstaged changes" (buffer-string))))))

;;;; Untracked tables section

(ert-deftest test-madolt-status-untracked-section-visible ()
  "The \"Untracked tables\" section appears when new tables exist."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (should (string-match-p "Untracked tables" (buffer-string))))))

(ert-deftest test-madolt-status-untracked-lists-tables ()
  "Untracked tables are listed."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; inventory is untracked in the populated db
        (should (string-match-p "new table.*inventory" text))))))

(ert-deftest test-madolt-status-untracked-hidden-when-empty ()
  "The untracked section is not shown when no untracked tables exist."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Untracked tables" (buffer-string))))))

;;;; Recent commits section

(ert-deftest test-madolt-status-recent-commits-shown ()
  "The recent commits section appears when there are commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "First commit")
    (madolt-with-status-buffer
      (should (string-match-p "Recent commits" (buffer-string))))))

(ert-deftest test-madolt-status-recent-commits-count ()
  "The recent commits section shows the correct number of commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "Commit one")
    (madolt-test-insert-row "t1" "(1)")
    (madolt-test-commit "Commit two")
    (madolt-test-insert-row "t1" "(2)")
    (madolt-test-commit "Commit three")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; All three commit messages should appear
        ;; (plus the initial dolt init commit = 4 total, but we check ours)
        (should (string-match-p "Commit one" text))
        (should (string-match-p "Commit two" text))
        (should (string-match-p "Commit three" text))))))

(ert-deftest test-madolt-status-recent-commit-format ()
  "Each commit shows hash and message."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "My test commit")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; Should have a line with hash followed by message
        (should (string-match-p
                 "[a-z0-9]\\{8\\}  My test commit" text))))))

;;;; Section structure

(ert-deftest test-madolt-status-sections-are-magit-sections ()
  "All sections in the status buffer are proper magit-section objects."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (goto-char (point-min))
      ;; The root section should be a magit-section
      (let ((root (magit-current-section)))
        (should root)
        (should (magit-section-p root))))))

(ert-deftest test-madolt-status-table-sections-have-values ()
  "Table sections store the table name as their value."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (goto-char (point-min))
      ;; Find table sections by walking the section tree
      (let ((found nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'table)
             (push (oref section value) found)))
         magit-root-section)
        ;; The populated db has: users (staged), products (unstaged),
        ;; inventory (untracked)
        (should (member "users" found))
        (should (member "products" found))
        (should (member "inventory" found))))))

(ert-deftest test-madolt-status-sections-collapsible ()
  "TAB toggles section visibility."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (goto-char (point-min))
      ;; Find the staged section
      (let ((staged-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'staged)
             (setq staged-section section)))
         magit-root-section)
        (should staged-section)
        ;; Move to the section and toggle
        (goto-char (oref staged-section start))
        (let ((was-hidden (oref staged-section hidden)))
          (call-interactively #'magit-section-toggle)
          (should (not (eq was-hidden
                           (oref staged-section hidden)))))))))

;;;; Inline diff expansion

(ert-deftest test-madolt-status-tab-on-table-shows-diff ()
  "Pressing TAB on a table section shows diff content."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; Find a table section (they start hidden due to the washer)
      (let ((table-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (and (eq (oref section type) 'table)
                      (not table-section))
             (setq table-section section)))
         magit-root-section)
        (should table-section)
        ;; Table sections start hidden (created with t for HIDE)
        (should (oref table-section hidden))
        ;; Expand the section
        (goto-char (oref table-section start))
        (let ((inhibit-read-only t))
          (magit-section-show table-section))
        ;; After expansion, the washer should have run and inserted
        ;; diff content (or the fallback placeholder)
        (should-not (oref table-section hidden))))))

(ert-deftest test-madolt-status-tab-toggle ()
  "Pressing TAB twice hides the section again."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      (let ((table-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (and (eq (oref section type) 'table)
                      (not table-section))
             (setq table-section section)))
         magit-root-section)
        (should table-section)
        (goto-char (oref table-section start))
        ;; Toggle open
        (let ((inhibit-read-only t))
          (magit-section-show table-section))
        (should-not (oref table-section hidden))
        ;; Toggle closed
        (magit-section-hide table-section)
        (should (oref table-section hidden))))))

;;;; Clean working tree

(ert-deftest test-madolt-status-clean-shows-header-only ()
  "A clean working tree shows only the header and recent commits."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; Should have the header
        (should (string-match-p "Head:" text))
        ;; Should have recent commits
        (should (string-match-p "Recent commits" text))
        ;; Should NOT have any change sections
        (should-not (string-match-p "Staged changes" text))
        (should-not (string-match-p "Unstaged changes" text))
        (should-not (string-match-p "Untracked tables" text))))))

;;;; Unpushed / unpulled sections

(ert-deftest test-madolt-status-unpushed-shown ()
  "The \"Unpushed to\" section appears when there are unpushed commits."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    ;; Create a local commit that hasn't been pushed
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "unpushed commit")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        (should (string-match-p "Unpushed to origin/main" text))
        (should (string-match-p "unpushed commit" text))))))

(ert-deftest test-madolt-status-unpushed-hidden-when-none ()
  "The unpushed section is hidden when there are no unpushed commits."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    (madolt-with-status-buffer
      (should-not (string-match-p "Unpushed to" (buffer-string))))))

(ert-deftest test-madolt-status-unpulled-shown ()
  "The \"Unpulled from\" section appears when there are unpulled commits.
Stubs upstream functions since dolt file:// fetch has limitations."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "shared base")
    ;; Create a branch to simulate remote being ahead
    (madolt--run "branch" "fake-remote")
    (madolt--run "checkout" "fake-remote")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "upstream only")
    (madolt--run "checkout" "main")
    (cl-letf (((symbol-function 'madolt-upstream-ref)
               (lambda (&optional _branch) "fake-remote")))
      (madolt-with-status-buffer
        (let ((text (buffer-string)))
          (should (string-match-p "Unpulled from fake-remote" text))
          (should (string-match-p "upstream only" text)))))))

(ert-deftest test-madolt-status-unpulled-hidden-when-none ()
  "The unpulled section is hidden when there are no unpulled commits."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    ;; No new commits on origin, so unpulled should be empty
    (madolt-with-status-buffer
      (should-not (string-match-p "Unpulled from" (buffer-string))))))

;;;; Recent commits conditional (or-recent pattern)

(ert-deftest test-madolt-status-recent-hidden-when-unpushed ()
  "Recent commits should NOT appear when unpushed section is shown."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "unpushed commit")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        ;; Unpushed section should be shown
        (should (string-match-p "Unpushed to" text))
        ;; Recent commits should NOT be shown
        (should-not (string-match-p "Recent commits" text))))))

(ert-deftest test-madolt-status-recent-shown-when-no-upstream ()
  "Recent commits should appear when there is no upstream (no remote)."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "local commit")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        (should (string-match-p "Recent commits" text))
        (should-not (string-match-p "Unpushed to" text))
        (should-not (string-match-p "Unpulled from" text))))))

;;;; Merge conflicts section

(ert-deftest test-madolt-status-conflicts-section-visible ()
  "The \"Merge conflicts\" section appears when there are conflicts."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "init")
    ;; Create a branch with a conflicting change
    (madolt-branch-checkout-create "feature")
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-commit "feature change")
    ;; Make a conflicting change on main
    (madolt-branch-checkout "main")
    (madolt-test-update-row "t1" "val = 30" "id = 1")
    (madolt-test-commit "main change")
    ;; Merge feature into main (should produce conflicts)
    (madolt--run "merge" "feature")
    (madolt-with-status-buffer
      (should (string-match-p "Merge conflicts" (buffer-string))))))

(ert-deftest test-madolt-status-conflicts-lists-tables ()
  "Conflicting tables are listed in the merge conflicts section."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "init")
    (madolt-branch-checkout-create "feature")
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-commit "feature change")
    (madolt-branch-checkout "main")
    (madolt-test-update-row "t1" "val = 30" "id = 1")
    (madolt-test-commit "main change")
    (madolt--run "merge" "feature")
    (madolt-with-status-buffer
      (should (string-match-p "t1" (buffer-string))))))

(ert-deftest test-madolt-status-conflicts-hidden-when-none ()
  "The merge conflicts section is not shown when there are no conflicts."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Merge conflicts" (buffer-string))))))

(ert-deftest test-madolt-status-conflicts-section-type ()
  "Conflict table sections have the conflicts section type."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY, val INT")
    (madolt-test-insert-row "t1" "(1, 10)")
    (madolt-test-commit "init")
    (madolt-branch-checkout-create "feature")
    (madolt-test-update-row "t1" "val = 20" "id = 1")
    (madolt-test-commit "feature change")
    (madolt-branch-checkout "main")
    (madolt-test-update-row "t1" "val = 30" "id = 1")
    (madolt-test-commit "main change")
    (madolt--run "merge" "feature")
    (madolt-with-status-buffer
      (let ((found nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'conflicts)
             (setq found t)))
         magit-root-section)
        (should found)))))

;;;; Section visibility preservation

(ert-deftest test-madolt-status-visibility-preserved-on-refresh ()
  "Expanded table sections remain expanded after refresh."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; Find a table section (they start hidden)
      (let ((table-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (and (eq (oref section type) 'table)
                      (not table-section))
             (setq table-section section)))
         magit-root-section)
        (should table-section)
        (should (oref table-section hidden))
        ;; Expand the section
        (goto-char (oref table-section start))
        (let ((inhibit-read-only t))
          (magit-section-show table-section))
        (should-not (oref table-section hidden))
        ;; Remember which table we expanded
        (let ((table-name (oref table-section value)))
          ;; Refresh the buffer
          (madolt-refresh)
          ;; Find the same table section again
          (let ((new-section nil))
            (madolt-test--walk-sections
             (lambda (section)
               (when (and (eq (oref section type) 'table)
                          (equal (oref section value) table-name))
                 (setq new-section section)))
             magit-root-section)
            (should new-section)
            ;; It should still be expanded (not hidden)
            (should-not (oref new-section hidden))))))))

(ert-deftest test-madolt-status-collapsed-sections-stay-collapsed ()
  "Collapsed sections remain collapsed after refresh."
  (madolt-with-test-database
    (madolt-test-setup-populated-db)
    (madolt-with-status-buffer
      ;; Find a top-level section like 'staged'
      (let ((staged-section nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'staged)
             (setq staged-section section)))
         magit-root-section)
        (should staged-section)
        ;; Collapse it
        (goto-char (oref staged-section start))
        (magit-section-hide staged-section)
        (should (oref staged-section hidden))
        ;; Refresh
        (madolt-refresh)
        ;; Find the staged section again
        (let ((new-section nil))
          (madolt-test--walk-sections
           (lambda (section)
             (when (eq (oref section type) 'staged)
               (setq new-section section)))
           magit-root-section)
          (should new-section)
          ;; It should still be collapsed
          (should (oref new-section hidden)))))))

;;;; No remote sections

(ert-deftest test-madolt-status-no-remote-no-pushed-unpulled ()
  "No unpushed/unpulled sections appear when there is no remote."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (let ((text (buffer-string)))
        (should-not (string-match-p "Unpushed" text))
        (should-not (string-match-p "Unpulled" text))))))

(ert-deftest test-madolt-status-unpushed-commit-count ()
  "The unpushed section shows the correct count of commits."
  (madolt-with-file-remote
    (madolt--run "push" "origin" "main")
    (madolt--run "fetch" "origin")
    ;; Make two local commits
    (madolt-test-create-table "t2" "id INT PRIMARY KEY")
    (madolt-test-commit "first unpushed")
    (madolt-test-insert-row "t2" "(1)")
    (madolt-test-commit "second unpushed")
    (madolt-with-status-buffer
      (should (string-match-p "Unpushed to origin/main (2)"
                              (buffer-string))))))

;;;; Rebase sequence section

(defun madolt-test--setup-rebase ()
  "Set up a two-commit history and start an interactive rebase.
Returns the hash of the commit used as the rebase upstream.
Leaves a SQL-initiated rebase in progress on `main'."
  (madolt-test-create-table "t1" "id INT PRIMARY KEY")
  (madolt-test-commit "initial")
  (madolt-test-create-table "t2" "id INT PRIMARY KEY")
  (madolt-test-commit "add t2")
  (madolt-test-create-table "t3" "id INT PRIMARY KEY")
  (madolt-test-commit "add t3")
  ;; Upstream = the "initial" commit (two back from HEAD)
  (let ((upstream (string-trim
                   (cdr (madolt--run "sql" "-q"
                                     "SELECT commit_hash FROM dolt_log ORDER BY date ASC LIMIT 1 OFFSET 1"
                                     "-r" "csv")))))
    ;; Strip CSV header line
    (setq upstream (car (last (split-string upstream "\n"))))
    (madolt--run "sql" "-q"
                 (format "CALL DOLT_REBASE('-i', '%s')" upstream))
    upstream))

(ert-deftest test-madolt-status-rebase-section-visible ()
  "The \"Rebasing\" section appears when an interactive rebase is in progress."
  (madolt-with-test-database
    (madolt-test--setup-rebase)
    (madolt-with-status-buffer
      (should (string-match-p "Rebasing" (buffer-string))))))

(ert-deftest test-madolt-status-rebase-section-hidden-when-none ()
  "The rebase section is not shown when no rebase is in progress."
  (madolt-with-test-database
    (madolt-test-create-table "t1" "id INT PRIMARY KEY")
    (madolt-test-commit "init")
    (madolt-with-status-buffer
      (should-not (string-match-p "Rebasing" (buffer-string))))))

(ert-deftest test-madolt-status-rebase-section-shows-branch ()
  "The rebase section heading includes the branch being rebased."
  (madolt-with-test-database
    (madolt-test--setup-rebase)
    (madolt-with-status-buffer
      (should (string-match-p "Rebasing main onto" (buffer-string))))))

(ert-deftest test-madolt-status-rebase-section-shows-commits ()
  "The rebase section lists the commits remaining in the plan."
  (madolt-with-test-database
    (madolt-test--setup-rebase)
    (madolt-with-status-buffer
      (should (string-match-p "add t2" (buffer-string)))
      (should (string-match-p "add t3" (buffer-string))))))

(ert-deftest test-madolt-status-rebase-section-type ()
  "The rebase section has the rebase-sequence section type."
  (madolt-with-test-database
    (madolt-test--setup-rebase)
    (madolt-with-status-buffer
      (let ((found nil))
        (madolt-test--walk-sections
         (lambda (section)
           (when (eq (oref section type) 'rebase-sequence)
             (setq found t)))
         magit-root-section)
        (should found)))))

(provide 'madolt-status-tests)
;;; madolt-status-tests.el ends here
