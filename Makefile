.PHONY: setup test lint type adr coverage vulture fix radon treepeat ci e2e

PACKAGE = pythonx/diffundo

# The denops.vim checkout @denops/test drives the editor with; see tests/e2e/README.md.
DENOPS_VERSION = v8.0.2
DENOPS_PATH = $(CURDIR)/.cache/denops.vim

setup:
	uv venv
	uv sync --python .venv/bin/python

test:
	uv run pytest

lint:
	uv run ruff check .
	uv run ast-grep scan $(PACKAGE) tests

vulture:
	uv run vulture --min-confidence 55 $(PACKAGE) .vulture-whitelist.py

fix:
	uv run ast-grep scan --update-all $(PACKAGE) tests
	uv run ruff check . --fix
	uv run ruff format .

type:
	uv run mypy

radon:
	uv run .github/scripts/check_radon.sh

treepeat:
	uv run treepeat detect .

$(DENOPS_PATH):
	git clone --depth 1 --branch $(DENOPS_VERSION) https://github.com/vim-denops/denops.vim $(DENOPS_PATH)

e2e: $(DENOPS_PATH)
	cd tests/e2e && DENOPS_TEST_DENOPS_PATH=$(DENOPS_PATH) deno test -A

ci: test lint type radon vulture
