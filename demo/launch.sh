#!/bin/bash
# Wrapper script to set up demo environment and launch Emacs.
# Used by VHS tape to keep setup commands out of the recording.

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEMO_DIR/.." && pwd)"

export TERM=xterm-256color
export MADOLT_DIR="$REPO_DIR"
export DEMO_DB=/tmp/madolt-demo-db

# Reset demo repo to known state
bash "$DEMO_DIR/setup.sh" "$DEMO_DB" >/dev/null 2>&1

# Launch Emacs with madolt
exec emacs -Q -nw -l "$DEMO_DIR/init.el"
