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

    " Make commands Repeatable (with kreskij/Repeatable.vim):
    Repeatable map <leader>uf :DiffEarlier 1f<cr>
    Repeatable map <leader>rf :DiffLater 1f<cr>
