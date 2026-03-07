# Madolt MVP Specification

A magit-like Emacs interface for the Dolt version-controlled database.

## Overview

Madolt provides a section-based, keyboard-driven UI for Dolt's
Git-like version control operations on SQL databases. The core loop
is: view status → stage tables → write commit message → view history.

## Dependencies

| Package         | Version | Role                                        | Reuse type |
|-----------------|---------|---------------------------------------------|------------|
| `magit-section` | >= 4.0  | Section UI: insert, navigate, collapse      | Direct     |
| `transient`     | >= 0.7  | Popup menus with sticky arguments           | Direct     |
| `with-editor`   | >= 3.0  | Commit message editing via `$EDITOR`        | Direct     |
| `compat`        | >= 30.1 | Emacs version compatibility                 | Direct     |

All four are already available on the target system (Emacs 30.1,
straight.el). No custom forks needed for any of them.

### Why not emacsql?

emacsql encodes all values as printed s-expressions. A Dolt database
written by non-Emacs tools (which is the normal case) would produce
values that emacsql's `(read ...)` parser misinterprets. The MySQL
backend is also marked "not recommended" by its maintainer.

Instead, madolt shells out to `dolt` CLI commands directly:
- Version-control operations: `dolt status`, `dolt diff`, `dolt log`, etc.
- SQL queries: `dolt sql -q "..." -r json` for structured results.
- No `dolt sql-server` dependency.

## File Structure

```
madolt/
  madolt.el              ;; Entry point, autoloads, defgroup, defcustoms
  madolt-dolt.el         ;; Dolt CLI wrapper layer
  madolt-mode.el         ;; Major mode, buffer lifecycle, refresh
  madolt-process.el      ;; Process execution + logging
  madolt-status.el       ;; Status buffer
  madolt-diff.el         ;; Tabular diff viewer
  madolt-log.el          ;; Commit log viewer
  madolt-commit.el       ;; Commit transient + commands
  madolt-apply.el        ;; Stage/unstage/discard operations
```

## Implementation Order

Build bottom-up; each step is independently testable.

1. `madolt-dolt.el` — CLI wrapper (foundation for everything)
2. `madolt-process.el` — process execution with logging
3. `madolt-mode.el` — major mode, buffer setup, refresh cycle
4. `madolt.el` — entry point, defgroup, autoloads
5. `madolt-status.el` — status buffer (the main UI)
6. `madolt-apply.el` — stage/unstage/discard
7. `madolt-commit.el` — commit transient + message editing
8. `madolt-diff.el` — tabular diff viewer
9. `madolt-log.el` — commit log viewer

---

## File-by-File Design

### madolt-dolt.el (~400 LOC)

Dolt CLI wrapper layer. Modeled on `magit-git.el`: same abstraction
pattern (executable + global args + output-parsing helpers), different
binary.

#### Configuration

```elisp
(defcustom madolt-dolt-executable "dolt"
  "The Dolt executable."
  :type 'string)

(defcustom madolt-dolt-global-arguments nil
  "Arguments prepended to every dolt invocation."
  :type '(repeat string))
```

#### Core execution functions

| Function               | Signature                        | Returns                          |
|------------------------|----------------------------------|----------------------------------|
| `madolt--run`          | `(&rest args)`                   | `(exit-code . output-string)`    |
| `madolt-dolt-string`   | `(&rest args)`                   | First line of output, or nil     |
| `madolt-dolt-lines`    | `(&rest args)`                   | List of output lines             |
| `madolt-dolt-json`     | `(&rest args)`                   | Parsed JSON (via `json-parse-*`) |
| `madolt-dolt-insert`   | `(&rest args)`                   | Inserts output at point          |
| `madolt-dolt-exit-code`| `(&rest args)`                   | Integer exit code                |
| `madolt-dolt-success-p`| `(&rest args)`                   | Boolean                          |

All functions prepend `madolt-dolt-global-arguments` and run the
command synchronously via `call-process` with `default-directory` set
to the database root.

#### Database context

| Function              | Returns                                   |
|-----------------------|-------------------------------------------|
| `madolt-database-dir` | Absolute path of directory containing `.dolt/`, searching upward from `default-directory`. Nil if not in a dolt database. |
| `madolt-database-p`   | Non-nil if `default-directory` is inside a dolt database. |
| `madolt-current-branch` | Current branch name string.             |

#### Status queries

```elisp
(madolt-status-tables)
;; => ((staged    . (("users" . "modified") ("orders" . "new table")))
;;     (unstaged  . (("products" . "modified")))
;;     (untracked . (("inventory" . "new table"))))
```

Parses `dolt status` output. The output format mirrors `git status`
closely — "Changes to be committed", "Changes not staged for commit",
"Untracked tables" — so the parser is a straightforward regexp walk.

#### Diff queries

| Function            | Args                    | Returns                          |
|---------------------|-------------------------|----------------------------------|
| `madolt-diff-json`  | `(&optional args)`      | Parsed JSON from `dolt diff -r json` |
| `madolt-diff-stat`  | `(&optional args)`      | Stats string from `dolt diff --stat` |
| `madolt-diff-raw`   | `(&optional args)`      | Raw tabular output string        |

#### Log queries

| Function             | Args            | Returns                              |
|----------------------|-----------------|--------------------------------------|
| `madolt-log-entries` | `(&optional n)` | List of `(hash branch-info date author message)` |

Parses `dolt log` default output format, which is nearly identical to
`git log`.

#### Mutation operations

| Function              | Args                | Runs                          |
|-----------------------|---------------------|-------------------------------|
| `madolt-add-tables`   | `(tables)`          | `dolt add TABLE...`           |
| `madolt-add-all`      | `()`                | `dolt add .`                  |
| `madolt-reset-tables` | `(tables)`          | `dolt reset TABLE...`         |
| `madolt-reset-all`    | `()`                | `dolt reset`                  |
| `madolt-checkout-table` | `(table)`         | `dolt checkout TABLE`         |

---

### madolt-process.el (~250 LOC)

Process execution with logging. Modeled on `magit-process.el` but
synchronous-only for MVP.

#### Process buffer

Each dolt database gets a process log buffer named
`*madolt-process: <dir>*`. Every command invocation is logged as a
`magit-insert-section` entry showing:

```
$ dolt status                              [exit: 0]
On branch main
...

$ dolt add users                           [exit: 0]
```

Each invocation is a collapsible section (type `process`). Exit code
is shown in the heading, color-coded: 0 = green, non-zero = red.

#### Functions

| Function            | Description                                         |
|---------------------|-----------------------------------------------------|
| `madolt-process-buffer` | Return (creating if needed) the process buffer for `default-directory` |
| `madolt-call-dolt`  | Run dolt synchronously, log to process buffer, return `(exit-code . output)` |
| `madolt-run-dolt`   | Same as `madolt-call-dolt` but also calls `madolt-refresh` afterward |

#### Keybinding

`$` in any madolt buffer opens the process log buffer.

---

### madolt-mode.el (~300 LOC)

Major mode definition, buffer management, and refresh cycle. Modeled
on `magit-mode.el`.

#### Major mode

```elisp
(define-derived-mode madolt-mode magit-section-mode "Madolt"
  "Parent mode for all Madolt buffers."
  :group 'madolt)
```

Derived from `magit-section-mode`, which itself derives from
`special-mode`. This gives us section navigation, expand/collapse,
visibility levels, and highlighting for free.

#### Sub-modes

```elisp
(define-derived-mode madolt-status-mode madolt-mode "Madolt Status")
(define-derived-mode madolt-diff-mode   madolt-mode "Madolt Diff")
(define-derived-mode madolt-log-mode    madolt-mode "Madolt Log")
```

#### Buffer lifecycle

| Function               | Description                                              |
|------------------------|----------------------------------------------------------|
| `madolt-setup-buffer`  | Create or reuse a buffer for a given mode. Set `default-directory` to the database root. Call refresh. |
| `madolt-refresh`       | Erase buffer, re-run mode-specific `*-sections-hook`, restore cursor position via `magit-section-ident`. |
| `madolt-display-buffer`| Display the buffer (configurable strategy).              |

The refresh function discovers the mode-specific refresh function by
convention: for `madolt-status-mode`, it calls
`madolt-status-refresh-buffer`.

#### Position preservation

Before erasing, save the `magit-section-ident` at point and the
relative position within the section. After re-inserting, use
`magit-get-section` to find the same section and restore the cursor.
This is the same approach magit uses.

#### Keymap (madolt-mode-map)

These bindings are available in all madolt buffers:

| Key   | Command                  | Category   |
|-------|--------------------------|------------|
| `g`   | `madolt-refresh`         | Buffer     |
| `q`   | `quit-window`            | Buffer     |
| `$`   | `madolt-process-buffer`  | Buffer     |
| `?`/`h` | `madolt-dispatch`      | Help       |
| `s`   | `madolt-stage`           | Apply      |
| `S`   | `madolt-stage-all`       | Apply      |
| `u`   | `madolt-unstage`         | Apply      |
| `U`   | `madolt-unstage-all`     | Apply      |
| `k`   | `madolt-discard`         | Apply      |
| `c`   | `madolt-commit`          | Commit     |
| `d`   | `madolt-diff`            | Diff       |
| `l`   | `madolt-log`             | Log        |
| `RET` | `madolt-visit-thing`     | Navigation |
| `TAB` | (inherited)              | Section    |
| `n`/`p` | (inherited)            | Section    |

---

### madolt.el (~100 LOC)

Entry point, customization group, autoloads.

```elisp
(defgroup madolt nil
  "A magit-like interface for the Dolt database."
  :group 'tools
  :prefix "madolt-")

;;;###autoload
(defun madolt-status (&optional directory)
  "Open the madolt status buffer for DIRECTORY.
If DIRECTORY is nil, search upward from `default-directory' for a
Dolt database (a directory containing `.dolt/')."
  (interactive)
  ...)

;;;###autoload
(transient-define-prefix madolt-dispatch ()
  "Show the main madolt dispatch menu."
  ["Madolt"
   ("s" "Status"  madolt-status)
   ("d" "Diff"    madolt-diff)
   ("l" "Log"     madolt-log)
   ("c" "Commit"  madolt-commit)
   ("$" "Process" madolt-process-buffer)
   ("Q" "SQL"     madolt-sql-query)])
```

---

### madolt-status.el (~350 LOC)

The status buffer — the main entry point and central hub.

#### Buffer layout

Driven by `madolt-status-sections-hook`:

```
Head:   main  a4i9j85e  Last commit message here
Remote: origin  https://dolthub.com/...

Staged changes (2)
  modified   users
  new table  orders

Unstaged changes (1)
  modified   products

Untracked tables (1)
  new table  inventory

Stashes (1)
  stash@{0}: WIP on main: a4i9j85e Last commit

Recent commits
  a4i9j85e  Add users table with initial data
  omthk7li  Initialize data repository
```

#### Section inserter functions

| Function                         | Section type  | Data source            |
|----------------------------------|---------------|------------------------|
| `madolt-insert-status-header`    | (header)      | `dolt branch --show-current`, last commit |
| `madolt-insert-staged-changes`   | `staged`      | `madolt-status-tables`  |
| `madolt-insert-unstaged-changes` | `unstaged`    | `madolt-status-tables`  |
| `madolt-insert-untracked-tables` | `untracked`   | `madolt-status-tables`  |
| `madolt-insert-stashes`          | `stashes`     | `dolt stash list`       |
| `madolt-insert-recent-commits`   | `recent`      | `madolt-log-entries`    |

Each table within staged/unstaged/untracked is a child section of type
`table` with value = table name.

#### Inline diff expansion

Pressing `TAB` on a table section in the status buffer expands it to
show the diff for that table inline, using a `washer` function that
calls `madolt-diff-insert-table` (deferred loading, only fetched when
the section is first expanded).

#### Section actions

| Key   | On section type | Action                            |
|-------|-----------------|-----------------------------------|
| `s`   | `table` (unstaged/untracked) | `dolt add TABLE`     |
| `s`   | `unstaged` heading | `dolt add .`                     |
| `u`   | `table` (staged) | `dolt reset TABLE`               |
| `u`   | `staged` heading | `dolt reset`                      |
| `k`   | `table` (unstaged) | `dolt checkout TABLE` (confirm) |
| `RET` | `table`         | Open diff buffer for that table   |
| `RET` | `commit`        | Open revision buffer              |

---

### madolt-apply.el (~200 LOC)

Stage, unstage, and discard operations.

#### Key difference from magit

Dolt stages whole tables, not hunks. There is no partial staging.
`dolt add` operates on table names, not file paths. This makes the
apply layer simpler than magit's.

#### Functions

| Function           | Behavior                                          |
|--------------------|---------------------------------------------------|
| `madolt-stage`     | Stage the table at point, or all tables if on a section heading. Context-sensitive via `magit-section-case`. |
| `madolt-stage-all` | `dolt add .` — stage everything.                  |
| `madolt-unstage`   | Unstage the table at point, or all if on heading. |
| `madolt-unstage-all` | `dolt reset` — unstage everything.              |
| `madolt-discard`   | `dolt checkout TABLE` — discard working changes. Prompts for confirmation with `y-or-n-p`. |

Each function calls `madolt-run-dolt` (which refreshes the buffer
after the operation completes).

---

### madolt-commit.el (~350 LOC)

Commit transient and commit message editing.

#### Reuse strategy

- **`with-editor`**: used directly, unmodified. Dolt respects
  `core.editor` and `$EDITOR`, so `with-editor` works out of the box.
- **`transient`**: used directly for the commit menu.
- **`git-commit.el`**: adapted. The font-lock rules, style checks
  (summary length, blank second line), and message ring from
  `git-commit.el` are forked into a `madolt-commit-message-mode` minor
  mode. Git-specific parts (branch name detection in comments,
  `magit-get` calls, diff propertization) are replaced with dolt
  equivalents or dropped.

#### Transient menu

```elisp
(transient-define-prefix madolt-commit ()
  "Create a commit."
  :man-page "dolt_commit"
  ["Arguments"
   ("-a" "Stage all modified and deleted tables" "--all")
   ("-A" "Stage all tables (including new)"      "--ALL")
   ("-e" "Allow empty commit"                    "--allow-empty")
   ("-f" "Force (ignore constraint warnings)"    "--force")
   ("-S" "GPG sign"                              "--gpg-sign")
   ("=d" "Override date"                         "--date=")
   ("=A" "Override author"                       "--author=")]
  ["Create"
   ("c" "Commit"  madolt-commit-create)
   ("a" "Amend"   madolt-commit-amend)]
  ["Edit"
   ("m" "Message"  madolt-commit-message)])
```

Note: dolt has no fixup/squash/rebase, so the menu is much simpler
than magit's.

#### Commit commands

| Function                 | Description                                   |
|--------------------------|-----------------------------------------------|
| `madolt-commit-create`   | Run `dolt commit` with transient args. If no `-m`, use `with-editor` to open message editor. |
| `madolt-commit-amend`    | Run `dolt commit --amend`. Opens editor for message. |
| `madolt-commit-message`  | Run `dolt commit -m MSG` with a message read from the minibuffer (quick commit, no editor). |

#### Commit message editing flow

1. `madolt-commit-create` calls `(with-editor (madolt-start-dolt "commit" args))`.
2. Dolt creates a temp file and invokes `$EDITOR` (= emacsclient).
3. Emacs opens the temp file. `madolt-commit-message-mode` is
   activated via a `find-file-hook` that matches dolt's temp file
   pattern.
4. The minor mode provides:
   - Summary line length highlighting (default 68 chars)
   - `C-c C-c` to finish (via `with-editor-mode`)
   - `C-c C-k` to cancel
   - `M-p`/`M-n` for message history (via `log-edit-comment-ring`)
5. On finish, dolt reads the message and creates the commit.
6. `madolt-refresh` runs to update the status buffer.

#### Commit assertion

`madolt-commit-assert` checks preconditions before committing:
- Are there staged changes? If not, offer to stage all (`--all`).
- Is this an empty commit? Require `--allow-empty`.

#### Detecting dolt's editor temp file

Dolt uses Go's `os.CreateTemp` to create the commit message file.
The pattern is something like `/tmp/dolt-commit-msg-*` or similar.
`madolt-commit-filename-regexp` matches this pattern and triggers
`madolt-commit-message-mode` via `find-file-hook`.

If the exact pattern proves hard to detect reliably, an alternative
is to set `core.editor` to a wrapper script that creates the file at
a predictable path inside `.dolt/COMMIT_EDITMSG` before invoking
emacsclient. But this is a fallback — try the temp file approach
first.

---

### madolt-diff.el (~500 LOC)

Tabular diff viewer. Written from scratch — this is the most novel
component. Dolt diffs are row-level and cell-level, not line-based
text diffs like git.

#### Two rendering modes

**1. Structured mode** (default): parse `dolt diff -r json`, render
a custom tabular view.

**2. Raw mode**: insert `dolt diff` native tabular output with
syntax highlighting applied.

The user can toggle between modes with a transient argument.

#### Dolt diff output formats

`dolt diff -r json` returns:

```json
{
  "tables": [{
    "name": "users",
    "schema_diff": ["..."],
    "data_diff": [
      {
        "from_row": {"id": 1, "name": "Alice", "email": "old@ex.com"},
        "to_row":   {"id": 1, "name": "Alice", "email": "new@ex.com"}
      },
      {
        "from_row": {},
        "to_row":   {"id": 3, "name": "Charlie", "email": "c@ex.com"}
      }
    ]
  }]
}
```

`dolt diff` (default tabular) returns:

```
diff --dolt a/users b/users
--- a/users
+++ b/users
+---+----+---------+---------------------------+
|   | id | name    | email                     |
+---+----+---------+---------------------------+
| < | 1  | Alice   | old@ex.com                |
| > | 1  | Alice   | new@ex.com                |
| + | 3  | Charlie | c@ex.com                  |
+---+----+---------+---------------------------+
```

Row markers: `<` = old (before), `>` = new (after), `+` = added,
`-` = deleted.

#### Section hierarchy (structured mode)

```
diff (root)
  table-diff "users"              ;; type: table-diff, value: table name
    schema-diff                   ;; type: schema-diff (if schema changed)
      (CREATE TABLE / ALTER diff)
    data-diff                     ;; type: data-diff
      row-diff (id=1, modified)   ;; type: row-diff
        old: id=1 name=Alice email=old@ex.com
        new: id=1 name=Alice email=new@ex.com
      row-diff (id=3, added)
        new: id=3 name=Charlie email=c@ex.com
  table-diff "orders"
    ...
```

Each `row-diff` section is collapsible. When collapsed, it shows a
one-line summary (e.g., `modified  id=1  (1 cell changed)`). When
expanded, it shows old and new values side by side or stacked.

#### Section hierarchy (raw mode)

```
diff (root)
  table-diff "users"
    (raw tabular output with faces applied)
  table-diff "orders"
    ...
```

The raw output is split per-table using the `diff --dolt a/TABLE
b/TABLE` header lines. Each table block is a collapsible section.
Faces are applied to the row markers.

#### Faces

```elisp
(defface madolt-diff-added       ;; green — added rows (+)
(defface madolt-diff-removed     ;; red — removed rows (-)
(defface madolt-diff-old         ;; red — old value of modified row (<)
(defface madolt-diff-new         ;; green — new value of modified row (>)
(defface madolt-diff-context     ;; dim — unchanged context
(defface madolt-diff-table-heading   ;; bold — "diff --dolt a/T b/T"
(defface madolt-diff-column-header   ;; underlined — column name row
```

In structured mode, individual changed cells within a modified row
are highlighted more brightly (word-level refinement equivalent).

#### Transient menu

```elisp
(transient-define-prefix madolt-diff ()
  "Show diffs."
  ["Arguments"
   ("-s" "Statistics only"    "--stat")
   ("-S" "Summary only"      "--summary")
   ("-w" "Where clause"      "--where=")
   ("-k" "Skinny columns"    "--skinny")
   ("-r" "Raw tabular mode"  madolt-diff-raw-mode)]
  ["Diff"
   ("d" "Working tree"            madolt-diff-unstaged)
   ("s" "Staged"                  madolt-diff-staged)
   ("c" "Between commits"        madolt-diff-commits)
   ("t" "Single table"           madolt-diff-table)])
```

#### Diff functions

| Function               | Description                                      |
|------------------------|--------------------------------------------------|
| `madolt-diff-unstaged` | Diff working tree vs HEAD (unstaged changes)     |
| `madolt-diff-staged`   | Diff staged vs HEAD (`dolt diff --staged`)       |
| `madolt-diff-commits`  | Diff between two revisions (prompt for both)     |
| `madolt-diff-table`    | Diff a single table (prompt for table name)      |
| `madolt-diff-insert-table` | Insert diff for one table into current buffer (used by status buffer washer for inline expansion) |

---

### madolt-log.el (~250 LOC)

Commit log viewer.

#### Log buffer layout

```
Commits on main:
a4i9j85e  2026-03-07  Alice   Add users table with initial data
omthk7li  2026-03-06  Alice   Initialize data repository
```

Each commit is a section (type `commit`, value = hash string).

- `RET` on a commit: show full commit details + diff in a revision
  buffer (runs `dolt show HASH` and renders with `madolt-diff`).
- `TAB` on a commit: expand inline to show `--stat` output (which
  tables were changed and row/cell counts).

#### Transient menu

```elisp
(transient-define-prefix madolt-log ()
  "Show log."
  ["Arguments"
   ("-n" "Limit count" "-n" :class transient-option :reader transient-read-number-N+)
   ("-s" "Show stat"   "--stat")
   ("-m" "Merges only" "--merges")
   ("-g" "Graph"       "--graph")]
  ["Log"
   ("l" "Current branch" madolt-log-current)
   ("o" "Other branch"   madolt-log-other)
   ("h" "HEAD"           madolt-log-head)])
```

#### Log margin

Author name and date displayed in a right margin area, similar to
magit-log. Configurable via `madolt-log-margin`.

---

## Reuse Analysis Summary

### Reuse directly (unmodified dependencies)

| Component       | What it provides for madolt                      |
|-----------------|--------------------------------------------------|
| `magit-section` | Section insertion (`magit-insert-section`), navigation (`n`/`p`), expand/collapse (`TAB`), visibility levels (`1`-`4`), region selection, highlighting, `magit-section-mode` as parent mode. |
| `transient`     | All popup menus: `transient-define-prefix` for dispatch, diff, log, commit menus. Sticky arguments, discoverability. |
| `with-editor`   | Commit message editing. Sets `$EDITOR` to emacsclient, provides `C-c C-c` / `C-c C-k` finish/cancel. Works with `dolt commit` because dolt respects `core.editor` / `$EDITOR`. |
| `log-edit`      | Comment ring (`M-p`/`M-n` message history) for commit messages. Built into Emacs. |

### Adapt (use as architectural template)

| magit component    | madolt equivalent     | What changes                           |
|--------------------|-----------------------|----------------------------------------|
| `magit-git.el`     | `madolt-dolt.el`      | Same abstraction (executable + global args + output helpers), replace `git` with `dolt`. |
| `magit-mode.el`    | `madolt-mode.el`      | Same buffer lifecycle + refresh + position preservation, replace git context with dolt context. |
| `magit-process.el` | `madolt-process.el`   | Same process logging pattern with sections, simpler (sync only for MVP). |
| `magit-commit.el`  | `madolt-commit.el`    | Same transient structure, simpler (no fixup/squash/rebase — dolt lacks these). |
| `git-commit.el`    | Minor mode in `madolt-commit.el` | Summary length highlighting, style checks, message ring. Drop git-specific identity lookup, diff propertization. |
| `magit-status.el`  | `madolt-status.el`    | Same hook-driven section layout. Replace file sections with table sections. |
| `magit-log.el`     | `madolt-log.el`       | Same section-per-commit pattern. Dolt log format is nearly identical to git log. |

### Write from scratch

| Component       | Why                                              |
|-----------------|--------------------------------------------------|
| `madolt-diff.el`| Dolt diffs are tabular (row/cell level), not unified text diffs. Completely different parser. The section hierarchy (`table-diff` > `row-diff` vs `file` > `hunk`) is novel. |
| `madolt-apply.el` | Simpler than magit — dolt stages whole tables, no hunk/region granularity. Small file. |

### Not reusable

| magit component | Why                                              |
|-----------------|--------------------------------------------------|
| `magit-diff.el` (parser) | Parses `diff --git` unified format, `@@` hunks, `---`/`+++` headers. None of this applies to dolt's tabular diffs. |
| Fixup/squash/rebase commands | Dolt has no interactive rebase, no `--fixup=`, no `--squash=`. |
| `magit-commit-absorb`, `magit-commit-autofixup` | Require `git-absorb`/`git-autofixup`. Not applicable. |
| Submodule, worktree, notes | No dolt equivalent. |

---

## Key Design Decisions

### 1. Table-level staging (not hunk-level)

Dolt's `dolt add` operates on whole tables. There is no equivalent of
staging individual hunks or lines. The apply layer is therefore much
simpler than magit's. If Dolt adds row-level staging in the future,
this can be extended.

### 2. Two diff rendering modes

The structured mode (JSON-parsed) gives us reliable data for building
interactive sections with per-row collapse and cell-level
highlighting. The raw mode (native tabular output) is useful for
users who prefer dolt's own formatting. Both are supported, toggled
via transient argument.

### 3. CLI-only, no server

All operations via `dolt` CLI with `call-process`. No dependency on
`dolt sql-server` running. SQL queries use `dolt sql -q "..." -r json`.

### 4. Synchronous for MVP

Start with synchronous `call-process`. Dolt commands on local
databases are fast enough. Add async (sentinels + filters) in Phase 2
for network operations (push/pull/fetch/clone).

### 5. Commit message via with-editor

Dolt respects `core.editor` and `$EDITOR`. `with-editor` sets
`$EDITOR` to emacsclient, giving us the same edit-finish-cancel flow
as magit. No wrapper scripts or hacks needed.

---

## Phase 2 (Post-MVP)

| Feature             | Description                                   |
|---------------------|-----------------------------------------------|
| `madolt-branch.el`  | Branch transient: switch, create, delete, rename. |
| `madolt-merge.el`   | Merge + conflict resolution. Dolt has `dolt_conflicts` system tables and `dolt conflicts cat`/`resolve` commands. |
| `madolt-stash.el`   | Stash operations (list, pop, drop, apply).    |
| `madolt-remote.el`  | Remote management, push, pull, fetch, clone. Async process support needed here. |
| `madolt-sql.el`     | Interactive SQL query buffer with tabular result rendering. |
| `madolt-table.el`   | Table inspection: schema display, row count, blame (`dolt blame TABLE`). |
| `madolt-rebase.el`  | Rebase operations (dolt supports `dolt rebase`). |
| Async processes     | Non-blocking push/pull/fetch via sentinels.   |
| `sql.el` integration | `M-x madolt-sql-repl` opens a `sql-mysql` session connected to `dolt sql-server`. |
