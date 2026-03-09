EMACS ?= emacs

# straight.el package directories for dependencies
STRAIGHT_DIR ?= $(HOME)/.emacs.d/straight/build
DEPS_LOAD_PATH = \
  -L $(STRAIGHT_DIR)/magit-section \
  -L $(STRAIGHT_DIR)/magit \
  -L $(STRAIGHT_DIR)/transient \
  -L $(STRAIGHT_DIR)/with-editor \
  -L $(STRAIGHT_DIR)/compat \
  -L $(STRAIGHT_DIR)/dash \
  -L $(STRAIGHT_DIR)/llama \
  -L $(STRAIGHT_DIR)/seq \
  -L $(STRAIGHT_DIR)/cond-let

LOAD_PATH = -L . -L test $(DEPS_LOAD_PATH)

# Emacs Lisp source files (in dependency order)
SRCS = madolt-dolt.el madolt-process.el madolt-mode.el madolt.el \
       madolt-status.el madolt-apply.el madolt-commit.el \
       madolt-diff.el madolt-log.el madolt-branch.el \
       madolt-cherry-pick.el madolt-merge.el madolt-rebase.el \
       madolt-reflog.el madolt-sql.el madolt-remote.el \
       madolt-stash.el madolt-tag.el

# Test files
TEST_HELPERS = test/madolt-test-helpers.el
TEST_SRCS = $(wildcard test/madolt-*-tests.el) $(wildcard test/madolt-tests.el)

.PHONY: test compile clean lint

## Run all tests
test: compile
	$(EMACS) --batch $(LOAD_PATH) \
	  -l ert \
	  -l $(TEST_HELPERS) \
	  $(patsubst %,-l %,$(TEST_SRCS)) \
	  -f ert-run-tests-batch-and-exit

## Byte-compile existing source files (warnings as errors)
compile:
	@existing="$(wildcard $(SRCS))"; \
	if [ -n "$$existing" ]; then \
	  $(EMACS) --batch $(LOAD_PATH) \
	    --eval "(setq byte-compile-error-on-warn t)" \
	    -f batch-byte-compile $$existing; \
	fi

## Run tests for a single file: make test-dolt, test-process, etc.
test-%: compile
	$(EMACS) --batch $(LOAD_PATH) \
	  -l ert \
	  -l $(TEST_HELPERS) \
	  -l test/madolt-$*-tests.el \
	  -f ert-run-tests-batch-and-exit

## Check for common issues
lint:
	$(EMACS) --batch $(LOAD_PATH) \
	  --eval "(require 'checkdoc)" \
	  $(patsubst %,--eval "(checkdoc-file \"%\")",$(wildcard $(SRCS)))

## Clean compiled files
clean:
	rm -f *.elc test/*.elc
