vim-diffundo
============

Open a vertical diffsplit against a files undo history, and quickly pull changes
from your undo history into your current buffer.

Installation
------------

Use your favorite package manager to install this plugin. For instance:

    Plug 'dsummersl/vim-diffundo'

Commands
--------

*:DiffEarlier* : compare your current buffer against the buffer if you had typed `:earlier`. Accepts the same parameters as the builtin `:earlier` command.

*:DiffLater* : compare your current buffer against the buffer if you had typed `:later`. Accepts the same parameters as the builtin `:later` command.

*:DiffSearch <needle>*: search your undo history for the addition of `<needle>` and open a vertical diffsplit against that undo version and your current buffer.

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

The python half of the plugin lives in `pythonx/diffundo` and is tested against
a fake `vim` module, so no vim process is needed:

    make setup
    make ci

`make ci` runs pytest (with coverage), ruff, ast-grep, mypy, radon and vulture.
Architecture Decision Records live in `docs/adr`; see `AGENTS.md` for the
day-to-day commands.
