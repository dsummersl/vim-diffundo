# 2. Vim plugin layout

Date: 2026-09-19

## Status

Superseded by [3. Lua port](0003-lua-port.md)

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
- The package is kept importable on python 3.8+, because vim loads it with
  whatever python3 vim itself was built against, which is not the python the
  developer picked. `requires-python` (3.11) constrains the dev toolchain only,
  so the `plugin-import` CI job imports the package under 3.8 through 3.13 to
  keep the two apart. Annotations are deferred with
  `from __future__ import annotations`, and runtime-evaluated generics (the
  `UndoEntry` alias) use `typing.Dict` rather than PEP 585/604 syntax.
- `.vulture-whitelist.py` records the entry points called from vimscript
  (`earlier`, `later`, `search_earlier`, `open_split`); vulture cannot see
  vimscript callers and would otherwise report them as dead code.

## Consequences

The python side is fully covered by `make ci`. The vimscript side is covered by
one end-to-end happy path in `tests/e2e/`: `@denops/test` starts a headless
neovim with denops.vim loaded, puts this repository on the runtimepath and
drives `:DiffEarlier` over a scratch buffer with a real undo history, so the
command definitions, the `py3` bridge and `pythonx/` loading are exercised for
real. It runs as its own `e2e` CI job rather than from `make ci`, which stays a
pure python gate: the e2e test needs deno, neovim and pynvim installed.

It is neovim only, because denops needs Vim 9.1.1646 or newer and the Vim it
drives also needs `+python3`; running `mode: "all"` once such a Vim is available
in CI would cover the primary target too.
