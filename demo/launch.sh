#!/bin/bash
# Wrapper script to set up demo environment and launch Emacs.
# Used by VHS tape to keep setup commands out of the recording.

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEMO_DIR/.." && pwd)"

export TERM=xterm-256color
export MADOLT_DIR="$REPO_DIR"
export DEMO_DB="$REPO_DIR/tmp/madolt-demo-db"
export CATPPUCCIN_DIR="$REPO_DIR/tmp/catppuccin-emacs"

# Reset demo repo to known state
# DEMO_PHASE can be: base (default), clip2, clip3, clip4
bash "$DEMO_DIR/setup.sh" "$DEMO_DB" "${DEMO_PHASE:-base}" >/dev/null 2>&1

# Clone catppuccin theme if not already present
if [ ! -d "$CATPPUCCIN_DIR" ]; then
    git clone --depth 1 https://github.com/catppuccin/emacs.git \
        "$CATPPUCCIN_DIR" >/dev/null 2>&1
fi

# Launch Emacs with madolt
exec emacs -Q -nw -l "$DEMO_DIR/init.el"
