# madolt demo — Clip 4: Merge, Conflicts & Database Features
#
# Merges a feature branch with conflict resolution, then shows
# blame, SQL query, and SQL server management.

Output demo/clip4-merge-database.gif

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

# Launch Emacs (setup phase: clip4 — committed, departments stashed,
# clean state ready for merge)
# Decline sql-server at startup since dolt merge requires no running server.
# The server is started explicitly in the SQL server scene at the end.
Hide
Type "DEMO_PHASE=clip4 bash demo/launch.sh"
Enter
Wait+Screen@30s /Start one/
Type "n"
Wait+Screen@30s /Recent commits/
Show

# === Merge feature/projects ===
Type "m"
Sleep 2s
Type "m"
Sleep 1s
Type "feature/projects"
Enter
Sleep 4s

# Merge conflict — return to status
Type "q"
Sleep 2s

# === Resolve conflict ===
Type "C"
Sleep 2s

# View conflicts
Type "c"
Sleep 500ms
Ctrl+A
Ctrl+K
Type "departments"
Enter
Sleep 3.5s

# Return
Type "q"
Sleep 1s

# Resolve theirs
Type "C"
Sleep 1.5s
Type "t"
Sleep 500ms
Ctrl+A
Ctrl+K
Type "departments"
Enter
Sleep 2.5s

# Continue merge
Type "m"
Sleep 1.5s
Type "m"
Sleep 1s
Ctrl+A
Ctrl+K
Type "Merge feature/projects into main"
Enter
Sleep 2.5s

# Pop stash to recover departments changes
Type "z"
Sleep 1s
Type "p"
Sleep 500ms
Enter
Sleep 1.5s

# === Blame ===
Type "B"
Sleep 500ms
Ctrl+A
Ctrl+K
Type "employees"
Enter
Sleep 4s
Type "q"
Sleep 1s

# === SQL query ===
Type "e"
Sleep 500ms
Type "SELECT name, salary FROM employees WHERE salary > 100000"
Enter
Sleep 4s
Type "q"
Sleep 1s

# === SQL server ===
# Server not running (declined at startup so merge could proceed).
# Show transient, start, check status, stop.
Type "E"
Sleep 2s

# Start
Type "s"
Sleep 3.5s

# Show status
Type "E"
Sleep 1.5s
Type "i"
Sleep 2s

# Stop
Type "E"
Sleep 1.5s
Type "k"
Sleep 2s

# Final pause
Sleep 5s
