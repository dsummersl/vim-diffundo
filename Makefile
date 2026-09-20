.PHONY: setup test lint type adr coverage vulture fix radon treepeat ci

PACKAGE = pythonx/diffundo

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

ci: test lint type radon vulture
