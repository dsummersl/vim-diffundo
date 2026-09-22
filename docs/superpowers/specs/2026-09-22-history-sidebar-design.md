# History sidebar (the floating undo list)

Date: 2026-09-22
Status: approved design, not yet implemented
Delivers: roadmap sub-project 3 from issue #8 (the "sidebar"); depends on sub-projects 0 and 1, both landed

## Goal

Give `:Diffundo` a keyboard-first history sidebar: a floating list, one line per
undo state, carrying a one-line preview of what that edit changed. Moving
through the list (by change, or by written change with `J`/`K`) and confirming
a state with `<cr>` shows that state in the existing diff split. Commands show
the history by default; a `-no-history` switch keeps today's minimal
behaviour. The list is produced by our own function (`history.rows`) from the
existing walker, so the same rows render in the float now and, later, in a
telescope picker or quickfix list without changes.

The diff is the sole state display: it opens and changes **only** on `<cr>`.
Cursor moves never touch it.

## Non-goals

- Moving the diff split on cursor move (an earlier "live, throttled" idea).
  Rejected in session: the diff is strictly `<cr>`-driven; the throttle,
  timers and debounce are gone entirely.
- RCS labels (sub-project 2). The spec reserves a `row.label` slot so RCS
  drops in without interface change; the ticket order (sidebar before RCS)
  stands.
- A telescope source or quickfix target (sub-project 4). This spec only makes
  the rows they will consume public and pure.
- Vim-compatible anything (hard cut from the port).
- Mouse support, resizable float, multi-column layouts.

## Layering

```
plugin/diffundo.lua        :Diffundo  -> require("diffundo").command(args)
lua/diffundo/init.lua      command layer: flags, dispatch, notify, repeat, cursor
lua/diffundo/sidebar.lua   controller: float lifecycle, binds J/K/<cr>//q, reveal after commands
lua/diffundo/window.lua    float mechanics on nvim_* (mirrors split.lua)
lua/diffundo/history.lua   row builder + collector over the walker; render/next/filtered are pure
lua/diffundo/restore.lua   within_source: source guard extracted from init.lua (shared by search & history)
lua/diffundo/split.lua     unchanged: the diff window
lua/diffundo/walker.lua    unchanged: Step stream (drives the buffer)
lua/diffundo/tree.lua      unchanged: pure states list
lua/diffundo/subcommand.lua  gains the `history` subcommand and `-no-history` flag
```

Only the command layer moves the cursor or changes the current window.
`sidebar` follows the stock focusable-float picker model: while the user
navigates the float it is current, and close/reveal restore the window that
was current before. `history.render`/`next`/`filtered` are pure and touch no
`vim` state. `history.rows` is the exception: like `walker.steps`, it must run
with the source buffer current (it replays undos through the walker), so it is
called through `restore.within_source`. `window.lua` and `split.lua` are the
only modules that call raw `nvim_*` window APIs.

## 1. Command surface

```
:Diffundo earlier [count]      opens the history float by default, then steps the diff
:Diffundo later  [count]
:Diffundo search[!] {pattern}  opens the history at the hit
:Diffundo history              toggles the float; standalone over a plain buffer (no diff)
:Diffundo -no-history earlier  today's behaviour exactly: no float
```

- The `-no-history` flag is a leading whitespace-delimited token before the
  subcommand, so `search` keeps its verbatim pattern. Completion lists the
  flag, the subcommands and `history`.
- `g:diffundo_history` (boolean, default true) flips the default for everyone
  who wants minimal-as-default; the flag overrides it per call.
- Every successful `earlier`/`later`/`search` ends with
  `sidebar.reveal(t:diffundo_diff_undonr)` unless suppressed. `search` with no
  hit leaves the float untouched (selection keeps its current position).
- `history` while a diff is up toggles the float and leaves the diff as it is.
  `history` over a buffer with no diffundo split opens the float standalone;
  this is the same code path as every float open, it just has no diff behind
  it yet.
- `:Diffundo history` guards: no undo history -> the existing
  "No changes to view!" notify, no float.

## 2. `history.lua` (list computation)

```lua
---@class diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]       -- lines the edit added (multiset, per walker)
---@field removed string[]     -- lines the edit removed
---@field label string         -- label.for_undonr(seq); RCS annotation lands here in sub-project 2

---@param step diffundo.Step
---@return diffundo.Row            -- pure: Step -> Row
history.row_for(step)

---@param opts { limit?: integer }|nil   -- default limit 500
---@return diffundo.Row[]                -- newest first
history.rows(opts)

---@param row diffundo.Row
---@param width integer
---@return string                        -- exactly one display line, truncated to width
history.render(row, width)

---@param rows diffundo.Row[]
---@param index integer
---@param opts { written?: boolean }|nil -- written: skip rows without save
---@return integer                       -- clamp-safe neighbour (index, not +-1)
history.next(rows, index, opts)

---@param rows diffundo.Row[]
---@param regex vim.regex
---@param opts { removed?: boolean }|nil
---@return diffundo.Row[]                -- rows with a matching added/removed line
history.filtered(rows, regex, opts)
```

- `row_for` and `render`/`next`/`filtered` are pure: unit-testable with fixture
  `diffundo.Step`s and no fake. The `render` preview rule: exactly one `added`
  and no `removed` -> `+ {line}`; one `removed` and no `added` -> `- {line}`;
  otherwise `~ {n} added, {m} removed`. The rendered line is the `label`
  (which already carries seq and time, per `label.for_undonr`), a written
  marker for `{save}` rows, then the preview, truncated to `width`. A sentinel
  row (`seq == 0`) renders as `…older…` regardless of width.
- `rows` is the one impure function: it calls the source-guarded
  `restore.within_source(function() ... walker.steps(seq_last + 1) ... end)`,
  mapping each step through `row_for` and keeping `added`/`removed` (changed
  lines only, never full file text), stopping at `limit` states. When the cap
  cuts off older states, the last returned row is a sentinel
  `{ seq = 0, ... }` that `render`s as `…older…`; a later open with a larger
  limit replaces it. This keeps a long history on a large file finite without a
  cache (ADR 4's memoisation stays a measured fallback).
- `filtered` shares its predicate with search: the match predicate is
  extracted from `init.lua` (`match_in`) into a shared helper so `/` in the
  float and `:Diffundo search` agree byte-for-byte, including the
  `\C`/`\c` flag logic from `with_case_flag`.

## 3. `window.lua` (float mechanics)

- `open(cfg) -> win`: scratch buffer `buftype=nofile`, `bufhidden=wipe`,
  `swapfile=false`; `nvim_open_win` with `relative="editor"`, rounded border,
  winbar title (`diffundo history`), width from
  `g:diffundo_history_width` (default 40), height `min(#lines, o.lines - 4)`,
  anchored on the left.
- `set_lines(win, lines)`: toggles `modifiable`, writes, restores, like
  `split.place` does.
- `map(win, ...)`: buffer-local normal-mode maps for `J`, `K`, `<cr>`, `/`,
  `q`, `<esc>` only. `j/k/gg/G` and counts are native cursor motions because
  every row renders as exactly one line.
- `close(win)`: `nvim_win_close`; the `bufhidden=wipe` buffer dies with it.
- `is_open(win)`: window valid and its buffer still the sidebar buffer.

## 4. `sidebar.lua` (controller)

Tab-scoped state under `t:diffundo_history_*`: float win, buffer, rows, source
window, filter. Methods:

```
sidebar.open(cfg)         -- history.rows via restore.within_source, open float, focus it, cursor on the diff's current seq (else newest)
sidebar.close()           -- close float, focus returns to the window it opened over
sidebar.toggle()
sidebar.reveal(seq)       -- after commands: open if absent (unless -no-history) and move cursor to seq's row
sidebar.place()           -- <cr>: source buffer, split.open() if needed, split.place(state), focus back to the float
sidebar.move_save(dir)    -- J/K: history.next(..., {written = true}) in dir
sidebar.filter(pattern)   -- / : vim.fn.input, apply regex, re-render subset; empty clears
```

- The cursor in the float **is** the selection: no separate highlight state.
  `reveal(seq)` maps seq to a row index through the current filter view.
- `<cr>` (place): switch to the stored source window (error with the existing
  "source window no longer open" message if it is gone), run
  `within_source`/`split.place` exactly as `search` does today, then return
  focus to the float, which stays open for iterative browse-and-pick. `q` /
  `<esc>` / `:Diffundo history` close it; the diff keeps whatever state it
  last showed.
- The source window is the window that was current when the float opened.
  Standalone `<cr>` therefore binds the buffer *under* the float as the diff
  source via `split.open()` — the standalone and paired cases are one code
  path.
- `vim.fn.input` for `/` keeps it keyboard-first and dependencies-free
  (no `vim.ui.input` async plumbing in the fake). Regex semantics match
  search, including case flags.

## 5. Dispatch changes (init.lua / subcommand.lua)

- `subcommand.parse` gains `-no-history` as an accepted leading token (flag,
  no bang) and `history` as a name. `takes_bang[history] = false`.
- The local `within_source` in `init.lua` moves to `lua/diffundo/restore.lua`
  unchanged in behaviour; `init.lua` and `history.rows` both use it.
- `command`:
  - `history` -> `sidebar.toggle()`; return.
  - otherwise run the existing behaviour unchanged, then, unless
    `flag.no_history` or `g:diffundo_history == false`,
    `sidebar.reveal(t:diffundo_diff_undonr)` (only when the action succeeded;
    a no-hit search does not reveal).
- Cursor-neutrality holds: the command layer already restores the window and
  cursor; `sidebar.reveal` opens a float only as a side surface. A float being
  current while the user navigates it is the stock nvim picker model, not a
  cursor move the API must suppress.

## 6. Interaction model (recorded decision)

- Diff state opens/changes on `<cr>` only. Cursor movement in the float never
  re-places the diff split, never runs `within_source`, and schedules nothing.
- The earlier in-session "live, throttled" answer is superseded by this
  strict-`<cr>` model (recorded in ADR 5); it would have required timers in
  the fake and placed a diff behind every keystroke for no win over inline
  previews.

## 7. Filter semantics

- `/` prompts once (`vim.fn.input`); the input is a vim regex applied to every
  row's `added` lines via `history.filtered`. Additions-only for v1, matching
  the common case; a `removed` variant can follow if the float ever needs the
  `search!` parity.
- While a filter is active the listed rows are the subset; native `j/k` and
  `J/K` move within it; `reveal` clamps into it. An empty input clears the
  filter and restores the full list.
- The filter is display-only: it narrows what the float lists, never the
  unfiltered walk that `:Diffundo search` and the commands operate on.

## 8. Error handling

| Situation | Behaviour |
|---|---|
| No undo history, `:Diffundo history` | existing "No changes to view!"; no float |
| Source window gone when `<cr>` fires | existing "The diffundo source window is no longer open in this tab." |
| Float closed by the user | `reveal` reopens it; commands still work without it |
| `-no-history` + `history` together | flag wins; `history` still toggles the float |
| Invalid regex in `/` | vim's `E...` from `vim.regex`, float left as it was |

## 9. Testing

Fake growth (`spec/fakevim.lua`): `nvim_open_win` and `nvim_win_close`
(windows carry their `config`); a real keymap registry behind
`nvim_buf_set_keymap` with a `fake:press(keys)` helper that dispatches mapped
keys (so sidebar walks and binds are asserted by simulating keypresses);
`vim.fn.input` stub returning a test-programmed string; `vim.o.lines`.
`close_window` already wipes `bufhidden="wipe"` buffers.

Unit (busted, fake), mirroring module structure:

- `spec/history_spec.lua`: `row_for` fed fixture steps (linear and branched
  histories) asserting previews `+`/`-`/`~ {n} added, {m} removed`, `label`
  derivation, and the cap sentinel; `render` truncation; `next` clamping incl.
  `{written = true}`; `filtered` with case flags. A `rows`-collection case runs
  against the fake (source guard restores the live state, `diffupdate` runs).
- `spec/window_spec.lua`: open_win config, nofile/wipe opts, `set_lines`
  modifiable dance, the six keymaps bound, close wipes the buffer.
- `spec/sidebar_spec.lua`: open/close/toggle focus round-trip; `reveal` opens
  unless `-no-history` / `g:diffundo_history == false`; `reveal(seq)` cursor
  placement under an active filter; `<cr>` places the right seq in the diff
  split, keeps the float open, returns focus; standalone `<cr>` records the
  buffer as source via `split.open()`; `J`/`K` skip non-save rows;
  `/` narrows and empty clears.
- `spec/subcommand_spec.lua`: `-no-history` parsing and the `history` name.
- `spec/init_spec.lua`: flag propagation into `sidebar.reveal` calls;
  no-reveal on `search` miss.

End-to-end (`make e2e`, the angle the fake cannot reach): `:Diffundo earlier`
adds exactly one floating window (winbar `diffundo history`); `-no-history
earlier` adds none; `:Diffundo history` toggles; inside the float `j` moves,
`<cr>` changes the diff winbar label to the selected seq, `J` skips non-save
states, `q` closes and focus lands back on the source.

`make ci` gates apply (complexity <= 5, < 80 lines; `history.rows` and the
row-builder are the functions to watch).

## 10. Docs

- README: `:Diffundo history`, `:Diffundo -no-history`, sidebar keys (`j k J K
  <cr> / q`), `g:diffundo_history`, `g:diffundo_history_width`; a "History
  sidebar" section; the Lua API note for `history.rows`.
- `doc/diffundo.txt`: the `history` subcommand, keys, and the RCS slot note.
- ADR 0005: the floating sidebar, strict-`<cr>` display model (and its
  superseding of the throttled idea), `history.lua` purity/reuse promise, the
  `-no-history` default contract, and the `row.label` slot for RCS.
- Issue #8: tick sub-project 3; note sub-project 2 drops into `row.label`.

## Approaches considered

Windowing library for the float (the session's focus):

- A. Hand-rolled `window.lua` on `nvim_open_win`, zero deps, faked via the
  existing `vim` surface. **Chosen**: one float needs a third of any library;
  the fake stays an honest `nvim_*` fake; consistent with `split.lua`.
- B. nui.nvim `NuiPopup` for border/title/resize/close. Rejected: adds an
  optional dep and a nui stub to the fake (or e2e-only float tests) for
  features a ~80-line wrapper covers.
- C. plenary.window.float. Rejected: a big dep for a centred-float helper
  trivially reproduced by hand.

The decision is deliberately low blast radius: the rows and their rendering
are our own functions under all three options — only ~40 lines of `window.lua`
differ — so the lib choice never touches what is shown (the "anything we show
is our own functions" constraint), and swapping `window.lua` for nui later is
a one-file change.