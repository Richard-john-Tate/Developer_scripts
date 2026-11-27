# The scripts are bash or Python 3; tell them apart by their #! line.
SHELL_SCRIPTS  := $(shell grep -l '^.!/usr/bin/env bash' bin/* install.sh tests/*.sh)
PYTHON_SCRIPTS := $(shell grep -l '^.!/usr/bin/env python3' bin/*)

.PHONY: check test lint install uninstall

check: lint test

test:
	@tests/run.sh

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck is not installed (https://www.shellcheck.net)"; exit 1; }
	shellcheck $(SHELL_SCRIPTS)
	@# Syntax-check the Python scripts against the oldest Python we support.
	python3 -c 'import ast, sys; [ast.parse(open(f).read(), f, feature_version=(3, 8)) for f in sys.argv[1:]]' $(PYTHON_SCRIPTS)

install:
	@./install.sh

uninstall:
	@./install.sh --uninstall
