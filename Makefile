SCRIPTS := $(wildcard bin/*) install.sh tests/run.sh

.PHONY: check test lint install uninstall

check: lint test

test:
	@tests/run.sh

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck is not installed (https://www.shellcheck.net)"; exit 1; }
	shellcheck $(SCRIPTS)

install:
	@./install.sh

uninstall:
	@./install.sh --uninstall
