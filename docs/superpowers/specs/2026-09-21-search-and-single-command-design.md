# Search and the single `:Diffundo` command

Date: 2026-09-21
Status: approved design, not yet implemented
Delivers: roadmap sub-project 1 from issue #8; closes issue #7

## Goal

Replace `:DiffEarlier` / `:DiffLater` / `:DiffSearch` with one `:Diffundo`
command with subcommands, and rebuild search on a reusable, tree-aware undo
state walker that later sub-projects (sidebar, telescope picker, RCS labels)
consume directly. Everything the command can do is also a plain Lua function
that leaves the cursor and current window where it found them.

## Non-goals

- Searching forward (`later`) through the history.
- A "written states only" API. Every walker step carries `save`, so
  `vim.iter(walker.steps(n)):filter(...)` is the filter until the sidebar
  needs `J`/`K`.
- Memoising state text across steps (approach C below). Measure first.
- Keeping the old commands, even as deprecated aliases. There is no stable
  release to protect and #8 chose hard cuts.

## Layering

```
plugin/diffundo.lua        :Diffundo  -> require("diffundo").command(args)
lua/diffundo/init.lua      command layer: parse, dispatch, notify, repeat, move cursor
                           public API: earlier / later / search  (cursor-neutral, raise errors)
lua/diffundo/walker.lua    drives the buffer: undo parent, undo seq, diff -> Step stream
lua/diffundo/tree.lua      pure: undotree() -> states with parents, descending seq
lua/diffundo/lines.lua     pure: multiset added_lines / removed_lines  (was additions.lua)
lua/diffundo/cursor.lua    pure: where the source cursor lands after a hit
lua/diffundo/split.lua     unchanged: the diff window
lua/diffundo/label.lua     unchanged
lua/diffundo/count.lua     unchanged
```

Only the command layer moves the cursor or changes the current window. The
API restores both; the walker and the pure modules never touch them.

## 1. Command surface

```
:Diffundo earlier [count]     count as :earlier (3, 10s, 2f ...); default 1
:Diffundo later  [count]
:Diffundo search  {pattern}   state whose edit added a line matching {pattern}
:Diffundo search! {pattern}   state whose edit removed a line matching {pattern}
```

- One `nvim_create_user_command("Diffundo", ..., { nargs = "*", complete = ... })`.
  Completion lists `earlier`, `later`, `search`, `search!`.
- The first whitespace-delimited token is the subcommand; `search` may carry a
  trailing `!`. Everything after the first token is the argument, verbatim, so
  patterns with spaces need no quoting.
- Unknown or missing subcommand:
  `diffundo: unknown subcommand "x" (earlier, later, search, search!)`.
- vim-repeat: `.` re-runs the last full `:Diffundo ...` invocation, as today.
- `:DiffEarlier`, `:DiffLater`, `:DiffSearch` are removed from `plugin/`, the
  README, and the e2e suite.

## 2. Lua API (`require("diffundo")`)

```lua
---@param count string|nil
diffundo.earlier(count)             -- opens the split if needed, steps it back
diffundo.later(count)

---@class diffundo.SearchOpts
---@field removed boolean|nil       -- true: find where a matching line was removed

---@class diffundo.Hit
---@field seq integer               -- state where the change happened (displayed)
---@field time integer
---@field save integer|nil
---@field line string               -- the matched line
---@field col integer               -- 0-based match start within line
---@field lnum integer              -- line number in the state that had the line

---@param pattern string
---@param opts diffundo.SearchOpts|nil
---@return diffundo.Hit|nil
diffundo.search(pattern, opts)

---@param args string               -- everything after :Diffundo
diffundo.command(args)
```

Contract for `earlier`, `later`, `search`:

- Cursor-neutral: implemented once as a wrapper that records
  `nvim_get_current_win` and `nvim_win_get_cursor`, runs the body, and
  restores both (pcall-safe, re-raising afterwards).
- Errors are raised with `error(msg, 0)`, never `vim.notify`d. The command
  layer is the only place that notifies. This inverts today's `reporting_errors`
  so a telescope extension can handle "the diffundo split is no longer open"
  itself.
- `@/` and the search history are never written.

## 3. `tree.lua` (pure)

```lua
---@class diffundo.State
---@field seq integer
---@field parent integer            -- 0 for the original text
---@field time integer
---@field save integer|nil

---@param undotree table            -- vim.fn.undotree()
---@return diffundo.State[]         -- descending seq
tree.states(undotree)
```

Parent rule over `undotree().entries`:

- an entry's parent is the previous entry in its list;
- the first entry of an `alt` list has the same parent as the entry the `alt`
  hangs off;
- the first entry of the root list has parent 0.

Recursive over `alt`, then sorted by seq descending.

## 4. `walker.lua`

```lua
---@class diffundo.Step
---@field seq integer
---@field parent integer
---@field time integer
---@field save integer|nil
---@field lines string[]            -- text of seq
---@field parent_lines string[]     -- text of parent
---@field added string[]            -- lines in seq not in parent (multiset)
---@field removed string[]          -- lines in parent not in seq (multiset)

---@param from_seq integer
---@return fun(): diffundo.Step|nil -- lazy iterator, newest first
walker.steps(from_seq)
```

- Requires the source buffer to be current. For each state with
  `seq < from_seq`, in descending order: `silent undo parent`, read lines,
  `silent undo seq`, read lines, diff with `lines.lua`.
- Lazy: the search stops at the first hit; unvisited states cost nothing.
- Does not restore the buffer. Callers wrap it in `within_source`, which
  already restores the live undo state and runs `diffupdate` even when the body
  raises.
- Seq 0 (original text) is never yielded as a step: it has no parent, so it can
  add or remove nothing. A line present since the file was loaded therefore has
  no "added" state, which is the correct answer.

Approaches considered:

- A. Linear chronological walk (today's `:earlier` loop). One undo per state,
  but across a branch switch the added/removed lines are the difference between
  branches, not any edit. Rejected: the noise would have to be documented and
  the sidebar would inherit it.
- B. Tree-aware, parent from `undotree()`. Two undos per state; correct
  per-edit diffs; parent map is a pure function. **Chosen.**
- C. B plus a per-seq line cache. Halves undos in the linear case at the cost
  of holding every visited state's text. Deferred until measured.

## 5. `search` semantics

1. `split.open()`; if it returns false (no undo history, existing
   "No changes to view!" notify inside `split`) return `nil`.
2. Compile `vim.regex(pattern)` before any walking, so an invalid pattern
   raises vim's own `E...` message with the buffer untouched. `match_str`
   honours `'ignorecase'`, `'smartcase'` and `'magic'` like `/`.
3. `from_seq` is `t:diffundo_diff_undonr` when the split was already open,
   otherwise `changenr() + 1` so the live state is the first candidate.
4. Inside `within_source`, iterate `walker.steps(from_seq)`; test each line of
   `step.added` (or `step.removed` with `opts.removed`) against the regex. The
   first matching line is the hit.
5. On a hit: `split.place(step.lines, step.seq)`. The diff window shows the
   state where the change happened, `t:diffundo_diff_undonr == step.seq`, so
   the label and tab variable agree and `earlier` afterwards steps exactly one
   state back. `lnum` is the matched line's index in `step.lines` for
   additions and in `step.parent_lines` for removals.
6. No hit: return `nil`; the split (opened or not) is left as it was and
   `t:diffundo_diff_undonr` is untouched.

A repeated `:Diffundo search foo` starts behind the displayed state, so it
finds the next older addition of `foo`, like `n`.

## 6. Cursor after a hit (command layer only)

`cursor.locate(source_lines, hit) -> lnum, col`:

- the first line of the source equal to `hit.line` (plain string equality) ->
  that line, `hit.col`;
- otherwise `min(hit.lnum, #source_lines)`, column 0;
- an empty buffer -> line 1, column 0.

`command` focuses the source window and sets the cursor there. `cursorbind`
scrolls the diff window alongside.

## 7. Error handling

| Situation | Behaviour |
|---|---|
| Unknown / missing subcommand | `diffundo: unknown subcommand "..." (earlier, later, search, search!)` |
| Bad count for earlier/later | existing `count.normalize` error, notified by the command layer |
| `search` with empty pattern | `diffundo: search needs a pattern`, before opening anything |
| Invalid regex | vim's `E...` from `vim.regex`, before any undo walking |
| No undo history | existing "No changes to view!"; API returns `nil` |
| No hit | command notifies `diffundo: no state adds a line matching {pattern}` (`removes` for `search!`) |
| Error mid-walk | `within_source` restores the live state, `diffupdate`, re-raises |
| Split closed by the user | existing "The diffundo split is no longer open in this tab." |
| API called from the diff window | `split.open()` moves to the source (existing `leave_stale_diff_window`); the wrapper restores the original window on return |

## 8. Testing

Unit, busted, no neovim:

- `spec/tree_spec.lua`: linear history, one `alt`, nested `alt`s, `save`
  markers; asserts parents and descending order. Fixtures are literal
  `undotree()` tables copied from a real nvim session.
- `spec/walker_spec.lua`: the fake grows a tree. `fakevim` keeps
  `seq -> {lines, parent, time, save}`, `undotree()` returns entries with
  `alt`, `undo N` jumps to any seq, and a builder such as
  `fake:branch_from(seq)` creates alternates. `earlier`/`later` remain
  chronological moves over that table. Asserts added/removed per step including
  across a branch switch, laziness, and the `from_seq` boundary.
- `spec/lines_spec.lua`: renamed from `additions_spec.lua`; adds
  `removed_lines`.
- `spec/cursor_spec.lua`: exact line present, absent -> clamped, empty buffer.
- `spec/init_spec.lua`: `search`/`search!` via the API against the fake: split
  placed at the right seq, honest `t:diffundo_diff_undonr`, return value,
  `nil` on no hit, errors raised not notified, window and cursor unchanged
  after each API call. `command`: dispatch, `search!`, patterns with spaces,
  unknown subcommand notifies, repeat re-runs the same invocation, cursor
  placed per `cursor.locate`.
- `vim.regex` in the fake: a shim good enough for the fixture patterns (plain
  `string.find` after stripping `\V`); real regex semantics are asserted e2e.
- `types/vim.lua` gains `vim.regex`, the `undotree()` entry shape,
  `nvim_win_get_cursor` / `nvim_win_set_cursor`.

End-to-end (`make e2e`): the existing cases move to `:Diffundo earlier/later`.
New: build states including a branch (`u`, then a new edit), `:Diffundo
search`, assert diff buffer contents, winbar label seq, source cursor, then
`:Diffundo earlier` steps exactly one seq back; `search!`; a no-match;
`smartcase` behaviour.

`make ci` gates as usual: complexity <= 5 per function, < 80 lines. The walker
iterator and the command parser are the functions to watch.

## 9. Docs

- README: Commands rewritten for `:Diffundo`; new "Lua API" section with the
  three functions and the cursor-neutral promise; setup mappings updated.
- `doc/diffundo.txt`: first vim help file (`:h :Diffundo`, `:h diffundo-api`).
- ADR 0004 records the single command, the layering (who may move the cursor)
  and the tree-aware walk.
- Close #7; comment on #8 ticking sub-project 1.
