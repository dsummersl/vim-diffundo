# 3. Lua port

Date: 2026-09-21

## Status

Accepted

Supersedes [1. Python project](0001-python-project.md)

Supersedes [2. Vim plugin layout](0002-vim-plugin-layout.md)

## Context

The plugin was vimscript calling into a python package under `pythonx/`, which
tied it to a `+python3` build and whichever python that build linked against
(ADR 2 kept the package importable on python 3.8 through 3.13 for that reason).
It also meant two languages, two toolchains, and a separate deno-driven
end-to-end suite just to exercise the vimscript half.

The project should conform to
[cookiecutter-adr-lua](https://github.com/dsummersl/cookiecutter-adr-lua), the
Lua sibling of the python template ADR 1 adopted.

## Decision

Rewrite the plugin in Lua against the neovim API and drop classic Vim support.
Neovim 0.10 or newer is required (`vim.keycode`).

Adopt the layout and tooling from cookiecutter-adr-lua:

- Use [LuaRocks](https://luarocks.org/) as the package manager, installing into a project-local `lua_modules/` tree (`luarocks --tree lua_modules`). Dependencies are declared in the rockspec.
- Use [busted](https://lunarmodules.github.io/busted/) as the test framework, with [LuaCov](https://lunarmodules.github.io/luacov/) for coverage.
- Use [adr-tools](https://github.com/npryce/adr-tools) to document architectural decisions.
- Use [ast-grep](https://ast-grep.github.io/) rules (in `.ast-grep/rules/`) to disallow comments and misplaced `require` calls.

```plaintext
project-root/
├── plugin/diffundo.lua   # :Diff* commands and the <Plug>(DiffundoRepeat) map
├── lua/diffundo/         # the package
├── spec/                 # busted specs, mirroring lua/diffundo/
│   └── fakevim.lua       # a fake of the slice of the vim global the plugin uses
├── types/                # ---@meta stubs: busted globals and the vim API used
├── tests/e2e/            # deno + denops.vim end-to-end test (make e2e)
└── docs/adr/
```

Departures from the template, all because this is a neovim plugin rather than
a library:

- `plugin/` is linted, formatted and complexity-checked alongside `lua/` and
  `spec/` (`SRC` in the Makefile and `check_complexity.sh`).
- The plugin reads the `vim` global at call time. `vim.yml` declares it as a
  selene std so `global_usage` stays on, and `types/vim.lua` is a `---@meta`
  stub of only the API the plugin uses, so `make type` runs without a neovim
  runtime on the host. Extend both when the plugin touches a new API.
- Tests never launch neovim, as before: `spec/fakevim.lua` models windows,
  buffers, `vim.t`, `vim.bo`/`vim.wo`, `vim.cmd` and a linear undo history,
  and each spec installs it as the `vim` global. The install is the one
  `-- selene: allow(global_usage)` in the codebase.
- `:DiffSearch` finds added lines by multiset difference of the before/after
  buffers rather than python's `difflib.ndiff`, which has no Lua equivalent;
  for "which undo step added this line" the two agree.

### Working with coding agents (and humans)

Much of the code in this project is configured to make working with LLM coding agents easier (and humans too!).
Agents often produce common problems (stray comments, dead code, near-duplicate code, requires buried inside functions, sprawling functions), so tooling is chosen to catch them at CI time:

- **No comments** ([ast-grep](https://ast-grep.github.io/) rules in `.ast-grep/rules/`).
  Code is expected to be self-documenting. `make lint` flags them and `make fix` strips them. Motivated by
  [Inside Out: Uncovering How Comment Internalization Steers LLMs for Better or Worse](https://arxiv.org/pdf/2512.16790),
  which shows LLMs lean heavily on comments and that this steers their output in
  unpredictable, model- and task-dependent ways. A small allowlist for exceptional cases:
  `---@` type annotations, `-- selene:`, `-- stylua:`, `-- luacov:`, and `-- WHY:` prefixed comments.
  Plain `---` doc comments are Lua's docstrings and are banned; only the `---@param`/`---@return` lines are kept.
- **Dead code is rejected immediately** ([selene](https://kampfkarren.github.io/selene/) `unused_variable`/`unreachable_code` and lua-language-server `unused-*` diagnostics, both at error level).
  Limitation: neither tool sees across files, so an exported `M.fn` that nothing calls is not caught (python's vulture has no Lua analog).
- **Keep `require` at the top of the file** (ast-grep rule `no-require-in-function-lua`).
- **Size and complexity limits** (`.github/scripts/check_complexity.sh`, built on ast-grep + jq).
  Cyclomatic complexity per function must stay at or below 5 and functions must be under 80 lines.
- **Strict typing** ([lua-language-server](https://luals.github.io/) `--check` with the `strict` and `type-check` diagnostic groups at error level, configured in `.luarc.json`).
- **Formatting** ([StyLua](https://github.com/JohnnyMorganz/StyLua)). `make lint` checks, `make fix` applies.

## Consequences

- Classic Vim is no longer supported; users on Vim stay on the last python
  release.
- One language, one `make ci` gate. The python toolchain, the `pythonx/`
  layout and the `plugin-import` python matrix are gone.
- The deno end-to-end suite from ADR 2 stays, now needing only `deno` and
  `nvim` (no pynvim). It still runs as its own `e2e` CI job rather than from
  `make ci`, and it is what catches behaviour the fake cannot model: the port
  found `vim.notify` at error level throwing out of a user command, and `.`
  going stale after one repeat, only there.
- Five host binaries are needed beyond Lua itself (`stylua`, `selene`,
  `ast-grep`, `lua-language-server`, `jq`); CI installs them via `cargo
  binstall` and a GitHub release download.
