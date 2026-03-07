EMACS ?= emacs
LOAD_PATH = -L . -L test

# Emacs Lisp source files (in dependency order)
SRCS = madolt-dolt.el madolt-process.el madolt-mode.el madolt.el \
       madolt-status.el madolt-apply.el madolt-commit.el \
       madolt-diff.el madolt-log.el

# Test files
TEST_HELPERS = test/madolt-test-helpers.el
TEST_SRCS = $(wildcard test/madolt-*-tests.el) $(wildcard test/madolt-tests.el)

.PHONY: test compile clean lint test-dolt

## Run all tests
test: compile
	$(EMACS) --batch $(LOAD_PATH) \
	  -l ert \
	  -l $(TEST_HELPERS) \
	  $(patsubst %,-l %,$(TEST_SRCS)) \
	  -f ert-run-tests-batch-and-exit

## Byte-compile all source files (warnings as errors)
compile:
	$(EMACS) --batch $(LOAD_PATH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  $(patsubst %,-f batch-byte-compile %,$(wildcard $(SRCS)))

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
