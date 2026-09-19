# Agent Guidelines

This file provides guidance when working with code in this repository.

## Project Overview

See this project's README.md for an overview of the project, and ADR documents in docs/adr/ for architectural decisions.

This is a vim plugin: vimscript in `plugin/` and `autoload/` calls into the
python package in `pythonx/diffundo/` (vim puts `pythonx/` on `sys.path`).
See docs/adr/0002-vim-plugin-layout.md before moving anything.

## Development Commands

**IMPORTANT**: Always use the Makefile commands for development tasks.

### Setup
```bash
make setup  # Set up venv and sync dependencies with uv
```

### Testing
```bash
make test                                              # Run all tests with pytest and coverage
uv run pytest tests/diffundo/test_interface.py         # Run specific test file
uv run pytest tests/diffundo/test_interface.py::test_earlier_accepts_a_count
uv run pytest -v                                       # Verbose output
```

Tests never launch vim. `tests/stubs/vim.py` makes `import vim` resolve at
collection time, and the `vim` fixture monkeypatches `interface.vim` with
`tests.fakevim.FakeVim` -- a fake of the windows, buffers, tab-local variables
and undo history the plugin actually uses. Add to the fake when the plugin
starts using a new part of the vim API.

### Code Quality
```bash
make lint   # Check code with ruff and ast-grep
make fix    # Auto-fix ruff issues and strip comments/docstrings
make type   # Type check with mypy (strict mode)
make radon  # Check cyclomatic complexity and maintainability
make ci     # Run all CI checks (test + lint + type + radon + vulture)
```

**Before completing any feature**, run `make ci` to ensure all checks pass.

## Code Quality Requirements

Writing guidance:

- Only include a brief description of the thing in docstrings (no arguments or return types)
- Do not use docstrings at the beginning of files.

New entry points called only from vimscript must be added to
`.vulture-whitelist.py`, or vulture will fail CI on them as dead code.

## Project Structure

```
autoload/            # vimscript entry points
plugin/              # :DiffEarlier / :DiffLater / :DiffSearch definitions
pythonx/diffundo/    # Main package source code
tests/               # Test files
docs/adr/            # Architecture Decision Records
```
