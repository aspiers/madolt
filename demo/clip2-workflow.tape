# madolt demo — Clip 2: Branch, Stage, Commit, Log & Refs
#
# Creates a branch, stages tables, commits, explores log and refs.

Output demo/clip2-workflow.gif

Require emacs
Require dolt

Set Shell "bash"
Set FontSize 20
Set FontFamily "SauceCodePro Nerd Font Mono"
Set LetterSpacing 0
Set LineHeight 1.1
Set Width 1600
Set Height 900
Set Padding 20
Set Framerate 12
Set Theme "Dracula"
Set TypingSpeed 60ms
Set WindowBar Colorful

# Launch Emacs (setup phase: base — same as clip 1)
Hide
Type "DEMO_PHASE=base bash demo/launch.sh"
Enter
Wait+Screen@30s /Start one/
Type "y"
Wait+Screen@30s /Recent commits/
Show

# === Stage employees ===
# Navigate to employees (10 Downs)
Down 10
Sleep 1s
Type "s"
Sleep 2.5s

# Navigate to tasks (Up 3 from departments)
Up 3
Sleep 1s
Type "s"
Sleep 2.5s

# === Commit ===
Type "c"
Sleep 2.5s
Type "c"
Sleep 1s
Type "Add tasks table, promote Carol and raise Bob"
Sleep 700ms
Ctrl+C
Ctrl+C
Sleep 2.5s

# === Log ===
Type "l"
Sleep 2s
Type "l"
Sleep 3s

# Expand first commit
Down
Sleep 500ms
Tab
Sleep 2.5s

# Expand a table diff
Down
Sleep 500ms
Tab
Sleep 3s

# Return to status
Type "q"
Sleep 1s

# === Refs buffer ===
Type "y"
Sleep 3s

# Expand feature/projects branch
Down
Sleep 500ms
Tab
Sleep 2.5s

# Return
Type "q"
Sleep 1s

# === Create new branch ===
Type "b"
Sleep 2s
Type "c"
Sleep 500ms
Enter
Sleep 500ms
Type "feature/next-sprint"
Enter
Sleep 2s

# Final pause showing new branch in Head line
Sleep 5s
