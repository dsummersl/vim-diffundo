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

*:Diffundo search {pattern}* : find the undo state whose edit **added** a line matching `{pattern}` (a vim regex, so `'ignorecase'` and `'smartcase'` apply as with `/`), show it in the diff split, and put your cursor on the match. Repeat it to find the next older one.

*:Diffundo search! {pattern}* : the same for a line that was **removed**.

*:Diffundo history* : toggle the floating history sidebar — the undo tree as
a gutter of branch lanes, a one-line preview of what each edit changed, and
the age right-aligned. Runs of consecutive states fold into a caption row.

In the sidebar: *j*/*k* move by change (or use counts, *gg*/*G*), *J*/*K* move
between written states, *<cr>* shows the selected state in the diff split,
*/* filters the list (vim regex, empty to clear), *g?* notifies this key map,
*q*/*<esc>* closes it.

Search walks the undo *tree*: each state is compared with the state it was
edited from, so switching undo branches never shows up as a change.

The diff window is labelled with the timestamp and sequence number of the undo
state it shows. The label is set as that window's `'statusline'` and
`'winbar'`, so it stays visible even with `laststatus=3`.

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
local hit = diffundo.search("TODO")                    -- nil when nothing matches
local gone = diffundo.search("TODO", { removed = true })
-- hit = { seq, time, save, line, col, lnum }
```

`require("diffundo.walker").steps(from_seq)` is the iterator underneath: it
yields `{ seq, parent, time, save, lines, parent_lines, added, removed }` per
undo state, newest first, and must be called with the source buffer current.

History sidebar
---------------

`:Diffundo earlier/later/search` open the history float by default;
`:Diffundo -no-history earlier` (or `g:diffundo_history` = `false`) keeps the
minimal layout. The float sits in the upper right of the editor by default;
`g:diffundo_history_width` (default 40) sets its width and
`g:diffundo_fold_min` (default 3) the fold threshold: runs of consecutive
same-branch states longer than this collapse into a caption row.

Each row is `<gutter><preview …><time>`: ancestor lanes draw `┊`; the row's own
lane is `│`, `○`/`◉` when it is the diff's current state (`◉` also saved),
`●` when saved, `├┐`/`├┬┐` where a fork splits onto alternate branches, and
`└` closing the tree's last lane. The preview shows a single changed line
(`+ <line>`, `- <line>`) or counts like `+2 -1 lines`; the time column is
right-aligned compact relative age (`now`, `2m`, `1h`, `3d`, `2w`, `4mo`,
`2y`).

Runs of consecutive states on one branch collapse to a caption row
(`+8 states: +5 -3 lines 8 undos`) — `zo`/`zc` open/fold one run, `zr`/`zm`
all. A footer under `────` shows the selected state's sequence number,
saved status, absolute time and change totals, then `shown/total` and
a right-aligned `help: g?` hint; `g?` in the sidebar notifies this key list.
The float's rows come from `require("diffundo.history").rows`, the same list
the future telescope/quickfix front-ends reuse.

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

It needs `deno` and `nvim`.

Architecture Decision Records live in `docs/adr`; see `AGENTS.md` for the
day-to-day commands.
