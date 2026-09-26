vim-diffundo
============

Open a vertical diffsplit against a files undo history, and quickly pull changes
from your undo history into your current buffer.

Requires neovim 0.10 or newer.

Installation
------------

Use your favorite package manager to install this plugin. For instance:

    Plug 'dsummersl/vim-diffundo'

Commands
--------

One command, `:Diffundo`, with subcommands (tab-completes):

*:Diffundo earlier [count]* : compare your current buffer against the buffer if you had typed `:earlier [count]`. Accepts the same count as the builtin: `3`, `10s`, `2f` ... (default `1`).

*:Diffundo later [count]* : the same for `:later`.

*:Diffundo undo {n}* : compare your current buffer against the buffer at exactly
undo number `{n}` (as reported by `:undolist` or the history pane), the same
state `:undo {n}` would restore.

*:Diffundo search {pattern}* : find the undo state whose edit **added** a line matching `{pattern}` (a vim regex, so `'ignorecase'` and `'smartcase'` apply as with `/`), show it in the diff split, and put your cursor on the match. Repeat it to find the next older one.

*:Diffundo search! {pattern}* : the same for a line that was **removed**.

Searching also filters the history pane: only the states whose edit matches
stay visible, with `┆ N undos` rows standing in for the rest, and the pane's
footer reads `filter: {pattern}` (`filter!:` for removals) instead of the diff
size. The next `:Diffundo earlier`/`later` clears it.

*:Diffundo focus* : jump into the history pane and expand it into the whole
undo tree (opening the diff split at the buffer's own state first if needed).

In the expanded pane: *j*/*k* move by state (or use counts, *gg*/*G*), *J*/*K*
move between written states, *<cr>* shows the selected state in the diff split,
*/* filters the pane exactly like `:Diffundo search` does (vim regex, empty to
clear) and puts the cursor on the newest match, *zo*/*zc* open and close
folds (a fold you opened stays open when *<cr>* re-renders the pane), *g?* notifies this key map, and *q*/*<esc>* (or leaving the window, e.g.
*<c-w>p*) collapse the pane and return to your buffer.

*:Diffundo close* : close the diff split and history pane, if either is open.

Search walks the undo *tree*: each state is compared with the state it was
edited from, so switching undo branches never shows up as a change.

The diff window gets no statusline or winbar label, so its lines stay on the
same screen rows as your buffer's; the history pane shows which state it is.

Lua API
-------

Everything the command does is a function in `require("diffundo")`. All of
them leave your cursor and current window where they were and raise errors
rather than printing them, so they can be called from your own code (a
telescope picker, a scratch buffer):

```lua
local diffundo = require("diffundo")

diffundo.earlier("1f")
diffundo.later()
diffundo.undo("12")
local hit = diffundo.search("TODO")                    -- nil when nothing matches
local gone = diffundo.search("TODO", { removed = true })
-- hit = { seq, time, save, line, col, lnum }
diffundo.close()
```

`require("diffundo.walker").steps(from_seq)` is the iterator underneath: it
yields `{ seq, parent, time, save, lines, parent_lines, added, removed }` per
undo state, newest first, and must be called with the source buffer current.

History pane
------------

While the diff split is open, a small pane in the diff window's lower right
corner shows what the diff is comparing -- like an LSP hover, it never takes
the focus, so you can keep editing and keep pressing `.`:

```
╭─ #4  2026-09-26 10:12:03 ────────╮
│@ + return x                   #12│   <- the state your buffer is at
│┆   7 undos 1w                    │   <- states in between (and writes)
│╷ - local y = 1                 #4│   <- the state the diff shows, bolded
│┆   3 undos                       │
╰──────────────────── +3 -5 lines ─╯
```

The title is the diff's state and its date; the footer is the size of the diff
against your buffer. Each row is `lanes pip preview #seq`: the pip is `@` for
your buffer's state, `w` for a written state, otherwise the tree lane; the
diff's own row carries no separate pip, it's the one shown in bold. A buffer
with no changes still opens, against `#0`, so you can leave the pane up and
watch your edits pile up. It flips to the upper corner when your cursor would
sit under it, and closes with the diff window.

`:Diffundo focus` expands the pane into the whole tree, using the same row
format; branch stretches longer than `g:diffundo_fold_min` fold into
`┆ N undos` captions.

Configuration:

```lua
vim.g.diffundo_history = false                     -- no pane
vim.g.diffundo_glyphs = { write = "ⓦ" }             -- merged over the defaults
vim.g.diffundo_date_format = "%Y-%m-%d %H:%M:%S"   -- or function(time) -> string
vim.g.diffundo_history_width = 40                  -- pane width
vim.g.diffundo_fold_min = 3                        -- expanded-view fold threshold
```

The default glyphs are `{ buffer = "@", write = "w", gap = "┆",
ellipsis = "…" }`. `ⓦ` is opt-in because terminals disagree on the width of
circled letters (kitty and WezTerm draw it in one cell). The pane's rows use the
`DiffundoGap` (gap rows, linked to `Comment`), `DiffundoDiff` (the diff's row,
linked to `CursorLine` and bold) and `DiffundoBuffer` (bold) highlight groups.

The rows come from `require("diffundo.history").rows`; each state's text and
its diff size against your buffer are cached, so the pane only walks new undo
states as you edit.

Setup
-----

Example setup:

    " Diff against last undo:
    map <leader>uu :Diffundo earlier<cr>
    map <leader>rr :Diffundo later<cr>

    " Diff against last time this buffer was written:
    map <leader>uf :Diffundo earlier 1f<cr>
    map <leader>rf :Diffundo later 1f<cr>

Repeating
---------

If [tpope/vim-repeat](https://github.com/tpope/vim-repeat) is installed, then
`.` repeats the last `:Diffundo` command with the same arguments you last
used. Nothing to configure - it works with your own mappings and with the
commands typed by hand:

    :Diffundo earlier 1f
    " then press `.` to step back another file write

Without vim-repeat the commands still work, `.` just won't repeat them.

Development
-----------

Requires `lua`, `luarocks`, `stylua`, `selene`, `ast-grep`, `lua-language-server`, and `jq` on `PATH`.

    make setup
    make ci

The plugin lives in `lua/diffundo` and is tested with busted against a fake of
the neovim API, so no editor process is needed. `make ci` runs busted (with
coverage), selene, stylua, ast-grep, lua-language-server and a complexity check.

The commands are also covered by a separate end-to-end test that drives a real
headless neovim through [denops.vim](https://github.com/vim-denops/denops.vim):

    make e2e

It needs `deno` and `nvim`. `make gen` prints the undotree and rendered history
text that real neovim produces for each sample undo shape in
`tests/e2e/gen_samples.ts`; that output is the ground truth the golden busted
tests in `spec/tree_spec.lua` and `spec/history_spec.lua` are derived from.

Architecture Decision Records live in `docs/adr`; see `AGENTS.md` for the
day-to-day commands.
