# madolt demo — Clip 1: Overview & Diffs
#
# Shows the status buffer, dispatch menu, and inline diff expansion.

Output demo/clip1-overview.gif

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

# Launch Emacs (setup phase: base)
Hide
Type "DEMO_PHASE=base bash demo/launch.sh"
Enter
Wait+Screen@30s /Start one/
Type "y"
Wait+Screen@30s /Recent commits/
Show

# === Status buffer overview ===
# Database, Path, Head, Remote, Untracked, Unstaged, Recent commits
Sleep 3s

# === Dispatch menu ===
Type "?"
Sleep 4s
Ctrl+G
Sleep 1.5s

# === Inline diff expansion ===
# Navigate to employees under Unstaged (10 Downs)
Down 10
Sleep 500ms

# TAB: row-level diff (salary + title changes)
Tab
Sleep 3s

# Expand a row for per-field detail
Down 1
Sleep 500ms
Tab
Sleep 3s

# Collapse back
Tab
Sleep 500ms

# Final pause
Sleep 5s
