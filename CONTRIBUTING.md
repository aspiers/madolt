# Contributing to Madolt

## Building

```sh
make compile    # Byte-compile all source files
make test       # Run all 185 tests
make test-dolt  # Run tests for a single module (dolt, process, mode, etc.)
make lint       # Run checkdoc
make clean      # Remove .elc files
```

## Running tests

The test suite requires the Emacs dependencies on your `load-path`.
The Makefile assumes [straight.el](https://github.com/radian-software/straight.el)
and looks for packages under `~/.emacs.d/straight/build/`.  Override
with:

```sh
make test STRAIGHT_DIR=/path/to/your/packages
```

## Known limitations

- Dolt (as of v1.82.x) does not support `$EDITOR`-based commit
  message editing.  Madolt uses minibuffer input with message history
  instead.
- Dolt stages whole tables, not individual rows or cells.  There is no
  hunk-staging equivalent.
- No `dolt sql-server` dependency -- all CLI operations use
  `dolt sql -q ... -r json`.
