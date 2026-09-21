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

*:DiffEarlier* : compare your current buffer against the buffer if you had typed `:earlier`. Accepts the same parameters as the builtin `:earlier` command.

*:DiffLater* : compare your current buffer against the buffer if you had typed `:later`. Accepts the same parameters as the builtin `:later` command.

*:DiffSearch <needle>*: search your undo history for the addition of `<needle>` and open a vertical diffsplit against that undo version and your current buffer.

The diff window is labelled with the timestamp and sequence number of the undo
state it shows. The label is set as that window's `'statusline'` and
`'winbar'`, so it stays visible even with `laststatus=3`.

Setup
-----

Example setup:

    " Diff against last undo:
    map <leader>uu :DiffEarlier<cr>
    map <leader>rr :DiffLater<cr>

    " Diff against last time this buffer was written:
    map <leader>uf :DiffEarlier 1f<cr>
    map <leader>rf :DiffLater 1f<cr>

Repeating
---------

If [tpope/vim-repeat](https://github.com/tpope/vim-repeat) is installed, then
`.` repeats the last `:DiffEarlier`, `:DiffLater` or `:DiffSearch`, with the
same arguments you last used. Nothing to configure - it works with your own
mappings and with the commands typed by hand:

    :DiffEarlier 1f
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
