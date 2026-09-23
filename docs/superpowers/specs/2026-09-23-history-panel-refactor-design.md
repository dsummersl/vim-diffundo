# History Panel Refactor — Design

**Date:** 2026-09-23
**Status:** approved-for-implementation
**Derived from:** `docs/designs/history-panel/design.md` (product design, stage 2 approved)
**Project:** vim-diffundo

## Goal

Replace the history sidebar's flat one-line-per-state float with the approved
layout: a tree gutter with branch edges and state glyphs, a change-preview
column, a right-aligned relative-time column, vim-fold regions that collapse
runs of consecutive same-branch states, and a footer (divider + two lines) that
carries everything else. The product layout is locked; this spec is the
implementation contract.

## Current behavior

- `history.rows()` walks the undo tree and returns `diffundo.Row`
  `{ seq, time, save, added, removed, label }` where `label` is
  `"<relative> - <seq>"`.
- `history.render(row, width)` returns `label .. " [saved]" .. "  " .. preview`
  (preview = `+ first-added` / `- first-removed` / `~ N added, M removed`).
- `sidebar.open()` renders those lines into a float via `window.open/render`,
  maps `J K <cr> / q <esc>`, selects the diffed state's row, and filters via
  `history.filtered`.
- `window.lua` is a thin float helper. `label.relative` exists.

## Target behavior (per row)

One buffer line per row, laid out left to right as:

```
<gutter><preview …right-padded or truncated>…<time right-aligned>
```

Example (this is the visual contract, from the approved design; one row is one
change, the active lane is solid, ancestors are `┊`, and count summaries say
"lines"):

```
  ○   +foo(); a = b                 1m
  │   +2 -1 lines                   3m
  ├┐  -3 lines                      5m
  ┊●  +far                          3m
  ┊│  +9 states: +5 -3 lines 9 undos  12m
  │   −bar(); refund():            16m
  │   +2 -1 lines                   3m
  ├┬┐ -3 lines                      5m
  ┊┊│ +12 -15 lines                12m
  ┊●  +9                           12m
  └●  + initial file                2h
```

### Tree gutter (depth-proportional)

One **row is one undo change** (a fold's caption is a region, not a "change").
The gutter renders the undo **tree**, not a unary chain. Columns are nested by
branch depth — an alternate child nests one column to the right of the branch
it hangs from — so a row at depth `d` has `d` gutter cells.

The **active lane** is the row's own lane (its innermost cell): it draws solid
and is the lane the rest of the row's text is about. Every *ancestor* lane the
row passes under still open is drawn **dashed** (`┊`, box-drawing light doubly
dashed vertical) so there is only ever one solid lane per row. The preview
column indents with the gutter; the time column always ends at the panel's
right edge.

Cell rules, left to right:

1. **Outer cells** (`d - 1` of them) are `┊` (dashed, a lane the row passes
   under but is not about) while that branch column is still open on this
   row's chain, empty once the column has closed above the row.
2. **Innermost cell** — the node on the row's own lane — is, in priority
   order:
   - a fork junction when this row has ≥ 2 children in the view: `├` (trunk
     continues down) + `┬` for each alternate arm except the last + `┐` for
     the last arm. One alternate → `├┐`; two → `├┬┐`; the junction spans
     columns `depth .. depth + k` where `k` = number of alternate children.
   - `└` when this row is the last in its branch column (closes the lane).
   - the node glyph otherwise.
3. **Node glyph** (0 or 1 char), in priority order:
   - `◉` — the diff's current state **and** saved (bold).
   - `○` — the diff's current state (saved or not). At most one row in a view
     shows `○`/`◉`.
   - `●` — a saved state (bold).
   - `◆` — a branch-switch row that is not itself saved or current.
   - empty otherwise.
4. One padding space after the last gutter cell.

The view is the source of truth for tree topology: rows in a view build a
parent→children map (`parent` from the row model); a child whose parent is not
the previous sibling's parent opens a fork.

### Preview column

- `#added == 1 and #removed == 0` → `+ <added[1]>` (span colored `DiffAdd`).
- `#added == 0 and #removed == 1` → `- <removed[1]>` (span colored
  `DiffDelete`). Note the leading char here is `-`, the design's "`−`" is a
  typographic minus; use ASCII `-` for unified trivia in buffer text.
- Otherwise → `+<#added> -<#removed> lines` with the `+N` and `-M` segments
  colored `DiffAdd` / `DiffDelete` (e.g. `-3 lines`, `+2 -1 lines`). The unit
  is always `lines` — a single-line change shows the line itself, so `line`
  never occurs.
- Fills the space between gutter and time column. If it would collide with the
  time column, truncate with a single trailing `…`.

### Time column

- Relative time via `label.relative(row.time)`, right-aligned.
- Column width = `max(relative lengths in view) + 1` (so it hugs the right
  edge with one space of breathing room). Fold introspections use the same.

### Fold runs

- A *run* = maximal consecutive rows where `row[i-1].parent == row[i].seq`
  (the list walks newest→oldest, so going down the list is moving to each
  row's parent; a run is a same-branch chain), length ≥ `g:diffundo_fold_min`
  (default `3`).
- A run renders as a **caption line** followed by the run's real rows:
  - Caption text: `+<run length> states: +<total added> -<total removed>
    lines <run length> undos` with the right-aligned time of the run's
    newest row. e.g. `+9 states: +5 -3 lines 9 undos  12m`.
  - Caption gutter: the gutter of the run's first row (own lane solid, the
    run's branch is the caption's lane). The fold is a region, not a change —
    the caption carries no node glyph.
- The caption line plus the run's rows form a *manual* vim fold region.
- Collapsed by default (`foldlevel=0`); `zo`/`zc`/`zr`/`zm` work natively.
- `foldtext` = `getline(v:foldstart)` (the caption shows verbatim; no vim
  decoration doubling).
- Runs are recomputed from the *current view* (filters change runs).

### Footer

Below the rows, separated by a `────…` divider (`-` run to the panel width):

- Line 1: `<#seq>  <meaning>  <absolute time>  <+N -M totals>` where
  `<meaning>` is, space-separated, one or more of `◉ saved`, `○`,
  `◆ branch`. Example: `#12  ◉ saved  2026-09-23 09:12  +1 -0`.
  Absolute time format = `os.date("%Y-%m-%d %I:%M:%S %p")` but truncated to
  fit the panel width.
- Line 2: `<shown>/<total>` at the left (matches a `3/12` style) and
  `help: g?` right-aligned.

Footer always reflects the **selected** row (the cursor row in the float).

## Data model

Extended `diffundo.Row`:

```lua
---@class (exclusive) diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]
---@field removed string[]
---@field parent integer   -- NEW
---@field label string     -- unchanged: "<relative> - <seq>"
```

`history.row_for` gains `parent = step.parent`. `older` sentinel gains
`parent = 0`.

## New `history` API

One entry point that produces everything the sidebar needs; all pure.

```lua
---@class diffundo.Span
---@field line integer      -- 0-based buffer line
---@field hl string         -- highlight group name
---@field col_start integer -- 0-based, inclusive
---@field col_end integer   -- 0-based, exclusive

---@class diffundo.Fold
---@field start integer     -- 1-based buffer line of caption
---@field stop integer      -- 1-based buffer line of last run row

---@class diffundo.Display
---@field lines string[]                            -- full buffer: rows (+captions) + divider + footer
---@field spans diffundo.Span[]                     -- bold + color spans
---@field folds diffundo.Fold[]                     -- manual fold regions
---@field row_to_line integer[]                     -- view index -> 1-based buffer line
---@field footer_start integer                      -- 1-based buffer line of the divider

---@param view diffundo.Row[]
---@param opts { current?: integer, width: integer, selected?: integer, total?: integer, fold_min?: integer }
---@return diffundo.Display
M.display = function(view, opts)
```

`opts.current` = `vim.t.diffundo_diff_undonr` (nil when no diff split).
`opts.selected` = 1-based view index of the selected row.
`opts.total` = total rows before filtering (for the `3/12` fraction).
`opts.fold_min` = fold threshold; the sidebar reads `g:diffundo_fold_min`
(default 3) and passes it in, so `display` stays pure.

Implementation note — keep the piece-builders as module-internal pure locals so
`display` stays small: `topology_for(view)` computes `depth` per row and the
parent→children map; `gutter_for(view, index)` renders that row's cells;
`preview_for(row)`, `time_for(view)`, `run_builder(view, fold_min)` as below.

Keep `M.render`/`M.row_for`/`M.next`/`M.filtered`/`M.rows` as-is except
`row_for` (adds `parent`). Remove `preview_for`'s old `~ N added, M removed`
format only where it conflicts (unit specs must be updated).

## `sidebar` changes

`open()` becomes:

1. `view = vim.t.diffundo_history_view` (unchanged flow: fresh = `history.rows({})`).
2. `display = history.display(view, { current = vim.t.diffundo_diff_undonr,
   width = <panel width>, selected = <selected index>, total = #<all rows> })`.
3. `window.render(float, display.lines)`.
4. Apply `display.spans` via `nvim_buf_add_highlight` into a single namespace
   (clear the namespace first: `nvim_buf_clear_namespace`).
5. Fold setup on the float buffer (`nvim_buf_call`):
   - `vim.bo.foldmethod = "manual"`, `vim.wo.foldlevel = 0`,
     `vim.wo.foldtext = "getline(v:foldstart)"`.
   - `:N,Mfold` for each `display.folds` entry.
   - Before re-render, `:%delfold` (reset).
6. `select_row` and cursor-move/filter/place paths translate **view index** ↔
   **buffer line** via `display.row_to_line`. Store the active display in
   `vim.t.diffundo_history_display`.

Keymap additions in the float (existing keys preserved): `g?` → `vim.notify`
with the key list (a multi-line string is fine).

`M.move_save`, `M.filter`, `M.reveal`, `M.place` adapt to the cursor ↔ index
mapping; the re-render path (filter) repeats steps 2–5 instead of
`window.render` alone.

## `window` changes

None. Float creation/config stays generic.

## Fake (`spec/fakevim.lua`) additions

- `nvim_buf_add_highlight(buf, ns, hl, line, col_start, col_end)` → record into
  `self.highlights` (so specs can assert groups/ranges).
- `nvim_buf_clear_namespace` → clear the recorded highlights list (accepting
  any ns/id).
- `nvim_buf_call(buf, fn)` → run `fn()` with the buffer's window current
  (set `self.current_win` to the buf's window, then restore).
- `fold` command (`:N,Mfold`) and `delfold` command → set `self.folds`
  (list/clear). `foldmethod`, `foldlevel`, `foldtext` ride the existing
  window-option proxy (`vim.wo`).
- Add `vim.o`/`vim.wo` access to anything new the code reads (`lines`,
  `columns` already exist; add `foldlevel`, `foldtext`, `foldmethod` if not
  already covered by the generic option proxy — it is).

## Types (`types/vim.lua`)

Add to `vim.api`: `nvim_buf_add_highlight`,
`nvim_buf_clear_namespace`, `nvim_buf_call`.
Add to `vim.wo`: `foldlevel integer` (and note `foldtext string`,
`foldmethod string` already declared). `vim.api` functions get
`fun(...)` signatures matching usage.

## Configuration

- `g:diffundo_fold_min` (default `3`) — minimum same-branch run length that
  folds. The sidebar reads it and passes it to `history.display` as
  `opts.fold_min`.

## Tests

Unit (busted, against the fake):

- `history`:
  - `display.lines`/`spans` for: single add, single remove, counts, run
    caption, footer divider + two lines.
  - gutter rules: glyphs (`○`, `◉`, `●`, `◆`, blank) at depth/depth colors,
    active-lane solid vs dashed ancestors (`│` own lane, `┊` pass-through),
    fork junctions (`├┐`, `├┬┐`), and `└` lane closes.
  - time column: right-aligned, width = longest relative + 1; preview
    truncates with `…` when it would collide.
  - fold runs: caption text (`+9 states: +5 -3 lines 9 undos`), `folds`
    ranges, `row_to_line` mapping, `footer_start`.
  - run grouping: `parent` chain continuation vs branch switch.
- `sidebar`:
  - open produces folds + highlights + `foldlevel=0` on the float.
  - selection → footer line 1; `3/12` and `help: g?` present.
  - movement maps through `row_to_line` (cursor lands on the right buffer
    line when captions are above).
  - `g?` notifies the key list.
  - filter re-renders runs/folds.
- `fakevim`: new APIs behave (record + fold commands).

E2E (denops, real nvim):

- keep existing coverage; update assertions that read float lines:
      - the `- N` row marker is gone → assert the footer contains `#2`
        (the previous `:Diffundo history` toggle test asserted a row marker;
        the footer now carries the seq).
      - build ≥ 4 same-branch states; assert a fold exists
        (`foldclosed(<caption line>)` returns a line number, and one buffer
        line starts with `+9 states:`-style caption text), and that
        `:normal zo` reveals the run's real rows.
      - assert `g?` shows the key list via `:messages`.

## Out of scope

- Diff split behavior, `label.apply` (diff-window winbar/statusline), the
  relative-time change (already shipped), the winbar push-down issue, mouse
  interaction, telescope/quickfix front-ends.

## Open questions

- None blocking. `g?` presentation (notify vs a small help float) is
  deliberately `vim.notify` for now.
