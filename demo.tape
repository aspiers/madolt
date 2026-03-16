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
# Head, Path, Remote, Untracked, Unstaged, Staged, Recent commits
Sleep 3s

# === Scene 2: Show the help/dispatch menu ===
Type "?"
Sleep 4s
# Dismiss the transient
Ctrl+G
Sleep 1s

# === Scene 3: Navigate to unstaged table and expand inline diff ===
Down 9
Sleep 500ms

# TAB expands to show row-level changes (level 3 summary)
Tab
Sleep 3s

# === Scene 4: Expand a row to see per-field detail (level 4) ===
Down 2
Sleep 500ms
Tab
Sleep 3s

# Collapse back
Tab
Sleep 500ms

# === Scene 5: Stage the unstaged table ===
# Navigate back up to the table heading
Up 2
Sleep 300ms
Type "s"
Sleep 2s

# Navigate to the untracked table and stage it too
Down 6
Sleep 500ms
Type "s"
Sleep 2s

# === Scene 6: Commit staged changes ===
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
# Press 'l' for log transient
Type "l"
Sleep 2.5s

# Press 'l' for current branch log
Type "l"
Sleep 2s

# Move to first commit and expand it
Down
Sleep 500ms
Tab
Sleep 1.5s

# Move down to a table entry and expand its diff
Down
Sleep 500ms
Tab
Sleep 3s

# Scroll down to see more diff content
Down 3
Sleep 500ms
Down 3
Sleep 1.5s

# === Scene 8: Return to status and view refs ===
Type "q"
Sleep 1s

# Press 'y' for refs buffer
Type "y"
Sleep 3s

# Expand the feature branch to show cherry commits
Down 2
Sleep 500ms
Tab
Sleep 2s

# Return from refs buffer
Type "q"
Sleep 1s

# === Scene 9: Create and checkout a new branch ===
# Press 'b' for branch transient
Type "b"
Sleep 2s

# Press 'c' to create and checkout
Type "c"
Sleep 500ms

# Type branch name
Type "feature/demo"
Enter
Sleep 500ms

# Accept default start point (HEAD)
Enter
Sleep 2s

# Show the clean status with new branch in Head line
Sleep 3s
