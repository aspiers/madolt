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
# Full status: Head, Path, Remote, Untracked, Unstaged, Staged, Recent commits
Sleep 2s

# === Scene 2: Show the help/dispatch menu ===
Type "?"
Sleep 4s
# Dismiss the transient (C-g, not q which would quit the buffer)
Ctrl+G
Sleep 1s

# === Scene 3: Navigate to unstaged table and view inline diff ===
Down 9
Sleep 500ms

# Expand inline diff for departments (Tab shows row-level changes)
Tab
Sleep 3s

# === Scene 4: Stage the unstaged table ===
Type "s"
Sleep 2s

# Buffer refreshed: departments moved to Staged changes.
# Navigate to projects entry under Untracked.
Down 6
Sleep 500ms

# === Scene 5: Stage the untracked table ===
Type "s"
Sleep 2s

# === Scene 6: Commit all staged changes ===
# Press 'c' for commit transient — linger to show options
Type "c"
Sleep 2.5s

# Press 'c' to create commit
Type "c"
Sleep 1s

# Type commit message
Type "Add projects table, update department budgets"
Enter
Enter
Type "Stage the new projects table and department budget changes."
Sleep 700ms

# Finalize the commit with C-c C-c
Ctrl+C
Ctrl+C
Sleep 2s

# === Scene 7: View the commit log ===
# Press 'l' for log transient — linger to show options
Type "l"
Sleep 3s

# Press 'l' for current branch log
Type "l"
Sleep 2s

# Move to first commit
Down
Sleep 500ms

# Expand commit to see list of changed tables
Tab
Sleep 1.5s

# Move down to first table entry and expand its diff
Down
Sleep 500ms
Tab
Sleep 3s

# Scroll down to see more diff content
Down 3
Sleep 500ms
Down 3
Sleep 1.5s

# === Scene 8: Return to status buffer ===
Type "q"
Sleep 1.5s

# Show the clean status (all changes committed)
Sleep 2s
