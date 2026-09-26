# History pane — Design

**Project:** vim-diffundo
**Status:** implemented
**Decision record:** [ADR 4. History pane](../../adr/0004-history-pane.md)
**Supersedes:** the focused two-float history sidebar (`:Diffundo history`)
**Last updated:** 2026-09-26

## Goal

A small pane that shows what the diff split is comparing, the way an LSP hover
shows a symbol: always visible while the diff is open, never in the way. You
keep editing the source buffer and keep walking history with `:Diffundo
earlier` and `.`, and the pane tracks it. When you want to browse, you jump
into the pane, and it expands into the whole undo tree.

## Problems with the sidebar it replaces

- **It takes focus.** `:Diffundo earlier/later/search` open the tree float with
  `enter = true`, so you can't edit the file or repeat the command with `.`
  without first leaving the float.
- **The winbar label misaligns the diff.** `label.apply` sets a winbar on the
  diff window, which pushes its lines down so they no longer sit beside the
  matching lines of the source. The label also duplicates what the float
  already shows.
- **It is editor-sized.** The float sits in the editor's corner at nearly full
  height and covers whatever is under it, whether or not you're looking at it.

## Behaviour

- **One pane per diff split.** The pane opens with the diff split and closes
  with it (`WinClosed` on the diff window). Nothing else opens or closes it.
- **Focus stays in the source window.** Every `:Diffundo` subcommand leaves
  the cursor where it was, so editing and `.` keep working.
- **`:Diffundo focus`** jumps into the pane and expands it. `q`, `<esc>`,
  `<c-w>p`, or leaving the window any other way collapses it and returns to
  the source window. With no diff open, it opens the split at the buffer's
  own state first.
- **Every buffer gets a pane**, including one with no changes. The diff opens
  at `#0` with a single row, instead of the old "No changes to view!"
  notice. The diff stays on its `#seq` while you edit and the pane re-renders
  as you go, so you can leave it up and watch your changes against `#0`.
- **No winbar or statusline label.** The diff buffer keeps only its name
  (`diffundo://<source bufnr>/#4`) for `:ls` and statusline plugins.
- **Removed:** `:Diffundo history` and the `-no-history` flag.
  `g:diffundo_history = false` still turns the pane off.

## Layout

The pane is one float anchored to the diff window (`relative = "win"`), in the
diff window's bottom-right corner, beside the divider with the source. It
moves and resizes with the split. If the shared cursor row (scrollbind) would
fall under the pane, the pane flips to the top-right corner, as LSP hovers
do.

```
 diff (readonly)                    │ source
 1  local M = {}                    │ 1  local M = {}
 2- local y = 1                     │ 2+ local x = compute()
 3  return M                        │ 3  return x
 ~   ╭─ #4  2026-09-26 10:12:03 ───╮│ ~
 ~   │@ + return x              #12││ ~
 ~   │┆   7 undos 1ⓦ               ││ ~
 ~   │○ - local y = 1            #4││ ~
 ~   │┆   3 undos                  ││ ~
 ~   ╰─────────────── +3 -5 lines ─╯│ ~
```

The pane is a single window with `border = "rounded"`. Its border `title` and
`footer` (neovim 0.10) replace the separate two-row footer float.

- **Title:** `#seq  <date>` of the diff's state. The date is
  `os.date(g:diffundo_date_format, time)`. `#0` has no timestamp, so its
  title is `#0`.
- **Footer:** `+N -M lines`, the size of the diff between the diff's state and
  the buffer.

## Rows

```
lanes pip preview…                #seq
```

- **Lanes** are the existing tree gutter (`│ ┊ ├┘`), padded to the widest lane
  in view, so a row on a branch shows where it sits.
- **The pip** is one cell and shows the row's state. When several apply, the
  first wins:

  | state | default | `write = "ⓦ"` |
  |---|---|---|
  | the buffer's state | `@` | `@` |
  | written | `w` | `ⓦ` |
  | the diff's state | `○` | `○` |
  | anything else | lane (`│`) | lane (`│`) |

  A diff on a written state therefore shows the write pip. The title always
  names the diff's `#seq`, and the diff row carries the `DiffundoDiff`
  highlight, so it stays findable in the expanded view. On a branch's
  junction row the pip replaces the `┘` cap (`├○`, `├w`).
- **Preview** is the change that state made, as the history rows compute it
  today (`+ line`, `- line`, `+2 -1 lines`). `#0` has no preview. A preview
  too long for the pane is cut with a single `…`.
- **`#seq`** is right-aligned. Every undo number is written `#seq`.

### Gap rows

```
┆   N undos Kⓦ
```

A run of rows that isn't shown folds into one gap row. `N` counts the hidden
states and `Kⓦ` the written ones among them (dropped when `K` is 0). The tree
is ordered by `#seq`, so `N` is also the `:earlier`/`:later` step count
across the gap.

Gap rows carry no tree lanes and use the `DiffundoGap` highlight (linked to
`Comment`), so they read as gray.

## Collapsed and expanded

**Collapsed** (the default): the full tree with every row except the buffer's
state and the diff's state folded into gap rows. There are up to three gaps:

1. above the top row (you are mid-undo and can redo that many states),
2. between the two rows,
3. below the bottom row (states down to `#1`).

When the diff equals the buffer there is one row, marked `@`.

**Expanded** (`:Diffundo focus`): the same rows and the same gap caption, with
the tree's existing folds (off-trunk branch stretches longer than
`g:diffundo_fold_min`). The cursor starts on the diff's row. The title and
footer follow the cursor row, so they show what `<cr>` would place.

Keys in the expanded pane:

| key | action |
|---|---|
| `j` / `k`, `gg` / `G` | move by state |
| `J` / `K` | move between written states |
| `<cr>` | show the state under the cursor in the diff (stays in the pane) |
| `/` | filter (vim regex, empty clears) |
| `zo` / `zc`, `zr` / `zm` | open / close folds |
| `g?` | notify the key list |
| `q`, `<esc>`, `<c-w>p` | collapse and return to the source window |

## Scenarios

The mockups use `write = "ⓦ"`. With the default glyphs, `w` appears in the
same places.

### 1. A buffer with no changes, left up against `#0`

Just opened, then after one edit:

```
╭─ #0 ─────────────────────────────╮  ╭─ #0 ─────────────────────────────╮
│@                               #0│  │@ + hello world                 #1│
╰──────────────────── +0 -0 lines ─╯  │○                               #0│
                                      ╰──────────────────── +1 -1 lines ─╯
```

After a `:w` and a few more edits, the write is counted in the gap:

```
╭─ #0 ─────────────────────────────╮
│@ + return x                    #5│
│┆   4 undos 1ⓦ                    │
│○                               #0│
╰──────────────────── +4 -1 lines ─╯
```

### 2. Linear history: `:Diffundo earlier`, then `.` `.`

After the first `:Diffundo earlier`, then after two presses of `.`, landing on
a written state:

```
╭─ #11  2026-09-26 10:41:10 ───────╮  ╭─ #9  2026-09-26 10:40:31 ────────╮
│@ + return x                   #12│  │@ + return x                   #12│
│○ + print(y)                   #11│  │┆   2 undos                       │
│┆   10 undos 1ⓦ                   │  │ⓦ - local y = 1                 #9│
╰──────────────────── +1 -0 lines ─╯  │┆   8 undos                       │
                                      ╰──────────────────── +3 -1 lines ─╯
```

### A branched tree

Scenarios 3–7 share one tree. `#8` and `#4` are written. After `#8` a branch
was made (`#9`–`#10`), then the buffer went back to `#8` and the trunk
continued (`#11`–`#12`).

### 3. Expanded, after `:Diffundo focus`

The first `│` on each row is the float's border; the one after it is the
trunk lane.

```
╭─ #10  2026-09-26 10:22:47 ───────╮
│@  + return x                  #12│
││  + print(y)                  #11│
│┊○ + tmp()                     #10│
│├┘ + y = 3                      #9│
│ⓦ  - local y = 1                #8│
││  + y = 2                      #7│
││  +3 -1 lines                  #6│
││  + def handle_request(self, … #5│
│ⓦ  + bar()                      #4│
││  - baz()                      #3│
││  +2 lines                     #2│
││  +1 -1 lines                  #1│
││                               #0│
╰──────────────────── +2 -4 lines ─╯
```

### 4. The diff on a branch; 5. the buffer on a branch

On the left, the diff is on the branch. On the right, the buffer is on the
branch (reached with `g-`) and the diff is on its written parent, so its pip
is `ⓦ`; the gap above shows three states to redo.

```
╭─ #10  2026-09-26 10:22:47 ───────╮  ╭─ #8  2026-09-26 10:12:03 ────────╮
│@  + return x                  #12│  │┆    3 undos                      │
│┆    1 undo                       │  │┊@ + y = 3                      #9│
│┊○ + tmp()                     #10│  │ⓦ  - local y = 1                #8│
│┆    9 undos 2ⓦ                   │  │┆    7 undos 1ⓦ                   │
╰──────────────────── +2 -4 lines ─╯  ╰──────────────────── +1 -1 lines ─╯
```

### 6. The diff equals the buffer; 7. a long preview

```
╭─ #12  2026-09-26 10:42:00 ───────╮  ╭─ #5  2026-09-26 10:18:30 ────────╮
│@  + return x                  #12│  │@  + return x                  #12│
│┆    11 undos 2ⓦ                  │  │┆    6 undos 1ⓦ                   │
╰──────────────────── +0 -0 lines ─╯  │○  + def handle_request(self, … #5│
                                      │┆    4 undos 1ⓦ                   │
                                      ╰──────────────────── +7 -0 lines ─╯
```

### 8. A heavily branched history

The diff is two lanes deep. The gaps drop the lanes; the shown rows keep
them.

```
╭─ #7  2026-09-26 10:15:02 ────────╮
│@   + return x                 #20│
│┆     12 undos 3ⓦ                 │
│┊┊○ + tmp()                     #7│
│┆     6 undos                     │
╰──────────────────── +5 -2 lines ─╯
```

## Configuration

```lua
vim.g.diffundo_history = false                     -- no pane
vim.g.diffundo_glyphs = { write = "ⓦ" }             -- merged over the defaults
vim.g.diffundo_date_format = "%Y-%m-%d %H:%M:%S"   -- or function(time) -> string
vim.g.diffundo_history_width = 40                  -- pane width
vim.g.diffundo_fold_min = 3                        -- expanded-view fold threshold
```

Default glyphs:

```lua
{ buffer = "@", diff = "○", write = "w", gap = "┆", ellipsis = "…" }
```

The default `write` is a plain `w` because circled letters like `ⓦ` are
East Asian ambiguous width and some terminals draw them across two cells.
Kitty and WezTerm draw `ⓦ` in one cell, so it is a one-line opt-in.
Negative circled letters (`🅦`) are avoided entirely: most fonts draw them as
wide emoji.

Highlights, all `default link` so colour schemes can override them:

| group | default link | used for |
|---|---|---|
| `DiffundoGap` | `Comment` | gap rows |
| `DiffundoDiff` | `CursorLine` | the diff's row |
| `DiffundoBuffer` | bold | the buffer's row |

## Cost and caching

Each `+N -M lines` needs that state's text plus a `vim.diff()` against the
buffer. Materializing a state means `undo N` inside the source buffer
(`restore.within_source`), so it's the expensive step. Three rules keep it
cheap:

- **State text is cached by `#seq`.** An undo state's text never changes, and
  the walker already produces each state's lines while building the rows.
- **Counts are cached by `(#seq, b:changedtick)`.** They are computed lazily
  and only for the rows the pane shows: the diff's row when collapsed, the
  cursor row when expanded. An edit bumps `changedtick`, so stale counts are
  dropped without clearing the state-text cache.
- **Rows rebuild on a debounce.** The pane re-renders when `seq_last` or the
  buffer's state changes (`TextChanged`, `BufWritePost`, undo/redo), not on
  every keystroke in insert mode.

## Code changes

| file | change |
|---|---|
| `lua/diffundo/label.lua` | drop the winbar and statusline; keep the buffer name |
| `lua/diffundo/split.lua` | open at `#0` when there is no history instead of refusing |
| `lua/diffundo/sidebar.lua` | becomes `pane.lua`: one float, collapsed/expanded, no `enter` except on focus |
| `lua/diffundo/history.lua` | pip precedence, gap rows with write counts, `…` truncation, `#seq` column |
| `lua/diffundo/window.lua` | `relative = "win"`, border `title` / `footer`, corner flip |
| `lua/diffundo/subcommand.lua` | remove `history` and `-no-history`; add `focus` |
| new cache module | state text by `#seq`, counts by `(#seq, changedtick)` |
| `spec/fakevim.lua`, `types/vim.lua` | autocmds, `relative = "win"` floats, `nvim_win_set_config` title/footer, `b:changedtick` |
| `tests/e2e/` | goldens regenerated with `make gen` |

## Open questions

- **Buffer on a written state.** `@` beats written, so just after `:w` the
  buffer's row looks like any other buffer row. A fifth pip for "buffer,
  written" would show it, at the cost of another glyph.
- **Corner.** Bottom-right with a flip to the top is the starting point; the
  top-right is worth trying if the flip is distracting.
