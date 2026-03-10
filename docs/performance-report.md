# Madolt Performance Report

## Executive Summary

A typical status buffer refresh takes **~2.6-2.9 seconds**. The
dominant cost is **dolt CLI process startup overhead**: each `dolt`
invocation takes ~170-250ms regardless of the actual work performed
(`dolt version` alone takes ~170ms). A full refresh makes 8 sequential
CLI calls, spending ~1.7s just starting processes.

The most impactful optimization would be **parallelizing CLI calls**,
which reduces the 8-call wall time from ~1.7s to ~0.4s (4x speedup
demonstrated). Beyond that, a persistent `dolt sql-server` connection
would eliminate process startup entirely for SQL-based queries.

## Profiling Data

### Status Buffer Refresh Breakdown

Measured on the test-dolt repo (3 tables, 9 commits, 1 remote):

| Section inserter               | Time (s) | % total | CLI calls |
|:-------------------------------|:---------|:--------|:----------|
| `madolt-insert-status-header`  | 0.90     | 33%     | 4 (branch, log, remote, branch -a) |
| `madolt-insert-staged-changes` | 0.46-0.52| 18%     | 0 (cached status) |
| `madolt-insert-unstaged-changes`| 0.34-0.46| 15%     | 0 (cached status) |
| `madolt-insert-unpushed-commits`| 0.23-0.30| 11%     | 1 (log range) |
| `madolt-insert-unpulled-commits`| 0.21-0.23| 8%      | 1 (log range) |
| `madolt-insert-merge-conflicts`| 0.20-0.23| 8%      | 1 (status, first caller) |
| `madolt-insert-stashes`        | 0.20-0.21| 7%      | 1 (stash list) |
| `madolt-insert-untracked-tables`| 0.006   | <1%     | 0 (cached status) |
| `madolt-insert-recent-commits` | 0.000006 | ~0%     | 0 (cached log) |
| **Total**                      | **~2.7** | **100%**| **8**     |

Cache hit rate: 3/11 (27%).

### Individual CLI Command Times

| Command                               | Time (ms) |
|:--------------------------------------|:----------|
| `dolt branch --show-current`          | 192-222   |
| `dolt log -n 10`                      | 224-227   |
| `dolt remote -v`                      | 162-183   |
| `dolt branch -a`                      | 171-203   |
| `dolt status`                         | 166-211   |
| `dolt stash list`                     | 123-145   |
| `dolt log -n 100 origin/main..HEAD`   | 208-245   |
| `dolt log -n 100 HEAD..origin/main`   | 176-207   |
| `dolt version` (bare startup)         | 166-185   |
| `dolt sql -q "SELECT 1" -r json`     | 176-199   |

**Process startup accounts for ~170ms of every call.** The actual work
(query execution, parsing) adds only 0-50ms on top.

### Commit Expansion (Tab on Log Entry)

Expanding a commit in the log view takes **~0.77s** with 4 CLI calls:

| Call                                           | Time (ms) |
|:-----------------------------------------------|:----------|
| `dolt log --oneline --parents -n 1 <hash>`    | 208       |
| `dolt diff -r json <parent> <hash>`           | 219       |
| `dolt sql -q "... key_column_usage ..." -r json` (1st) | 191 |
| `dolt sql -q "... key_column_usage ..." -r json` (2nd) | 149 |

Note: the primary key query runs twice for the same table because it's
called per-row in `madolt-diff--modified-summary` and the refresh-cache
is not active during Tab-expand (only during `madolt-refresh`).

### Parallel vs Sequential CLI Calls

```
8 commands sequential:  1.69s  (141% CPU)
8 commands parallel:    0.42s  (445% CPU)
```

**4x wall-time improvement** from parallelization.

## Root Causes

### 1. Dolt CLI process startup overhead (~170ms per call)

Dolt is a Go binary. Each invocation pays for Go runtime startup,
database file opening, and noms chunk store initialization. This is
inherent to the CLI architecture and cannot be reduced without
architectural changes.

### 2. Sequential CLI execution (8 calls × ~200ms = ~1.6s)

All 8 CLI calls during a refresh run sequentially via
`call-process`. Since most calls are independent (status, branch,
log, remote, stash), they could run in parallel.

### 3. No caching outside refresh cycle

The `madolt--refresh-cache` is only active during `madolt-refresh`.
Operations outside this scope (Tab-expand in log view, commit message
buffer) make uncached CLI calls. This leads to duplicate queries like
the primary key lookup being called twice for the same table.

### 4. Staged/unstaged changes sections are slow despite 0 CLI calls

`madolt-insert-staged-changes` and `madolt-insert-unstaged-changes`
take 0.3-0.5s each despite making no CLI calls (they use cached
`dolt status` output). This suggests the Elisp processing (section
construction, text property application, diff expansion state) has
significant overhead. Worth profiling with `elp` to identify hot
spots.

## Recommendations

### High Impact (P0)

#### 1. Parallelize independent CLI calls

**Expected improvement: ~1.2s off refresh (from ~2.7s to ~1.5s)**

Use `make-process` (async) instead of `call-process` (sync) for
independent CLI calls. The 8 status refresh calls break into 3
dependency groups:

- **Group 1** (independent, can all run in parallel):
  - `dolt branch --show-current`
  - `dolt remote -v`
  - `dolt branch -a`
  - `dolt status`
  - `dolt stash list`

- **Group 2** (depends on branch + remote from Group 1):
  - `dolt log -n 10`
  - `dolt log -n 100 <remote>/<branch>..HEAD`
  - `dolt log -n 100 HEAD..<remote>/<branch>`

- **Group 3** (depends on log from Group 2):
  - Recent commits (uses cached log entries)

Implementation: batch Group 1 as 5 parallel async processes, then
batch Group 2 as 3 parallel async processes once Group 1 completes.

Actually, all 8 calls could run fully in parallel since the log range
args (`origin/main..HEAD`) can be constructed from the remote name
(which is known without querying `dolt remote`). The upstream ref
resolution (`madolt-upstream-ref`) currently queries branch +
remote + branch -a sequentially, but the remote and branch names are
often already known from config.

**Complexity:** Medium. Requires refactoring `madolt--run` to support
async mode and adding a barrier/callback mechanism for section
inserters to wait on their data.

#### 2. Persistent `dolt sql-server` connection

**Expected improvement: ~170ms per SQL query → ~1-5ms**

Start a `dolt sql-server` process at first use and connect via MySQL
protocol (Emacs has `sql-mysql` and `mysql` process support, or use
a simple TCP socket). This eliminates process startup for all
SQL-based operations:

- `dolt sql -q "SELECT ..." -r json` → direct MySQL query
- `dolt diff -r json` → `SELECT * FROM dolt_diff_<table>` system table
- `dolt log` → `SELECT * FROM dolt_log` system table
- `dolt status` → `SELECT * FROM dolt_status` system table
- `dolt branch` → `SELECT * FROM dolt_branches` system table

Most dolt CLI commands have equivalent SQL queries via Dolt's system
tables. This would reduce per-query time from ~200ms to ~1-5ms.

**Complexity:** High. Requires managing a background server process,
connection lifecycle, error recovery, and rewriting all query functions
to use SQL instead of CLI commands. But the payoff is enormous —
refresh could drop to under 100ms.

### Medium Impact (P1)

#### 3. Activate refresh-cache for Tab-expand operations

**Expected improvement: eliminate duplicate PK queries (~150ms per table)**

Bind `madolt--refresh-cache` around `magit-section-toggle` or the
washer function so that repeated queries for the same table (e.g.,
primary key lookups) are cached within a single Tab-expand.

```elisp
(let ((madolt--refresh-cache (list (cons 0 0))))
  (magit-section-toggle section))
```

**Complexity:** Low. One-line change.

#### 4. Batch dolt queries where possible

Some section inserters make multiple independent CLI calls that could
be combined:

- `madolt-insert-status-header` calls `dolt branch --show-current`,
  `dolt remote -v`, and `dolt branch -a` separately. These could be
  replaced by a single `dolt sql -q "SELECT ..."` that queries
  `dolt_branches` and `dolt_remotes` system tables.

- The parent hash lookup (`dolt log --oneline --parents -n 1`) could
  be included in the initial log query by always requesting the parent
  hash field.

**Complexity:** Medium.

#### 5. Profile and optimize Elisp overhead

The staged/unstaged sections take 0.3-0.5s with no CLI calls. Use
`elp-instrument-package` on `madolt-diff` to find hot spots in the
diff rendering code:

```elisp
(elp-instrument-package "madolt-diff")
(madolt-refresh)
(elp-results)
```

Likely candidates: string formatting, text property application,
alist lookups in diff data.

**Complexity:** Low to investigate, varies to fix.

### Low Impact (P2)

#### 6. Incremental refresh

Instead of erase-and-rebuild, detect which sections need updating
and refresh only those. For example, after `dolt add`, only the
staged/unstaged sections change — the header, stashes, and commits
are unaffected.

**Complexity:** Very high. Requires section-level diffing.

#### 7. Lazy section loading

Only insert section bodies when they scroll into view, not when
they're part of the visible buffer. This is partially implemented
(diffs are lazy via Tab), but section headings and their entry
lists are always computed eagerly.

**Complexity:** High.

## Quick Wins (Can implement today)

1. **Wrap Tab-expand in refresh-cache** — eliminates duplicate PK
   queries, saves ~150ms per table expand. One-line change.

2. **Cache log entries including parent hashes** — avoid the separate
   `dolt log --parents` call during commit expand. Save ~200ms per
   commit expand.

3. **Use `dolt status --json`** (if available in v1.82+) instead of
   parsing text output — may be faster to parse.

## Measurement Methodology

- All timings measured on the `tmp/test-dolt` repo (3 tables,
  9 commits, 1 remote with unpushed commits)
- Refresh timing via `madolt-refresh-verbose` (per-section breakdown)
- CLI timing via bash `time` (3 runs per command)
- Parallel timing via bash background processes with `wait`
- Commit expand timing via Emacs `current-time` with `madolt--run` advice
- System: Linux, dolt v1.82.3
