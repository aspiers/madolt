;;; madolt-dolt.el --- Dolt CLI wrapper layer  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Dolt CLI wrapper layer for madolt.  Provides functions to execute
;; dolt commands and parse their output.  Modeled on magit-git.el:
;; same abstraction pattern (executable + global args + output-parsing
;; helpers), different binary.
;;
;; This is the lowest layer of madolt — it has no dependency on
;; magit-section, transient, or with-editor.

;;; Code:

(eval-when-compile (require 'cl-lib))

;; Defined in madolt-connection.el; declared here to avoid
;; a circular require.
(defvar madolt-use-sql-server)

;;;; Configuration

(defcustom madolt-dolt-executable "dolt"
  "The Dolt executable used by Madolt."
  :group 'madolt
  :type 'string)

(defcustom madolt-dolt-global-arguments nil
  "Global arguments prepended to every dolt invocation.
These are placed right after the executable itself and before
the dolt command."
  :group 'madolt
  :type '(repeat string))

;;;; Per-refresh cache

(defvar madolt--refresh-cache nil
  "Cache of subprocess results for the current refresh cycle.
Like `magit--refresh-cache': a list whose car is (HITS . MISSES)
and whose cdr is an alist of (KEY . VALUE) entries.
Bound dynamically around a full buffer refresh so that identical
dolt invocations are served from cache.")

(defmacro madolt--with-refresh-cache (key &rest body)
  "If caching is active, return cached value for KEY or evaluate BODY.
Cache hits/misses are counted in the car of `madolt--refresh-cache'."
  (declare (indent 1) (debug (form body)))
  (let ((k (gensym))
        (hit (gensym)))
    `(if madolt--refresh-cache
         (let ((,k ,key))
           (if-let ((,hit (assoc ,k (cdr madolt--refresh-cache))))
               (progn (cl-incf (caar madolt--refresh-cache))
                      (cdr ,hit))
             (cl-incf (cdar madolt--refresh-cache))
             (let ((value ,(macroexp-progn body)))
               (push (cons ,k value)
                     (cdr madolt--refresh-cache))
               value)))
       ,@body)))

;;;; Internal helpers

(defun madolt--flatten-args (args)
  "Flatten ARGS into a flat list of strings, removing nils."
  (let ((flat (flatten-tree args)))
    (delq nil (mapcar (lambda (a)
                        (and a (if (stringp a) a (format "%s" a))))
                      flat))))

(defconst madolt--ansi-escape-re
  "\033\\[[0-9;]*m"
  "Regexp matching ANSI SGR escape sequences.")

(defun madolt--strip-ansi (string)
  "Strip ANSI escape sequences from STRING."
  (if string
      (replace-regexp-in-string madolt--ansi-escape-re "" string)
    ""))

;;;; SQL translation registry

;; Forward declarations for optional SQL connection module
(declare-function madolt-connection-ensure "madolt-connection")
(declare-function madolt-connection-query "madolt-connection")

(defvar madolt--sql-translations nil
  "Alist mapping CLI arg patterns to SQL query generators.
Each entry is (PATTERN . GENERATOR) where:
  PATTERN is a function taking a flat args list, returning non-nil on match.
  GENERATOR is a function taking the args list, returning a SQL string.
Populated by individual migration tasks (e.g. madolt-hlh, madolt-a61).")

(defun madolt--register-sql-translation (name pattern generator)
  "Register a SQL translation with NAME.
PATTERN is a predicate on the flat args list.
GENERATOR produces SQL from the matched args."
  (setf (alist-get name madolt--sql-translations) (cons pattern generator)))

(defun madolt--find-sql-translation (args)
  "Find a SQL translation for ARGS.
Returns the generator function or nil."
  (cl-loop for (_name . (pattern . generator)) in madolt--sql-translations
           when (funcall pattern args)
           return generator))

;;;; Core execution

(defun madolt--run (&rest args)
  "Execute dolt with ARGS synchronously.
Return a cons cell (EXIT-CODE . OUTPUT-STRING).
Global arguments from `madolt-dolt-global-arguments' are prepended.
Nil arguments are removed and nested lists are flattened.
When `madolt--refresh-cache' is active, the raw result is cached
under a `raw'-prefixed key so that repeated calls with the same
arguments avoid process startup (~170ms per call).
When `madolt-use-sql-server' is enabled and a SQL translation
exists for the given args, routes through the SQL connection
instead of spawning a CLI process.  Falls back to CLI on failure."
  (let* ((args (madolt--flatten-args
                (append madolt-dolt-global-arguments args)))
         (cache-key (and madolt--refresh-cache
                         (cons 'raw (cons default-directory args)))))
    (if-let ((hit (and cache-key
                       (assoc cache-key (cdr madolt--refresh-cache)))))
        (progn
          (cl-incf (caar madolt--refresh-cache))
          (cdr hit))
      (when cache-key
        (cl-incf (cdar madolt--refresh-cache)))
      (let ((result (or (madolt--run-sql args)
                        (madolt--run-cli args))))
        (when cache-key
          (push (cons cache-key result) (cdr madolt--refresh-cache)))
        result))))

(defun madolt--run-cli (args)
  "Execute dolt CLI with ARGS synchronously.
Return (EXIT-CODE . OUTPUT-STRING).
Stderr is captured separately and only included in the output
when the exit code is non-zero, to prevent spurious warnings
\(e.g. connection errors from config.yaml) from contaminating
normal output."
  (let ((process-environment (cons "NO_COLOR=1" process-environment))
        (stderr-file (make-temp-file "madolt-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process
                             madolt-dolt-executable nil
                             (list t stderr-file) nil
                             args)))
            (if (zerop exit)
                (cons exit (buffer-string))
              ;; On error, append stderr to output for diagnostics
              (let ((stderr (with-temp-buffer
                              (insert-file-contents stderr-file)
                              (buffer-string))))
                (cons exit (concat (buffer-string) stderr))))))
      (delete-file stderr-file))))

(defun madolt--run-sql (args)
  "Try to execute ARGS via SQL translation.
Returns (0 . OUTPUT) on success, nil if no translation or connection."
  (when (and (bound-and-true-p madolt-use-sql-server)
             (fboundp 'madolt-connection-ensure))
    (when-let ((generator (madolt--find-sql-translation args)))
      (condition-case nil
          (when (funcall 'madolt-connection-ensure)
            (let* ((sql (funcall generator args))
                   (rows (funcall 'madolt-connection-query sql))
                   (output (mapconcat
                            (lambda (row) (string-join row "\t"))
                            rows "\n")))
              (cons 0 (if (string-empty-p output) output
                        (concat output "\n")))))
        (error nil)))))

;;;; Parallel prefetch

(defun madolt--prefetch (commands)
  "Launch all COMMANDS as async dolt processes, wait, populate cache.
COMMANDS is a list of argument lists (each is what you would pass
to `madolt--run').  All processes run in parallel; results are
stored in `madolt--refresh-cache' under `raw'-prefixed keys so
that subsequent `madolt--run' calls find them already cached.
Must be called while `madolt--refresh-cache' is bound.

Stderr is redirected to /dev/null to prevent spurious warnings
\(e.g. dolt sql-server connection errors) from contaminating
output.  On non-zero exit, the error is visible from the exit
code; use `madolt--run' for detailed error output."
  (let* ((dir default-directory)
         (global-args madolt-dolt-global-arguments)
         (env (cons "NO_COLOR=1" process-environment))
         (all-procs nil))
    ;; Launch all processes in parallel
    (dolist (cmd-args commands)
      (let* ((args (madolt--flatten-args (append global-args cmd-args)))
             (cache-key (cons 'raw (cons dir args))))
        ;; Skip if already cached
        (unless (assoc cache-key (cdr madolt--refresh-cache))
          (let* ((buf (generate-new-buffer " *madolt-prefetch*"))
                 (process-environment env)
                 (proc (make-process
                        :name "madolt-prefetch"
                        :buffer buf
                        :command (cons madolt-dolt-executable args)
                        :connection-type 'pipe
                        :noquery t
                        :sentinel #'ignore)))
            (process-put proc 'madolt-cache-key cache-key)
            (push proc all-procs)))))
    ;; Wait for all to complete (10s timeout).
    ;; Accept output from each live process in round-robin to ensure
    ;; all prefetch I/O is serviced.
    (let ((deadline (+ (float-time) 10.0))
          (live (copy-sequence all-procs)))
      (while (and live (< (float-time) deadline))
        (setq live (cl-remove-if-not #'process-live-p live))
        (dolist (proc live)
          (accept-process-output proc 0.05)))
      ;; Kill any stragglers
      (dolist (proc live)
        (when (process-live-p proc)
          (kill-process proc))))
    ;; Collect results into cache.
    ;; Failed commands (non-zero exit) are NOT cached so that
    ;; madolt--run falls through to a synchronous retry.  This
    ;; handles transient failures from dolt lock contention when
    ;; a stale sql-server.info is present.
    (dolist (proc all-procs)
      (let ((cache-key (process-get proc 'madolt-cache-key))
            (buf (process-buffer proc)))
        (when (buffer-live-p buf)
          (let ((exit (process-exit-status proc))
                (output (with-current-buffer buf (buffer-string))))
            (if (zerop exit)
                (progn
                  (cl-incf (cdar madolt--refresh-cache))
                  (push (cons cache-key (cons exit output))
                        (cdr madolt--refresh-cache)))
              ;; Non-zero exit: don't cache, let madolt--run retry
              (cl-incf (cdar madolt--refresh-cache))))
          (kill-buffer buf))))))

(defun madolt-dolt-string (&rest args)
  "Execute dolt with ARGS, returning the first line of output.
Return nil if exit code is non-zero or if there is no output."
  (setq args (madolt--flatten-args args))
  (madolt--with-refresh-cache (cons default-directory args)
    (let ((result (apply #'madolt--run args)))
      (and (zerop (car result))
           (not (string-empty-p (cdr result)))
           (car (split-string (cdr result) "\n" t))))))

(defun madolt-dolt-lines (&rest args)
  "Execute dolt with ARGS, returning output as a list of lines.
Empty lines are omitted."
  (setq args (madolt--flatten-args args))
  (madolt--with-refresh-cache (cons default-directory args)
    (let ((result (apply #'madolt--run args)))
      (split-string (cdr result) "\n" t))))

(defun madolt-dolt-json (&rest args)
  "Execute dolt with ARGS, returning parsed JSON output.
Return nil if the output cannot be parsed as JSON.
Uses `json-parse-string' with alist object type and list array type."
  (setq args (madolt--flatten-args args))
  (madolt--with-refresh-cache (cons default-directory args)
    (let ((result (apply #'madolt--run args)))
      (and (zerop (car result))
           (not (string-empty-p (cdr result)))
           (condition-case nil
               (json-parse-string (cdr result)
                                  :object-type 'alist
                                  :array-type 'list)
             (json-parse-error nil))))))

(defun madolt-dolt-insert (&rest args)
  "Execute dolt with ARGS, inserting output at point.
Return the exit code."
  (let ((result (apply #'madolt--run args)))
    (insert (cdr result))
    (car result)))

(defun madolt-dolt-exit-code (&rest args)
  "Execute dolt with ARGS, returning the exit code as an integer."
  (setq args (madolt--flatten-args args))
  (madolt--with-refresh-cache (cons default-directory (cons 'exit-code args))
    (car (apply #'madolt--run args))))

(defun madolt-dolt-success-p (&rest args)
  "Execute dolt with ARGS, returning non-nil if exit code is 0."
  (zerop (apply #'madolt-dolt-exit-code args)))

;;;; Database context

(defun madolt-database-dir (&optional directory)
  "Return the root directory of the Dolt database.
Search upward from DIRECTORY (or `default-directory') for a
directory containing a `.dolt/' subdirectory.
Return nil if not in a dolt database."
  (let ((dir (locate-dominating-file
              (or directory default-directory)
              (lambda (d) (file-directory-p (expand-file-name ".dolt" d))))))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun madolt-database-p (&optional directory)
  "Return non-nil if DIRECTORY is inside a Dolt database.
If DIRECTORY is nil, use `default-directory'."
  (not (null (madolt-database-dir directory))))

(defun madolt-sql-server-info ()
  "Return sql-server info if a dolt sql-server is running, or nil.
The info file `.dolt/sql-server.info' contains PID:PORT:UUID when
a server is running.  Returns a plist (:pid PID :port PORT) if
the file exists and the process is still alive, nil otherwise."
  (let ((info-file (expand-file-name ".dolt/sql-server.info"
                                     default-directory)))
    (when (file-exists-p info-file)
      (let ((contents (with-temp-buffer
                        (insert-file-contents info-file)
                        (string-trim (buffer-string)))))
        (when (string-match "\\`\\([0-9]+\\):\\([0-9]+\\):" contents)
          (let ((pid (string-to-number (match-string 1 contents)))
                (port (string-to-number (match-string 2 contents))))
            (when (and (> pid 0)
                       (file-exists-p (format "/proc/%d" pid)))
              (list :pid pid :port port))))))))

(defun madolt-check-stale-sql-server ()
  "Warn if a stale sql-server.info exists in the database directory chain.
Dolt CLI checks for sql-server.info in parent directories and attempts
to connect, which causes timeouts and failures when the server is dead.
This checks the current database directory and its parents."
  (let ((dir default-directory)
        (warned nil))
    (while (and dir (not warned))
      (let ((info-file (expand-file-name ".dolt/sql-server.info" dir)))
        (when (file-exists-p info-file)
          (let ((contents (with-temp-buffer
                            (insert-file-contents info-file)
                            (string-trim (buffer-string)))))
            (when (string-match "\\`\\([0-9]+\\):\\([0-9]+\\):" contents)
              (let ((pid (string-to-number (match-string 1 contents)))
                    (port (string-to-number (match-string 2 contents))))
                (unless (file-exists-p (format "/proc/%d" pid))
                  (message "Warning: stale sql-server.info in %s (pid %d port %d is dead). This causes slow dolt commands. Remove the file to fix."
                           dir pid port)
                  (setq warned t)))))))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (and parent
                       (not (equal parent dir))
                       (file-directory-p (expand-file-name ".dolt" parent))
                       parent))))))

(defun madolt-current-branch ()
  "Return the name of the current Dolt branch as a string."
  (let ((branch (madolt-dolt-string "branch" "--show-current")))
    (and branch (string-trim branch))))

(defun madolt-remotes ()
  "Return an alist of (NAME . URL) for configured remotes.
Parses the output of `dolt remote -v'."
  (let ((lines (madolt-dolt-lines "remote" "-v"))
        (result nil))
    (dolist (line lines)
      (when (string-match "^\\(\\S-+\\)\\s-+\\(\\S-+\\)" line)
        (let ((name (match-string 1 line))
              (url (match-string 2 line)))
          (unless (assoc name result #'string=)
            (push (cons name url) result)))))
    (nreverse result)))

(defun madolt-remote-add (name url)
  "Add a remote with NAME pointing to URL."
  (madolt--run "remote" "add" name url))

(defun madolt-remote-remove (name)
  "Remove the remote named NAME."
  (madolt--run "remote" "remove" name))

;;;; Table queries

(defun madolt-table-names ()
  "Return a list of all table names in the current database."
  (let ((result (madolt-dolt-json "sql" "-q" "SHOW TABLES" "-r" "json")))
    (when result
      (let ((rows (alist-get 'rows result)))
        (mapcar (lambda (row)
                  ;; The key name varies: "Tables_in_<dbname>"
                  (cdr (car row)))
                rows)))))

;;;; Status queries

(defun madolt-status-tables ()
  "Parse `dolt status' and return an alist of change categories.
Return value is:
  ((staged    . ((TABLE . STATUS) ...))
   (unstaged  . ((TABLE . STATUS) ...))
   (untracked . ((TABLE . STATUS) ...))
   (conflicts . ((TABLE . STATUS) ...)))
where STATUS is a string like \"modified\", \"new table\", \"renamed\",
\"deleted\", or \"both modified\"."
  (let ((output (cdr (madolt--run "status")))  ; madolt--run is not cached (mutations use it)
        (staged nil)
        (unstaged nil)
        (untracked nil)
        (conflicts nil)
        (current-section nil))
    (dolist (line (split-string output "\n"))
      (cond
       ((string-match-p "^Changes to be committed:" line)
        (setq current-section 'staged))
       ((string-match-p "^Changes not staged for commit:" line)
        (setq current-section 'unstaged))
       ((string-match-p "^Untracked tables:" line)
        (setq current-section 'untracked))
       ((string-match-p "^Unmerged paths:" line)
        (setq current-section 'conflicts))
       ;; Table entry lines are tab-indented: "\tstatus:  table_name"
       ((string-match "^\t\\([a-z ]+\\):\\s-+\\(\\S-+\\)" line)
        (let ((status (string-trim (match-string 1 line)))
              (table (match-string 2 line)))
          (pcase current-section
            ('staged    (push (cons table status) staged))
            ('unstaged  (push (cons table status) unstaged))
            ('untracked (push (cons table status) untracked))
            ('conflicts (push (cons table status) conflicts)))))))
    `((staged    . ,(nreverse staged))
      (unstaged  . ,(nreverse unstaged))
      (untracked . ,(nreverse untracked))
      (conflicts . ,(nreverse conflicts)))))

;;;; Rebase state

(defun madolt-rebase-in-progress-p ()
  "Return non-nil if a dolt rebase is currently in progress.
Checks the raw `dolt status' output for rebase indicators."
  (let ((output (madolt-dolt-string "status")))
    (and output (string-match-p "rebase in progress" output))))

;;;; Schema queries

(defun madolt-primary-key-columns (table)
  "Return the list of primary key column names for TABLE.
The result is cached per refresh cycle via `madolt--refresh-cache'."
  (let* ((json (madolt-dolt-json
                "sql" "-q"
                (format "SELECT COLUMN_NAME FROM information_schema.key_column_usage WHERE table_name='%s' AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION"
                        table)
                "-r" "json"))
         (rows (and json (alist-get 'rows json))))
    (mapcar (lambda (row) (alist-get 'COLUMN_NAME row)) rows)))

;;;; Diff queries

(defun madolt-diff-json (&rest args)
  "Run `dolt diff' with JSON output and return parsed result.
ARGS are additional arguments passed to `dolt diff'."
  (apply #'madolt-dolt-json "diff" "-r" "json" args))

(defun madolt-diff-stat (&rest args)
  "Run `dolt diff --stat' and return the output string.
ARGS are additional arguments passed to `dolt diff'."
  (cdr (apply #'madolt--run "diff" "--stat" args)))

(defun madolt-diff-raw (&rest args)
  "Run `dolt diff' and return the raw tabular output string.
ARGS are additional arguments passed to `dolt diff'."
  (cdr (apply #'madolt--run "diff" args)))

;;;; Log queries

(defun madolt-log-entries (&optional n rev extra-args)
  "Return the last N commits as a list of plists.
Each plist has keys :hash :refs :date :author :message :parents.
When --graph is in EXTRA-ARGS, each plist also has :graph (the
graph prefix string from the commit line, e.g. \"* \") and
:graph-pre (a list of graph-only junction lines that appear
between the previous commit and this one, e.g. (\"|\\\\\") for a
merge fork or (\"|/\") for a merge join).
N defaults to 10.  REV is the revision to show (branch name,
tag, or commit hash); when nil, dolt shows the current branch.
EXTRA-ARGS is a list of additional dolt log arguments
such as \"--merges\".
The :parents key holds a list of parent hash strings, parsed from
the commit line (dolt log is called with --parents).  It is nil
only for initial commits that have no parent."
  (let* ((args (append (list "log" "--parents"
                             "-n" (number-to-string (or n 10)))
                       (madolt--flatten-args extra-args)
                       (when rev (list rev))))
         (graph-mode (member "--graph" args))
         (output (cdr (apply #'madolt--run args)))
         (clean-output (madolt--strip-ansi output))
         (entries nil)
         (current-hash nil)
         (current-refs nil)
         (current-author nil)
         (current-date nil)
         (current-parents nil)
         (current-graph nil)
         (current-message-lines nil)
         (in-message nil))
    (dolist (raw-line (split-string clean-output "\n"))
      ;; Extract graph prefix before stripping it for the parser.
      ;; Graph prefix: characters from the set [|*/\ ] at start of line.
      (let* ((graph-prefix
              (when (and graph-mode
                        (string-match "^\\([|*/ \\\\]+\\) ?" raw-line))
                (match-string 1 raw-line)))
             (line (if graph-prefix
                       (replace-regexp-in-string
                        "^[|*/ \\\\]+ ?" "" raw-line)
                     raw-line)))
      (cond
       ;; Commit line with --parents:
       ;;   "commit HASH"
       ;;   "commit HASH PARENT1"
       ;;   "commit HASH PARENT1 PARENT2 (refs)"
       ;;   "commit HASH(refs)" (--graph omits space before parens)
       ((string-match "^commit \\([a-z0-9]+\\)\\(.*\\)$" line)
        ;; Save previous entry if any
        (when current-hash
          (push (list :hash current-hash
                      :refs current-refs
                      :date current-date
                      :author current-author
                      :parents current-parents
                      :graph current-graph
                      :graph-pre nil
                      :graph-post nil
                      :message (string-trim
                                (mapconcat #'identity
                                           (nreverse current-message-lines)
                                           "\n")))
                entries))
        (setq current-hash (match-string 1 line))
        ;; Store graph prefix for the commit line (contains *)
        (setq current-graph graph-prefix)
        ;; Parse remainder: optional parent hashes and optional (refs)
        (let ((rest (string-trim (match-string 2 line))))
          ;; Extract refs from trailing (...) if present
          (setq current-refs
                (when (string-match "(\\(.*\\))\\s-*$" rest)
                  (prog1 (match-string 1 rest)
                    (setq rest (string-trim
                                (substring rest 0 (match-beginning 0)))))))
          ;; Remaining words are parent hashes
          (setq current-parents
                (and (not (string-empty-p rest))
                     (split-string rest))))
        (setq current-author nil)
        (setq current-date nil)
        (setq current-message-lines nil)
        (setq in-message nil))
       ;; Merge line: "Merge: HASH1 HASH2"
       ;; Only use as fallback — --parents already provides parents
       ;; on the commit line itself.
       ((string-match "^Merge:\\s-+\\(.*\\)$" line)
        (unless current-parents
          (setq current-parents
                (split-string (string-trim (match-string 1 line))))))
       ;; Author line
       ((string-match "^Author:\\s-+\\(.*\\)$" line)
        (setq current-author (string-trim (match-string 1 line))))
       ;; Date line
       ((string-match "^Date:\\s-+\\(.*\\)$" line)
        (setq current-date (string-trim (match-string 1 line)))
        ;; Message follows after the blank line after Date
        (setq in-message t))
       ;; Blank line between date and message
       ((and in-message (string-match-p "^\\s-*$" line)
             (null current-message-lines))
        ;; Skip the blank line separator
        nil)
       ;; Message lines (tab-indented)
       ((and in-message (string-match "^\t\\(.*\\)" line))
        (push (match-string 1 line) current-message-lines))
       ;; Blank line within/after message
       ((and in-message current-message-lines
             (string-match-p "^\\s-*$" line))
        ;; Could be multi-paragraph message; keep blank lines
         (push "" current-message-lines)))))
    ;; Don't forget the last entry
    (when current-hash
      (push (list :hash current-hash
                  :refs current-refs
                  :date current-date
                  :author current-author
                  :parents current-parents
                  :graph current-graph
                  :graph-pre nil
                  :graph-post nil
                  :message (string-trim
                            (mapconcat #'identity
                                       (nreverse current-message-lines)
                                       "\n")))
            entries))
    ;; Post-process: attach graph junction lines between entries.
    ;; In graph mode, dolt outputs junction lines like "|\" and "|/"
    ;; between commits.  We do a second pass over the raw output to
    ;; extract these and attach them to each entry's :graph-pre.
    (when graph-mode
      (madolt-log--attach-graph-continuations entries clean-output))
    (nreverse entries)))

;;;; Reflog queries

(defun madolt-log--attach-graph-continuations (entries clean-output)
  "Attach graph junction lines to ENTRIES from CLEAN-OUTPUT.
ENTRIES is a reversed list of plists (newest first, as built by
`madolt-log-entries').  CLEAN-OUTPUT is the ANSI-stripped dolt log
output.  Junction lines are graph-only lines containing fork/join
characters (backslash or forward slash) that appear between
commits.  Each entry's :graph-pre is set to a list of junction
line strings that should be rendered before that entry.

Additionally, junction characters found within a commit's content
lines (e.g. the `|\\' on a Merge: line) are captured as
:graph-post on that entry, to be rendered after the commit heading."
  ;; Build a hash→entry lookup for quick access.
  (let ((hash-map (make-hash-table :test 'equal))
        (state 'between)  ; 'in-commit or 'between
        (current-entry nil)
        (junction-lines nil)
        (seen-commit-line nil))
    (dolist (entry entries)
      (puthash (plist-get entry :hash) entry hash-map))
    (dolist (raw-line (split-string clean-output "\n"))
      ;; Check if this line contains a commit header
      (cond
       ;; Commit line — find which entry it belongs to
       ((string-match "^[|*/ \\\\]* *commit \\([a-z0-9]+\\)" raw-line)
        (let ((hash (match-string 1 raw-line)))
          ;; Attach collected junction lines to this entry
          (when (and junction-lines (gethash hash hash-map))
            (plist-put (gethash hash hash-map)
                       :graph-pre (nreverse junction-lines)))
          (setq junction-lines nil)
          (setq current-entry (gethash hash hash-map))
          (setq seen-commit-line t)
          (setq state 'in-commit)))
       ;; Content line within a commit that has junction chars in its
       ;; graph prefix (e.g. "|\ Merge: ...").  Capture the graph
       ;; prefix as :graph-post on the current entry.
       ((and (eq state 'in-commit) seen-commit-line current-entry
             (string-match "^\\([|*/ \\\\]+\\)\\s-+" raw-line)
             (string-match-p "[/\\\\]" (match-string 1 raw-line))
             ;; Only capture the first junction within a commit
             (not (plist-get current-entry :graph-post)))
        (plist-put current-entry :graph-post
                   (list (string-trim-right (match-string 1 raw-line))))
        ;; Don't change state — still in-commit
        )
       ;; Graph-only line with junction chars (\ or /) — collect as
       ;; junction line.  When in-commit, this also triggers a
       ;; transition to between-commits state (e.g. "|  /" after a
       ;; commit's message marks the start of the join region).
       ((and (string-match "^\\([|*/ \\\\]+\\)\\s-*$" raw-line)
             (string-match-p "[/\\\\]" raw-line))
        (when (eq state 'in-commit)
          (setq state 'between))
        (push (match-string 1 raw-line) junction-lines))
       ;; Blank line after message — transition to 'between state
       ;; A line that is just graph continuation (| or | |) with no
       ;; content after stripping indicates we're between commits.
       ((and current-entry
             (string-match "^\\([|*/ \\\\]*\\)\\s-*$" raw-line)
             (not (string-match-p "[/\\\\]" raw-line)))
        ;; Pure continuation line (just | chars) — marks end of
        ;; commit content, transition to between-commits state.
        ;; Only set state after message has been seen.
        (when (eq state 'in-commit)
          (setq state 'between)))))))

(defun madolt-reflog-entries (&optional ref all)
  "Return reflog entries as a list of plists.
Each plist has keys :hash :refs :message.
REF is an optional branch/tag name to filter (default: all refs
for current branch).  When ALL is non-nil, pass --all to show
hidden refs too.

Dolt reflog output format (one line per entry):
  HASH (refs) message"
  (let* ((args (append (list "reflog")
                       (when all (list "--all"))
                       (when ref (list ref))))
         (output (cdr (apply #'madolt--run args)))
         (clean (madolt--strip-ansi output))
         (entries nil))
    (dolist (line (split-string clean "\n" t))
      (when (string-match
             "^\\([a-z0-9]+\\)\\s-+(\\(.*?\\))\\s-+\\(.*\\)$"
             line)
        (push (list :hash (match-string 1 line)
                    :refs (match-string 2 line)
                    :message (string-trim (match-string 3 line)))
              entries)))
    (nreverse entries)))

;;;; Mutation operations

(defun madolt-add-tables (tables)
  "Stage TABLES for commit.
TABLES is a list of table name strings."
  (apply #'madolt--run "add" tables))

(defun madolt-add-all ()
  "Stage all changed tables for commit."
  (madolt--run "add" "."))

(defun madolt-reset-tables (tables)
  "Unstage TABLES.
TABLES is a list of table name strings."
  (apply #'madolt--run "reset" tables))

(defun madolt-reset-all ()
  "Unstage all staged tables."
  (madolt--run "reset"))

(defun madolt-checkout-table (table)
  "Discard working change to TABLE."
  (madolt--run "checkout" table))

;;;; Branch operations

(defun madolt-branch-names ()
  "Return a list of branch names in the current database."
  (let ((lines (madolt-dolt-lines "branch")))
    (mapcar (lambda (line)
              (string-trim (replace-regexp-in-string "^\\*\\s-*" "" line)))
            lines)))

(defun madolt-branch-list-verbose ()
  "Return a list of branch plists from `dolt branch -av'.
Each plist has keys :name :hash :message :current :remote.
Local branches have :remote nil; remote tracking branches have
:remote set to the remote name."
  (let ((lines (madolt-dolt-lines "branch" "-av"))
        result)
    (dolist (line lines)
      (when (string-match
             "^\\(\\*?\\)\\s-*\\(\\S-+\\)\\s-+\\(\\S-+\\)\\s-+\\(.*\\)$"
             line)
        (let* ((current (not (string-empty-p (match-string 1 line))))
               (name (match-string 2 line))
               (hash (match-string 3 line))
               (message (string-trim (match-string 4 line)))
               (remote nil))
          (when (string-match "^remotes/\\([^/]+\\)/\\(.*\\)$" name)
            (setq remote (match-string 1 name))
            (setq name (match-string 2 name)))
          (push (list :name name :hash hash :message message
                      :current current :remote remote)
                result))))
    (nreverse result)))

(defun madolt-branch-create (name &optional start-point)
  "Create a new branch NAME, optionally from START-POINT.
Does not switch to the new branch."
  (if start-point
      (madolt--run "branch" name start-point)
    (madolt--run "branch" name)))

(defun madolt-branch-checkout (name)
  "Switch to branch NAME."
  (madolt--run "checkout" name))

(defun madolt-branch-checkout-create (name &optional start-point)
  "Create and switch to a new branch NAME, optionally from START-POINT."
  (if start-point
      (madolt--run "checkout" "-b" name start-point)
    (madolt--run "checkout" "-b" name)))

(defun madolt-branch-delete (name &optional force)
  "Delete branch NAME.
When FORCE is non-nil, use -D (force delete)."
  (madolt--run "branch" (if force "-D" "-d") name))

(defun madolt-branch-rename (old-name new-name)
  "Rename branch OLD-NAME to NEW-NAME."
  (madolt--run "branch" "-m" old-name new-name))

;;;; Remote operations

(defun madolt-remote-names ()
  "Return a list of remote names."
  (mapcar #'car (madolt-remotes)))

(defun madolt-remote-branch-exists-p (remote branch)
  "Return non-nil if REMOTE has BRANCH.
Checks `dolt branch -a' output for remotes/REMOTE/BRANCH."
  (let ((ref (format "remotes/%s/%s" remote branch)))
    (seq-some (lambda (line)
                (string= (string-trim line) ref))
              (madolt-dolt-lines "branch" "-a"))))

;;;; Upstream tracking

(defun madolt-upstream-ref (&optional branch)
  "Return the upstream remote ref for BRANCH, or nil.
Dolt does not have git-style upstream tracking, so this uses the
convention of looking for origin/BRANCH.  If no remote named
\"origin\" exists, the first configured remote is tried.
BRANCH defaults to the current branch."
  (let* ((branch (or branch (madolt-current-branch)))
         (remotes (madolt-remote-names))
         (remote (if (member "origin" remotes)
                     "origin"
                   (car remotes))))
    (when (and remote branch
               (madolt-remote-branch-exists-p remote branch))
      (format "%s/%s" remote branch))))

(defun madolt-unpushed-commits (&optional upstream)
  "Return commits in HEAD that are not in UPSTREAM.
UPSTREAM defaults to the result of `madolt-upstream-ref'.
Returns a list of plists with keys :hash :refs :date :author :message,
or nil if there is no upstream or no unpushed commits."
  (let ((upstream (or upstream (madolt-upstream-ref))))
    (when upstream
      (madolt-log-entries 100 (format "%s..HEAD" upstream)))))

(defun madolt-unpulled-commits (&optional upstream)
  "Return commits in UPSTREAM that are not in HEAD.
UPSTREAM defaults to the result of `madolt-upstream-ref'.
Returns a list of plists with keys :hash :refs :date :author :message,
or nil if there is no upstream or no unpulled commits."
  (let ((upstream (or upstream (madolt-upstream-ref))))
    (when upstream
      (madolt-log-entries 100 (format "HEAD..%s" upstream)))))

;;;; Tag operations

(defun madolt-tag-names ()
  "Return a list of tag names in the current database."
  (mapcar #'string-trim (madolt-dolt-lines "tag")))

(defun madolt-tag-list-verbose ()
  "Return a list of tag plists from `dolt tag -v'.
Each plist has keys :name, :hash, and :message.
The :message is the tag annotation (nil for lightweight tags)."
  (let ((output (madolt-dolt-string "tag" "-v"))
        result current-tag)
    (when output
      (dolist (line (split-string output "\n"))
        (cond
         ;; Tag header line: "tagname\thash"
         ((string-match "^\\(\\S-+\\)\t\\(\\S-+\\)" line)
          (when current-tag
            (push current-tag result))
          (setq current-tag (list :name (match-string 1 line)
                                  :hash (match-string 2 line)
                                  :message nil)))
         ;; Annotation message line (indented with tab)
         ((and current-tag
               (string-match "^\t\\(.+\\)" line))
          (let ((msg (match-string 1 line))
                (existing (plist-get current-tag :message)))
            (plist-put current-tag :message
                       (if existing (concat existing " " msg) msg))))
         ;; Skip Tagger:/Date: lines
         ))
      (when current-tag
        (push current-tag result)))
    (nreverse result)))

(defun madolt-tag-create (name &optional ref message)
  "Create a tag NAME, optionally at REF with MESSAGE.
When MESSAGE is non-nil, create an annotated tag."
  (let ((args (list "tag")))
    (when message
      (setq args (append args (list "-m" message))))
    (setq args (append args (list name)))
    (when ref
      (setq args (append args (list ref))))
    (apply #'madolt--run args)))

(defun madolt-tag-delete (name)
  "Delete tag NAME."
  (madolt--run "tag" "-d" name))

;;;; SQL translations for read-only queries

;; These register SQL equivalents for CLI commands so that
;; madolt--run can route through sql-server when available.

(madolt--register-sql-translation
 'branch-show-current
 (lambda (args)
   (and (equal (car args) "branch")
        (member "--show-current" args)))
 (lambda (_args) "SELECT active_branch()"))

(madolt--register-sql-translation
 'branch-list
 (lambda (args)
   (and (equal (car args) "branch")
        (not (member "-d" args))
        (not (member "-m" args))
        (not (member "-c" args))
        (not (member "--show-current" args))
        (not (member "-a" args))
        (not (member "-r" args))
        (not (member "-v" args))))
 (lambda (_args) "SELECT CONCAT(IF(name = active_branch(), '* ', '  '), name) FROM dolt_branches ORDER BY name"))

(madolt--register-sql-translation
 'remote-list
 (lambda (args)
   (and (equal (car args) "remote")
        (member "-v" args)))
 (lambda (_args)
   "SELECT CONCAT(name, '\t', url) FROM dolt_remotes ORDER BY name"))

(madolt--register-sql-translation
 'tag-list
 (lambda (args)
   (and (equal (car args) "tag")
        (not (member "-d" args))
        (not (member "-v" args))))
 (lambda (_args) "SELECT tag_name FROM dolt_tags ORDER BY tag_name"))

(madolt--register-sql-translation
 'status
 (lambda (args) (equal args '("status")))
 (lambda (_args) "SELECT table_name, staged, status FROM dolt_status"))

(madolt--register-sql-translation
 'ls
 (lambda (args) (equal args '("ls")))
 (lambda (_args) "SHOW TABLES"))

;;;; SQL translations for log queries

(madolt--register-sql-translation
 'log-basic
 (lambda (args)
   (and (equal (car args) "log")
        (member "--parents" args)
        (not (member "--graph" args))))
 (lambda (args)
   ;; Parse -n limit and optional rev/range
   (let ((limit 10) rev)
     (cl-loop for (a b) on args
              do (cond ((equal a "-n") (setq limit (string-to-number b)))
                       ((and (not (string-prefix-p "-" a))
                             (not (equal a "log"))
                             (not (equal a "--parents")))
                        (setq rev a))))
     (if rev
         (format "SELECT commit_hash, committer, email, date, message, parent_hashes FROM dolt_log('%s') LIMIT %d"
                 rev limit)
       (format "SELECT commit_hash, committer, email, date, message, parent_hashes FROM dolt_log LIMIT %d"
               limit)))))

;;;; SQL translations for mutation commands (DOLT_* stored procedures)

(madolt--register-sql-translation
 'add-tables
 (lambda (args)
   (and (equal (car args) "add")
        (not (member "--help" args))))
 (lambda (args)
   (let ((tables (cl-remove-if (lambda (a) (or (equal a "add")
                                               (string-prefix-p "-" a)))
                               args)))
     (if (member "." tables)
         "CALL DOLT_ADD('.')"
       (format "CALL DOLT_ADD(%s)"
               (mapconcat (lambda (tbl) (format "'%s'" tbl)) tables ", "))))))

(madolt--register-sql-translation
 'reset-tables
 (lambda (args)
   (and (equal (car args) "reset")
        (not (member "--help" args))))
 (lambda (args)
   (let ((tables (cl-remove-if (lambda (a) (or (equal a "reset")
                                               (string-prefix-p "-" a)))
                               args)))
     (if (or (null tables) (member "." tables))
         "CALL DOLT_RESET('.')"
       (format "CALL DOLT_RESET(%s)"
               (mapconcat (lambda (tbl) (format "'%s'" tbl)) tables ", "))))))

(madolt--register-sql-translation
 'commit-msg
 (lambda (args)
   (and (equal (car args) "commit")
        (member "-m" args)))
 (lambda (args)
   (let* ((msg-idx (cl-position "-m" args :test #'equal))
          (msg (and msg-idx (nth (1+ msg-idx) args)))
          (all (or (member "--all" args) (member "-a" args)))
          (ALL (member "--ALL" args)))
     (cond
      (ALL (format "CALL DOLT_COMMIT('--ALL', '-m', '%s')"
                   (replace-regexp-in-string "'" "''" (or msg ""))))
      (all (format "CALL DOLT_COMMIT('-a', '-m', '%s')"
                   (replace-regexp-in-string "'" "''" (or msg ""))))
      (t (format "CALL DOLT_COMMIT('-m', '%s')"
                 (replace-regexp-in-string "'" "''" (or msg ""))))))))

(madolt--register-sql-translation
 'checkout-branch
 (lambda (args)
   (and (equal (car args) "checkout")
        (= (length args) 2)
        (not (string-prefix-p "-" (nth 1 args)))))
 (lambda (args)
   (format "CALL DOLT_CHECKOUT('%s')" (nth 1 args))))

(madolt--register-sql-translation
 'branch-create
 (lambda (args)
   (and (equal (car args) "branch")
        (>= (length args) 2)
        (not (member "-d" args))
        (not (member "-m" args))
        (not (member "-c" args))
        (not (member "-v" args))
        (not (member "-a" args))
        (not (member "-r" args))
        (not (member "--show-current" args))
        (not (member "--list" args))
        (not (string-prefix-p "-" (nth 1 args)))))
 (lambda (args)
   (let ((name (nth 1 args))
         (start (and (>= (length args) 3) (nth 2 args))))
     (if start
         (format "CALL DOLT_BRANCH('%s', '%s')" name start)
       (format "CALL DOLT_BRANCH('%s')" name)))))

(madolt--register-sql-translation
 'branch-delete
 (lambda (args)
   (and (equal (car args) "branch")
        (member "-d" args)))
 (lambda (args)
   (let ((name (car (cl-remove-if
                     (lambda (a) (or (equal a "branch")
                                     (string-prefix-p "-" a)))
                     args)))
         (force (or (member "-f" args) (member "--force" args))))
     (if force
         (format "CALL DOLT_BRANCH('-D', '%s')" name)
       (format "CALL DOLT_BRANCH('-d', '%s')" name)))))

(madolt--register-sql-translation
 'branch-rename
 (lambda (args)
   (and (equal (car args) "branch")
        (member "-m" args)))
 (lambda (args)
   (let ((names (cl-remove-if
                 (lambda (a) (or (equal a "branch")
                                 (string-prefix-p "-" a)))
                 args)))
     (format "CALL DOLT_BRANCH('-m', '%s', '%s')"
             (nth 0 names) (nth 1 names)))))

(madolt--register-sql-translation
 'tag-create
 (lambda (args)
   (and (equal (car args) "tag")
        (>= (length args) 2)
        (not (member "-d" args))
        (not (member "-v" args))
        (not (string-prefix-p "-" (nth 1 args)))))
 (lambda (args)
   (let* ((name (nth 1 args))
          (msg-idx (cl-position "-m" args :test #'equal))
          (msg (and msg-idx (nth (1+ msg-idx) args)))
          (ref (car (cl-remove-if
                     (lambda (a) (or (equal a "tag")
                                     (equal a name)
                                     (equal a "-m")
                                     (and msg (equal a msg))
                                     (string-prefix-p "-" a)))
                     args))))
     (cond
      ((and msg ref)
       (format "CALL DOLT_TAG('%s', '%s', '-m', '%s')"
               name ref (replace-regexp-in-string "'" "''" msg)))
      (msg
       (format "CALL DOLT_TAG('%s', '-m', '%s')"
               name (replace-regexp-in-string "'" "''" msg)))
      (ref (format "CALL DOLT_TAG('%s', '%s')" name ref))
      (t (format "CALL DOLT_TAG('%s')" name))))))

(madolt--register-sql-translation
 'tag-delete
 (lambda (args)
   (and (equal (car args) "tag")
        (member "-d" args)))
 (lambda (args)
   (let ((name (car (cl-remove-if
                     (lambda (a) (or (equal a "tag")
                                     (string-prefix-p "-" a)))
                     args))))
     (format "CALL DOLT_TAG('-d', '%s')" name))))

(madolt--register-sql-translation
 'fetch
 (lambda (args) (equal (car args) "fetch"))
 (lambda (args)
   (let ((remote (or (nth 1 args) "origin")))
     (format "CALL DOLT_FETCH('%s')" remote))))

(madolt--register-sql-translation
 'pull
 (lambda (args) (equal (car args) "pull"))
 (lambda (args)
   (let ((remote (or (nth 1 args) "origin")))
     (format "CALL DOLT_PULL('%s')" remote))))

(madolt--register-sql-translation
 'push
 (lambda (args) (equal (car args) "push"))
 (lambda (args)
   (let ((remote (or (nth 1 args) "origin")))
     (format "CALL DOLT_PUSH('%s')" remote))))

(madolt--register-sql-translation
 'merge
 (lambda (args)
   (and (equal (car args) "merge")
        (>= (length args) 2)))
 (lambda (args)
   (let ((branch (nth 1 args)))
     (format "CALL DOLT_MERGE('%s')" branch))))

(provide 'madolt-dolt)
;;; madolt-dolt.el ends here
