# 2. Vim plugin layout

Date: 2026-09-19

## Status

Accepted

## Context

The template in ADR 1 expects the package to sit at the project root
(`package_name/`). This project is a vim plugin: vim puts `pythonx/` on
`sys.path` when the plugin is loaded, so the package must live at
`pythonx/diffundo/` and cannot be moved. The plugin also imports `vim`, a module
that only exists inside a vim process, so the package cannot be imported at all
outside of vim without help.

## Decision

Keep the vim-mandated directory layout and point the tooling at it instead:

```plaintext
project-root/
├── autoload/            # vimscript entry points
├── plugin/              # :Diff* command definitions
├── pythonx/diffundo/    # the package; vim adds pythonx/ to sys.path
├── tests/
│   ├── fakevim.py       # a fake of the slice of the vim API the plugin uses
│   └── stubs/vim.py     # importable placeholder so collection succeeds
└── docs/adr/
```

- `PACKAGE = pythonx/diffundo` in the Makefile drives ruff, ast-grep, radon and vulture.
- mypy uses `mypy_path = "pythonx"` with `packages = ["diffundo"]`.
- pytest sets `pythonpath = ["pythonx", "tests/stubs"]`, so tests import
  `diffundo` exactly as vim does, and `import vim` resolves to the stub.
- Tests then monkeypatch `interface.vim` with `tests.fakevim.FakeVim`, which
  models windows, buffers, tab-local variables and a linear undo history, so the
  interface can be driven end to end without a vim process.
- `.vulture-whitelist.py` records the entry points called from vimscript
  (`earlier`, `later`, `search_earlier`, `open_split`); vulture cannot see
  vimscript callers and would otherwise report them as dead code.

## Consequences

The python side is fully covered by `make ci`. The vimscript side is not tested
at all -- an end-to-end smoke test driving `vim --clean -es` over a scratch file
with a real undo history would close that gap.
