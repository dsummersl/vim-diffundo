# 4. Single command, cursor-neutral API and tree-aware undo walker

Date: 2026-09-21

## Status

Accepted

## Context

After the Lua port (ADR 3) the plugin exposed three commands, `:DiffEarlier`,
`:DiffLater` and `:DiffSearch`, each a thin wrapper over a function in
`lua/diffundo/init.lua` that swallowed errors with `vim.notify` and moved the
cursor as a side effect. `:DiffSearch` was a straight port of the python
version and kept its known defects (issue #7): it searched by plain substring,
found additions only, labelled the diff window with one undo state while
recording another in `t:diffundo_diff_undonr`, and walked the history
chronologically, so adjacent states on different undo branches produced
"added" lines that no edit had made.

The roadmap (issue #8) wants the same walk to feed a sidebar with per-state
preview diffs, a telescope picker, and git-blob lookups for written states.
Those front-ends need the core as plain Lua functions they can call from their
own windows, without the cursor jumping in the user's buffer.

## Decision

**One command, `:Diffundo`, with subcommands** `earlier [count]`,
`later [count]`, `search {pattern}` and `search! {pattern}`. The old three
commands are removed outright, as with the other hard cuts in #8.

**Three layers, and only the top one moves the cursor:**

- `plugin/diffundo.lua` defines `:Diffundo` and calls `diffundo.command(args)`.
- The command layer in `lua/diffundo/init.lua` parses the subcommand, turns
  raised errors into `vim.notify`, registers with vim-repeat, and after a
  search hit places the cursor in the source window (on the matched line if it
  is still there, else on its old line number).
- The public API `diffundo.earlier`, `diffundo.later`, `diffundo.search`
  raises errors and is cursor-neutral: a single wrapper records the current
  window and cursor before the body and restores them after, even on error.
  `@/` is never written.

**A tree-aware walker.** `tree.lua` is a pure function from `vim.fn.undotree()`
to a list of states with their parent seq (previous entry in the list; an
`alt` branch shares the parent of the entry it hangs off). `walker.lua`
iterates the states newest first, and for each runs `undo parent`, `undo seq`
and a multiset line diff, yielding `{seq, parent, time, save, lines,
parent_lines, added, removed}`. Each step is therefore exactly what that edit
did, regardless of undo branches. The walk is lazy so search stops at its first
hit. Patterns are vim regexes via `vim.regex`, so `'ignorecase'` and
`'smartcase'` apply as with `/`.

**The diff window shows the state where the change happened**, and
`t:diffundo_diff_undonr` always equals what is displayed. A repeated search
continues from behind the displayed state; `earlier` after a search steps back
exactly one state.

## Consequences

- Users update mappings: `:DiffEarlier 1f` becomes `:Diffundo earlier 1f`.
  There is a vim help file for the first time (`doc/diffundo.txt`).
- Two `:undo` calls per visited state instead of one. The multiset diff is
  linear in lines, and `:undo N` is cheap for adjacent states, so this is
  expected to be far under the old `difflib.ndiff` cost. A per-seq line cache
  is the fallback if a long history on a large file proves slow.
- `spec/fakevim.lua` must model an undo *tree* (`undotree()` with `alt`, `undo
  N` to any seq), not just a line. That is also what the sidebar's tests will
  need.
- Front-ends (sidebar, telescope, RCS labels) consume `walker.steps` directly
  and never go through the command layer, so they inherit no cursor movement.
- Errors from the API propagate to the caller; anyone calling
  `require("diffundo")` from their own code must `pcall` if they want the
  notify behaviour the command gives.
- A line present since the buffer was loaded has no "added" state; searching
  for it reports no match rather than pointing at seq 0.
