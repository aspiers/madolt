# madolt demo — A magit-like Emacs interface for Dolt
#
# This VHS tape creates an animated GIF demonstrating madolt's features.
# Run with: vhs demo.tape
#
# Prerequisites:
#   - Emacs 29.1+ with magit-section, transient, keycast installed
#   - Dolt CLI
#
# Scenes:
#   1.  Status buffer overview
#   2.  Dispatch menu (?)
#   3.  Inline diff expansion (unstaged employees)
#   4.  Stage + commit (employees + tasks; departments stays dirty)
#   5.  Log with graph
#   6.  Stash demo (stash departments → list → pop → stash again)
#   7.  Interactive rebase (squash fix-typo, reorder)
#   8.  Pop stash, stash again for merge
#   9.  Merge feature/projects (conflict)
#   10. Conflict resolution (resolve theirs, continue merge)
#   11. Pop stash
#   12. Blame (employees table)
#   13. SQL query
#   14. SQL server (start, status, stop)
#   15. Refs buffer
#   16. Create new branch

Output demo.gif

Require emacs
Require dolt

Set Shell "bash"
Set FontSize 22
Set FontFamily "SauceCodePro Nerd Font Mono"
Set LetterSpacing 0
Set LineHeight 1.1
Set Width 1800
Set Height 1000
Set Padding 20
Set Framerate 15
Set Theme "Dracula"
Set TypingSpeed 60ms
Set WindowBar Colorful

# Launch Emacs via wrapper (sets up env, resets demo repo, loads madolt)
Hide
Type "bash demo/launch.sh"
Enter
# Accept the sql-server prompt (server runs throughout the demo)
Wait+Screen@30s /Start one/
Type "y"
# Wait for the status buffer to fully render
Wait+Screen@30s /Recent commits/
Show

# ================================================================
# Act 1: Orientation
# ================================================================

# === Scene 1: Status buffer overview ===
# Shows: Database, Path, Head (main), Remote (origin),
# Untracked (tasks), Unstaged (departments, employees), Recent commits
Sleep 3s

# === Scene 2: Dispatch menu ===
Type "?"
Sleep 4s
Ctrl+G
Sleep 1s

# ================================================================
# Act 2: Working with changes
# ================================================================

# === Scene 3: Inline diff expansion ===
# Navigate to employees under Unstaged changes.
# From top: 10 section-forwards past Path, Head, Remote, blank,
# Untracked heading, tasks, blank, Unstaged heading, departments,
# then employees.
Down 10
Sleep 500ms

# TAB: row-level diff (salary + title changes for Carol and Bob)
Tab
Sleep 3s

# Move to first changed row, expand for per-field detail
Down 1
Sleep 500ms
Tab
Sleep 3s

# Collapse back
Tab
Sleep 500ms

# === Scene 4: Stage + commit ===
# Navigate up to employees table heading
Up 1
Sleep 300ms
# Stage employees
Type "s"
Sleep 1.5s

# Point lands on departments. Go up 3 to tasks:
# departments → Unstaged heading → blank → tasks
Up 3
Sleep 300ms
# Stage tasks
Type "s"
Sleep 1.5s

# Now: departments unstaged, employees+tasks staged.
# Open commit transient — pause to show options
Type "c"
Sleep 2.5s

# Press 'c' to create commit (opens message buffer)
Type "c"
Sleep 1s

# Type a single-line commit message (keeps stash display clean)
Type "Add tasks table, promote Carol and raise Bob"
Sleep 700ms

# Finalize commit with C-c C-c
Ctrl+C
Ctrl+C
Sleep 2s

# ================================================================
# Act 3: History exploration
# ================================================================

# === Scene 5: Log ===
# Open log transient
Type "l"
Sleep 2s

# Current branch log
Type "l"
Sleep 3s

# Expand first commit
Down
Sleep 500ms
Tab
Sleep 2s

# Expand a table diff inside the commit
Down
Sleep 500ms
Tab
Sleep 3s

# Return to status
Type "q"
Sleep 1s

# ================================================================
# Act 4: Stash
# ================================================================

# === Scene 6: Stash demo ===
# departments is still unstaged after the commit — perfect for stash.

# Open stash transient — pause to show menu
Type "z"
Sleep 2s

# Stash the dirty departments changes
Type "z"
Sleep 2s

# List stashes (shown in minibuffer/echo area)
Type "z"
Sleep 1s
Type "l"
Sleep 2s

# Pop the stash to restore departments changes
Type "z"
Sleep 1s
Type "p"
# Pop prompts for stash number — accept default (0)
Sleep 500ms
Enter
Sleep 2s

# Stash again — we need clean state for interactive rebase
Type "z"
Sleep 1s
Type "z"
Sleep 1.5s

# ================================================================
# Act 5: Interactive rebase
# ================================================================

# === Scene 7: Interactive rebase to clean up history ===
Type "r"
Sleep 2s

# Start interactive rebase
Type "i"
Sleep 500ms

# Upstream prompt has completion — clear it and type our ref.
# Go back 5 commits to include the fix-typo commit.
Ctrl+A
Ctrl+K
Type "HEAD~5"
Enter
Sleep 3s

# Plan editor is now open showing 5 commits oldest-first:
#   pick Q2 budget adjustment for Engineering
#   pick Promote Alice Chen to Staff Engineer
#   pick Fix typo in Alice's email       ← squash this
#   pick Update Sales headcount
#   pick Add tasks table, promote Carol and raise Bob

# Navigate to the fix-typo commit (3rd line = 2 Downs)
Down 2
Sleep 500ms

# Change action to squash (merge into Promote Alice above)
Type "s"
Sleep 2s

# Move to next line (Update Sales headcount) and reorder it up
Down 1
Sleep 500ms
# M-p moves the line at point up one position
Alt+p
Sleep 2s

# Apply the rebase plan
Ctrl+C
Ctrl+C
Sleep 4s

# ================================================================
# Act 6: Merge with conflict resolution
# ================================================================

# === Scene 8: Pop stash, stash again for merge ===
# Pop stash to briefly recover departments changes
Type "z"
Sleep 1s
Type "p"
Sleep 500ms
Enter
Sleep 1.5s

# Stash again for clean merge
Type "z"
Sleep 1s
Type "z"
Sleep 1.5s

# === Scene 9: Merge feature/projects ===
# Open merge transient — pause to show options
Type "m"
Sleep 2s

# Press 'm' to merge
Type "m"
Sleep 500ms

# Prompted for branch — clear completion and type branch name
Ctrl+A
Ctrl+K
Type "feature/projects"
Enter
Sleep 4s

# Merge conflict! Process buffer shows the error.
# Return to status to see the conflict state.
Type "q"
Sleep 2s

# === Scene 10: Resolve the conflict ===
# Status shows "Merge conflicts (1): departments"
# Open conflicts transient
Type "C"
Sleep 2s

# View conflicts on departments
Type "c"
Sleep 500ms
Ctrl+A
Ctrl+K
Type "departments"
Enter
Sleep 3s

# Shows base/ours/theirs comparison for Engineering row.
# Return to status
Type "q"
Sleep 500ms

# Resolve using theirs (accept feature branch values)
Type "C"
Sleep 1.5s
Type "t"
Sleep 500ms
Ctrl+A
Ctrl+K
Type "departments"
Enter
Sleep 2s

# Continue merge: open merge transient (shows Continue/Abort)
Type "m"
Sleep 1.5s
Type "m"
Sleep 1s

# Merge commit message prompt — clear default and type our own
Ctrl+A
Ctrl+K
Type "Merge feature/projects into main"
Enter
Sleep 2s

# === Scene 11: Pop stash to recover departments changes ===
Type "z"
Sleep 1s
Type "p"
Sleep 500ms
Enter
Sleep 1.5s

# ================================================================
# Act 7: Database-native features
# ================================================================

# === Scene 12: Blame ===
Type "B"
Sleep 500ms
# Prompted for table — clear completion and type
Ctrl+A
Ctrl+K
Type "employees"
Enter
Sleep 4s

# Per-row blame annotations with commit hashes and authors
Type "q"
Sleep 1s

# === Scene 13: SQL query ===
Type "e"
Sleep 500ms
Type "SELECT name, salary FROM employees WHERE salary > 100000"
Enter
Sleep 4s

# Formatted table results
Type "q"
Sleep 1s

# === Scene 14: SQL server ===
# Server is already running from startup. Show the transient and status.
# Open SQL server transient — show the menu
Type "E"
Sleep 2s

# Show server status (server was started at startup)
Type "i"
Sleep 2s

# Stop the server
Type "E"
Sleep 1.5s
Type "k"
Sleep 2s

# Restart it to show the full lifecycle
Type "E"
Sleep 1.5s
Type "s"
Sleep 3s

# ================================================================
# Act 8: Branch management & refs
# ================================================================

# === Scene 15: Refs buffer ===
Type "y"
Sleep 3s

# Expand feature/projects branch to show cherry commits
Down
Sleep 500ms
Tab
Sleep 2s

# Return from refs
Type "q"
Sleep 1s

# === Scene 16: Create a new branch ===
# Open branch transient
Type "b"
Sleep 2s

# Create and checkout
Type "c"
Sleep 500ms

# Prompted for start point first — accept HEAD default
Enter
Sleep 500ms

# Now prompted for branch name
Type "feature/next-sprint"
Enter
Sleep 2s

# Status shows new branch in Head line
Sleep 3s
