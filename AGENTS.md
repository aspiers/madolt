# Agent Instructions

Madolt is a magit-like Emacs interface for the Dolt version-controlled
database.  The **MVP is complete** -- all 9 source files and 9 test files
are implemented with 185 passing tests (~4,685 LOC total).

See [CONTRIBUTING.md](CONTRIBUTING.md) for project overview, build/test
instructions, interactive QA testing guide, and technical notes.

## Build & Test

```bash
make clean && make compile   # Always clean first to avoid stale .elc
make test                    # Run all 185 tests
make test-dolt               # Run a single module's tests
make lint                    # checkdoc
```

The Makefile assumes `straight.el` packages under `~/.emacs.d/straight/build/`.
Override with `STRAIGHT_DIR=/path/to/packages`.

## Interactive QA Testing via tmux

**Both automated AND interactive testing are required** when working on UI changes. Run unit tests first (`make test`), then verify interactively via tmux.

Use a **dedicated tmux session called `madolt-test`** for interactive testing. This session runs Emacs with madolt loaded in a controlled environment that can be inspected programmatically via `emacsclient`.

**CRITICAL RULES for tmux session management:**

- **NEVER kill existing tmux sessions or windows.** Take great care to preserve any running sessions.
- **Session name is always `madolt-test`** -- do not use other names, and do not reuse session names belonging to other tools.
- **Do NOT use `tmux kill-session`, `tmux kill-window`, or `tmux kill-pane`** unless you are absolutely certain the target is a stale `madolt-test` session with no running process.

### Setting up the test repo

Create a temporary dolt repo for interactive testing:

```bash
mkdir -p tmp/test-dolt
cd tmp/test-dolt
dolt init
dolt sql -q "CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(100))"
dolt sql -q "INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob')"
dolt add .
dolt commit -m "Initial commit"
dolt sql -q "INSERT INTO users VALUES (3, 'Charlie')"
dolt sql -q "CREATE TABLE orders (id INT PRIMARY KEY, user_id INT, amount DECIMAL(10,2))"
dolt sql -q "INSERT INTO orders VALUES (1, 1, 99.99)"
dolt add users
# Now: 'users' is staged, 'orders' is untracked
```

### Running Emacs in tmux

```bash
# Check if session already exists
tmux has-session -t madolt-test 2>/dev/null

# If no session exists, create one with Emacs running as a daemon-like server:
tmux new-session -d -s madolt-test -x 120 -y 40
tmux send-keys -t madolt-test 'emacs -nw --eval "(progn (server-start) (add-to-list (quote load-path) \"'$(pwd)'\") (require (quote madolt)) (madolt-status \"'$(pwd)'/tmp/test-dolt\"))"' Enter

# Force a specific terminal size
tmux resize-window -t madolt-test -x 120 -y 40
```

### Inspecting state with emacsclient

Once Emacs is running with `server-start`, use `emacsclient --eval` to inspect and interact programmatically:

```bash
# Evaluate arbitrary Elisp in the running Emacs
emacsclient --eval '(buffer-name)'
emacsclient --eval '(buffer-string)'

# Refresh madolt status
emacsclient --eval '(madolt-status-refresh)'

# Check what sections are visible
emacsclient --eval '(buffer-substring-no-properties (point-min) (point-max))'

# Navigate and interact
emacsclient --eval '(goto-char (point-min))'
emacsclient --eval '(magit-section-forward)'
emacsclient --eval '(madolt-stage)'

# Check current section at point
emacsclient --eval '(magit-current-section)'
```

### Sending keys via tmux

For testing keybindings rather than Elisp functions, send keys directly:

```bash
# Send a single key
tmux send-keys -t madolt-test 's'         # Stage
tmux send-keys -t madolt-test 'u'         # Unstage
tmux send-keys -t madolt-test 'g'         # Refresh
tmux send-keys -t madolt-test 'c'         # Commit transient
tmux send-keys -t madolt-test 'Tab'       # Toggle section
tmux send-keys -t madolt-test 'C-c'       # Ctrl+C

# Capture current screen content
tmux capture-pane -t madolt-test -p

# Wait briefly between actions for Emacs to update
sleep 0.3
```

### Important tmux notes

- **Window size**: tmux resizes to match the connecting client terminal, so `-x 120 -y 40` at creation doesn't persist. Use `tmux resize-window` to force a specific size.
- **Prefer emacsclient**: For inspecting buffer contents and evaluating Elisp, `emacsclient --eval` is far more reliable than capturing tmux pane output. Use tmux `send-keys` only when testing actual keybindings.
- **Graceful shutdown**: Send `C-x C-c` to quit Emacs, or use `emacsclient --eval '(kill-emacs)'`. Never kill sessions/windows/panes violently.
- **PTY sessions**: Alternatively, use `pty_spawn` to run Emacs in a managed PTY session for automated testing within the agent environment. But this is far less preferable because it cannot easily be observed by the user during testing, so ask permission before using this fallback.

### Typical QA workflow

1. Compile with `make clean && make compile`
2. Set up or verify the test repo state in `tmp/test-dolt/`
3. Launch Emacs in the `madolt-test` tmux session (or restart if already running)
4. Use `emacsclient --eval` to inspect buffer contents and verify behavior
5. Send keys via tmux to test keybindings
6. Check for correct section rendering, staging/unstaging, diffs
7. When done: `emacsclient --eval '(kill-emacs)'` (leave the tmux session intact for next time)

## Technical Notes

- **Dolt CLI only** -- no `dolt sql-server` dependency. All operations
  use `dolt sql -q ... -r json` or direct CLI commands.
- **Dolt v1.82.x does NOT support `$EDITOR`-based commit messages.**
  All commits use `-m` flag via minibuffer input.
- **Dolt stages whole tables**, not hunks. No partial staging.
- **`dolt commit --all`** only stages modified/deleted tables, NOT
  untracked. Use `--ALL` for that.
- **Stale .elc files cause insidious test failures** -- always
  `make clean` before `make compile`.
- **`magit-insert-section` with `(eval type)` needs DOUBLE parens:
  `((eval type))`**.
- **`define-derived-mode` replaces the keymap variable** -- bindings
  must be added AFTER the mode definition using `keymap-set`.

## Issue Tracking (bd/beads)

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd export -o .beads/issues.jsonl  # Export issues for git
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Version-controlled: Built on Dolt with cell-level merge
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update <id> --claim --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task atomically**: `bd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd export -o .beads/issues.jsonl
   git add .beads/issues.jsonl
   git commit -m "chore: export beads issues"
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

<!-- END BEADS INTEGRATION -->
