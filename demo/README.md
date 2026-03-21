# Demo Clips

Animated demos of madolt features, built with
[VHS](https://github.com/charmbracelet/vhs).

## Clips

| Clip | Description | Tape file |
|------|-------------|-----------|
| 1 | Overview & diffs | `clip1-overview.tape` |
| 2 | Branch, stage, commit, log & refs | `clip2-workflow.tape` |
| 3 | Stash & interactive rebase | `clip3-stash-rebase.tape` |
| 4 | Merge, conflicts, blame, SQL & server | `clip4-merge-database.tape` |

Each tape produces a `.gif` (used in the README) and optionally other
formats like `.webm` — just add extra `Output` lines to the tape file.

## Prerequisites

- [VHS](https://github.com/charmbracelet/vhs) (requires `ttyd` and `ffmpeg`)
- [Dolt](https://docs.dolthub.com/introduction/installation)
- Emacs 29+
- madolt's Emacs dependencies on your `load-path` (via
  [straight.el](https://github.com/radian-software/straight.el) by
  default; override with `STRAIGHT_DIR`)
- [SauceCodePro Nerd Font Mono](https://www.nerdfonts.com/) (for
  consistent rendering)

Install VHS and dependencies:

```sh
# macOS / Linux (Homebrew)
brew install vhs

# Or via Go
go install github.com/charmbracelet/vhs@latest
# + install ttyd and ffmpeg separately
```

## Generating clips

**Run from the repository root**, not the `demo/` directory — the tape
files use relative paths like `demo/launch.sh`.

```sh
# Generate a single clip
vhs demo/clip1-overview.tape

# Generate all clips
for tape in demo/clip*.tape; do vhs "$tape"; done
```

Each tape file specifies its own `Output` paths.  By default these are
GIF files in `demo/`.  To also produce `.webm` (or `.mp4`), add an
extra `Output` line to the tape:

```
Output demo/clip1-overview.gif
Output demo/clip1-overview.webm
```

## How it works

1. **`setup.sh`** creates a temporary Dolt repo at `tmp/madolt-demo-db`
   with a multi-commit history including branches, tags, staged/unstaged/
   untracked tables, and a diverged feature branch with conflicting changes.
   It supports four phases (`base`, `clip2`, `clip3`, `clip4`) so each
   clip starts from the right repo state.

2. **`launch.sh`** sets environment variables, runs `setup.sh` with the
   appropriate phase, clones the
   [catppuccin Emacs theme](https://github.com/catppuccin/emacs) if
   needed, and launches `emacs -Q -nw` with `init.el`.

3. **`init.el`** loads madolt and its dependencies, applies the
   catppuccin mocha theme, sets up explicit diff face colours for
   terminal mode, enables `keycast-mode-line-mode` (to show keystrokes
   in the mode line), and opens the madolt status buffer.

4. **The `.tape` file** scripts the interaction: typing commands,
   pressing keys, and adding pauses for readability.  VHS records the
   terminal and renders the output.

## Modifying a clip

- **Change repo data**: edit `setup.sh`
- **Change Emacs config**: edit `init.el`
- **Change recorded interaction**: edit the `.tape` file

After making changes, re-run `vhs demo/<clip>.tape` to regenerate.

## Rendering settings

All clips share these VHS settings (defined at the top of each tape):

| Setting | Value |
|---------|-------|
| Font | SauceCodePro Nerd Font Mono, size 20 |
| Resolution | 1600 x 900 |
| Framerate | 12 fps |
| Terminal theme | Dracula |
| Emacs theme | Catppuccin Mocha |
| Typing speed | 60ms |
| Window bar | Colorful |

## Phase progression

The demo repo state advances across clips:

```
base  →  clip2  →  clip3  →  clip4
(initial)  (committed)  (stashed)  (ready for merge)
```

Each clip's tape file sets `DEMO_PHASE` before calling `launch.sh`,
which passes it to `setup.sh`.
