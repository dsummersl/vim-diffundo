TODO / future directions
========================

Notes from a read-through of the code. Nothing here is urgent; it is a place to
park ideas so they don't get rediscovered every time.

Bugs
----

- `_update_buffer_name()` names the seq-0 buffer with the literal string
  `{original} - 0` -- the f-string prefix is missing and `original` is not
  defined anywhere. It should probably restore the source file's own name.
- Buffer names built from the undo timestamp contain spaces and colons, so
  `:file 2021-08-01 11:04:19 PM - 5` does not do what it looks like. Run the
  name through `fnameescape()`.
- `_find_undotree_entry()` walks only the top level of `undotree().entries`.
  Entries on an alternate branch are nested under an `alt` key, so landing on
  one raises `StopIteration` out of the bare `next()`. See the xfail in
  `tests/diffundo/test_interface.py`. Flatten `alt` recursively and give
  `next()` a default.
- `search_earlier()` feeds the matched line straight to `/` without escaping,
  so a match containing `.`, `*`, `/` or `\` searches for the wrong thing (or
  raises E486). Use `escape(..., '/\\.*$^~[]')` or a `\V` very-nomagic search.
- `within_source()` wraps its body in `try:`/`finally: pass` -- the restore
  step is inside the `try`, so an exception in the body leaves the source
  buffer sitting at an older undo state. Move the restore into the `finally`.

Features
--------

- `:DiffSearchLater` -- search forward through the undo history, mirroring
  `:DiffSearch`.
- Search for *removals* as well as additions ("when did this line disappear?").
- A `:DiffUndoClose` command to tear the split down and clear the `t:` vars.
  Right now the state is only validated with `bufexists()`, so closing the
  scratch window by hand leaves `t:diffundo_diff_bn` pointing at a buffer that
  has no window and `_focus_window_of_buffer()` raises `StopIteration`.
- A mapping/command to pull the diff buffer's version of a hunk into the source
  buffer (`do`/`dp` work, but a "take this undo state wholesale" command would
  be handy).
- Jump straight to a save point (`:DiffEarlier 1f` exists via `:earlier`, but a
  `:DiffSaves` list to pick from would be nicer).

Housekeeping
------------

- `autoload/diffundo.vim` guards on `b:autoloaded_diffundo` (buffer-local);
  autoload guards are conventionally `g:`.
- `pyproject.toml` lists `black` and `python-vim` as runtime dependencies, and
  `pytest` is pinned at `^5.2`. `black` belongs in dev-dependencies, and the
  test suite no longer needs a `vim` package at all (see `tests/fakevim.py`).
- No `doc/diffundo.txt`, so `:help diffundo` finds nothing. The README content
  is most of the way to a help file already.
- The tests drive `VimInterface` against a fake vim. An end-to-end smoke test
  running `vim --clean -es` (or `nvim --headless`) over a scratch file with a
  real undo history would cover the vimscript layer too.
