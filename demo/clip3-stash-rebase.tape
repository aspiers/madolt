# madolt demo — Clip 3: Stash & Interactive Rebase
#
# Demonstrates stash workflow and interactive rebase with squash/reorder.

Output demo/clip3-stash-rebase.gif

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

# Launch Emacs (setup phase: clip2 — employees+tasks committed,
# departments still unstaged)
Hide
Type "DEMO_PHASE=clip2 bash demo/launch.sh"
Enter
Wait+Screen@30s /Start one/
Type "y"
Wait+Screen@30s /Recent commits/
Show

# === Stash demo ===
# departments is still unstaged — perfect for stash

# Open stash transient
Type "z"
Sleep 2s

# Stash the dirty departments changes
Type "z"
Sleep 2.5s

# List stashes
Type "z"
Sleep 1s
Type "l"
Sleep 2s

# Pop the stash
Type "z"
Sleep 1s
Type "p"
Sleep 500ms
Enter
Sleep 2.5s

# Stash again for clean rebase
Type "z"
Sleep 1s
Type "z"
Sleep 1.5s

# === Interactive rebase ===
Type "r"
Sleep 2s

# Start interactive rebase
Type "i"
Sleep 500ms
Ctrl+A
Ctrl+K
Type "HEAD~5"
Enter
Sleep 3s

# Navigate to fix-typo commit (2 Downs)
Down 2
Sleep 500ms

# Squash
Type "s"
Sleep 2.5s

# Move next line up
Down 1
Sleep 500ms
Alt+p
Sleep 2.5s

# Apply
Ctrl+C
Ctrl+C
Sleep 4s

# Final pause showing cleaned history
Sleep 5s
