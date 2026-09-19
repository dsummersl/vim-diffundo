# 1. Python project

Date: 2026-09-19

## Status

Accepted

## Context

The python half of this vim plugin (the `diffundo` package) had no tooling: a
poetry `pyproject.toml` that was never used for anything, and a test suite that
could not even be collected.

## Decision

Adopt the standard layout from
[cookiecutter-adr-python](https://github.com/dsummersl/cookiecutter-adr-python):

- Use [uv](https://docs.astral.sh/uv/) as the package manager.
- Use [pytest](https://docs.pytest.org/en/stable/) as the test framework (with coverage).
- Use [adr-tools](https://github.com/npryce/adr-tools) to document architectural decisions.
- Use [ast-grep](https://ast-grep.github.io/) rules (in `.ast-grep/rules/`) to disallow comments and docstrings.

### Working with coding agents (and humans)

Much of the code in this project is configured to make working with LLM coding agents easier (and humans too!).
Agents often produce a common problems (stray comments, dead code, near-duplicate code, imports buried inside functions, sprawling functions), so tooling is chosen to catch at CI time:

- **No comments or docstrings** ([ast-grep](https://ast-grep.github.io/) rules in `.ast-grep/rules/`).
  Code is expected to be self-documenting. `make lint` flags them and `make fix` strips them. Motivated by
  [Inside Out: Uncovering How Comment Internalization Steers LLMs for Better or Worse](https://arxiv.org/pdf/2512.16790),
  which shows LLMs lean heavily on comments and that this steers their output in
  unpredictable, model- and task-dependent ways. A small allowlist for exceptional cases:
  `# noqa`, `# type: ignore`, `# pragma`, and `# WHY:` prefixed comments.
- **Dead code is rejected immediately** ([vulture](https://github.com/jendrikseipp/vulture)). Unused code is not allowed by default.
- **Duplicate code is surfaced** ([treepeat](https://github.com/dsummersl/treepeat)), advisory via `make treepeat`.
- **Keep imports at the top of the file** (ruff `B`, `PLR`, `PLC`, `TID` rule sets).
- **Size and complexity limits** ([radon](https://radon.readthedocs.io/) via `.github/scripts/check_radon.sh`).
- **Strict typing** (mypy `strict = true`).

## Consequences

`make ci` is the single gate for the python half of the plugin. The existing
docstrings and comments were stripped to satisfy the ast-grep rules, and
`VimInterface` gained full type annotations for mypy strict mode.

The vimscript half (`plugin/`, `autoload/`) is not covered by any of this
tooling; see ADR 2 for how the layout departs from the template.
