# madolt demo - A magit-like Emacs interface for Dolt
#
# This VHS tape creates an animated GIF demonstrating madolt's core features.
# Run with: vhs demo.tape
#
# Prerequisites:
#   - Emacs 29.1+ with magit-section, transient installed
#   - Dolt CLI

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

# Launch Emacs directly via wrapper that sets up environment
Hide
Type "bash demo/launch.sh"
Enter
# Wait for the status buffer to fully render
Wait+Screen@30s /Recent commits/
Show

# === Scene 1: Status buffer overview ===
# Full status: Head, Untracked, Unstaged, Staged, Recent commits
Sleep 3s

# === Scene 2: Navigate to unstaged table and view inline diff ===
# Cursor starts on L1 (Head:). Navigate to departments entry (L7).
Down 6
Sleep 800ms

# Expand inline diff for departments (Tab on a table entry shows row changes)
Tab
Sleep 3s

# === Scene 3: Stage the unstaged table ===
# Cursor is on L7 (departments entry). Press 's' to stage it.
Type "s"
Sleep 3s

# Buffer refreshed: departments moved to Staged changes.
# Cursor returned to L1. Navigate to projects entry (L4).
# L1: Head:  L2: blank  L3: Untracked tables  L4: new table projects
Down 3
Sleep 500ms

# === Scene 4: Stage the untracked table ===
Type "s"
Sleep 3s

# === Scene 5: Commit all staged changes ===
# Press 'c' for commit transient menu
Type "c"
Sleep 1.5s

# Press 'c' to open the commit message buffer
Type "c"
Sleep 1.5s

# Type commit message (summary + body) in the dedicated buffer
Type "Add projects table, update department budgets"
Enter
Enter
Type "Stage the new projects table and department budget changes."
Sleep 1s

# Finalize the commit with C-c C-c
Ctrl+C
Ctrl+C
Sleep 3s

# === Scene 6: View the commit log ===
# Press 'l' for log transient
Type "l"
Sleep 1.5s

# Press 'l' for current branch log
Type "l"
Sleep 2.5s

# Log opens in bottom window with margin annotations (author, date).
# Cursor is on L1 (root section). Move to first commit.
Down
Sleep 500ms

# Expand commit to see list of changed tables
Tab
Sleep 1.5s

# Move down to first table entry (departments) and expand its diff
Down
Sleep 500ms
Tab
Sleep 3s

# Scroll down to see more diff content
Down 3
Sleep 800ms
Down 3
Sleep 2s

# === Scene 7: Return to status buffer ===
Type "q"
Sleep 2s

# Show the clean status (all changes committed)
Sleep 3s

# Exit Emacs
Ctrl+X
Ctrl+C
Sleep 1s
