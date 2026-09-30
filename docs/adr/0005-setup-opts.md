# 5. setup(opts) instead of vim.g.* configuration

Date: 2026-09-29

## Status

Accepted

## Context

Configuration was spread over five `vim.g.diffundo_*` variables, each read
at call time in a different module: `glyphs.lua` merged
`g:diffundo_glyphs`, `label.lua` picked `g:diffundo_date_format`,
`pane.lua` read `g:diffundo_history`, `g:diffundo_history_width` and
`g:diffundo_fold_min`. The pane's keymaps were hardcoded inside
`pane.map_keys`, so users could not rebind them, and any new option or
keymap meant another global plus another read site. The globals gave no
place for types or defaults to live, and exercising configuration in the
busted specs meant writing into the fake's `vim.g` table.

The project also had no precedent for per-buffer keymap configuration; the
prior commit had just removed the pane's `/` (filter) and `g?` (help)
keymaps, leaving their specs and e2e cases stale.

## Decision

Make `require("diffundo").setup(opts)` the only configuration surface, in
the style of the neovim plugin ecosystem, and apply it project-wide:

- New `lua/diffundo/config.lua` owns the built-in defaults and the merge.
  `config.setup(opts)` rebuilds the current state from the defaults plus a
  shallow user overlay: scalar options replace, `glyphs` merges over
  `{ buffer = "@", write = "w", gap = "┆", ellipsis = "…" }`, and
  `keys.pane` merges per key. `config.get()` returns the merged state that
  `pane.lua`, `label.lua` and `glyphs.lua` read.
- The module initializes itself from the defaults at load
  (`M.setup(nil)`), so calling no `setup()` at all leaves every default in
  effect. `diffundo.setup` simply delegates to `config.setup`.
- Keymaps move into the options under `keys.pane`, pane-local only: no
  global keymaps are introduced and `j`/`k` remain plain motions. The
  default bindings are exactly today's six (`J`, `K`, `<cr>`, `<c-cr>`,
  `q`, `<esc>`); `/` (filter) and `g?` (help), removed by the preceding
  commit, stay removed and `pane.filter` is dropped as dead code.
- Every default keymap value is a plain Lua function of one argument: the
  facade `api` from the new `lua/diffundo/api.lua` module. The facade
  combines the command actions (`earlier`, `later`, `undo`, `search`,
  `focus`, `close`, wired from `diffundo`) with the pane actions
  (`move_save`, `place`, `apply`, `collapse`, wired from `pane`), so a
  replacement function gets everything it needs from that one argument.
- A `keys.pane` value of `false` or `""` removes that default binding;
  any other value replaces only that key and leaves the other defaults
  intact. `pane.map_keys` iterates the merged table and skips nothing
  because the removal happens at merge time.
- The five `vim.g.diffundo_*` reads are gone from `lua/`, `plugin/` and
  `spec/`; the README and vimdoc call the variables out as removed and
  point at the matching `setup` options instead of silently dropping them.
- Specs go through `setup` and reset the module with `config.setup(nil)`
  per test (each busted file runs in its own process). `spec/config_spec
  .lua` snapshots the pristine load-time defaults to prove the no-setup
  path, and covers each option, the per-key merge, the `false`/`""`
  removal rule, and the facade argument reaching the intended action.
- The e2e `statusline` assertion is made version-robust: it now compares
  the diff window's `&statusline`/`&winbar` to the global options instead
  of `""`, because nvim 0.13-dev ships a non-empty default `statusline`
  that an empty assignment cannot clear. The diff-window cases that feed
  `q`, `j`, `<cr>` and `<c-cr>` into the expanded pane, plus a new case
  that replaces `<cr>` with `api.apply` and disables `<esc>`, all run
  against a real headless nvim.

Where the Goal did not settle a design question, the choice that keeps the
defaults working with zero configuration was taken: the six-key default
set, load-time default initialization, per-key (not global) merging, and
keeping `history = false` as a real option value rather than a "removal".

## Consequences

- Unknown options are ignored and unset options fall back to the defaults;
  `setup()` can be called any number of times and each call re-merges from
  a copy of the defaults, so calling it restores earlier overrides.
- The pane's keymaps are applied when the pane float is created; a
  `setup` call while a pane is already open does not rebind that pane, but
  the next `:Diffundo` command recreates the float with the new bindings.
- `spec/fakevim.lua` needs no new API slice: the keymap behaviour it
  models (buffer-local `nvim_buf_set_keymap` callbacks) is unchanged.
- Configuration is typed (`diffundo.Opts`, `diffundo.Keys`,
  `diffundo.Api`) and testable without the editor, and the plugin keeps
  running on neovim 0.10+ with no new runtime dependencies.