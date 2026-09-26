# 4. History pane

Date: 2026-09-26

## Status

Accepted

## Context

`:Diffundo earlier/later/search` open a history sidebar: two editor-relative
floats (the undo tree and a pinned two-row footer) in the editor's upper
right. `:Diffundo history` toggles it. Three problems came out of using it:

- The tree float is opened with `enter = true`. Focus lands in it after every
  command, so you can't keep editing the source or repeat the command with
  `.` (vim-repeat) to keep walking back.
- `label.apply` puts the diff state's label in the diff window's winbar. A
  winbar on one side of a diff pushes that window's lines down, so they no
  longer line up with the source. The label also repeats what the sidebar
  shows.
- The sidebar is sized to the editor, not the diff, and covers the editor
  whether or not you're using it.

## Decision

Replace the sidebar with a history pane, designed in
[docs/designs/history-panel/design.md](../designs/history-panel/design.md):

- The pane is one float anchored to the diff window. It opens and closes with
  the diff split and never takes focus on its own.
- It is collapsed by default: the buffer's state (`@`) and the diff's state,
  with everything else folded into gray `┆  N undos Kw` gap rows. The border
  title names the diff's state (`#seq` plus a date from
  `g:diffundo_date_format`). The border footer gives the diff's size
  (`+N -M lines`).
- `:Diffundo focus` enters the pane and expands it into the full tree.
  Leaving collapses it and returns to the source window.
- A buffer with no undo history still opens the diff (at `#0`), so the pane
  can be left up as a running diff against the original.
- Drop the winbar and statusline label; keep only the diff buffer's name.
- Remove `:Diffundo history` and `-no-history`. `g:diffundo_history = false`
  still disables the pane.
- Glyphs come from `g:diffundo_glyphs`, merged over narrow defaults (`w` for
  written). Circled letters are opt-in because terminals disagree on their
  width.
- Diff sizes are memoized: state text by `#seq`, counts by
  `(#seq, b:changedtick)`, computed only for the rows on screen.

## Consequences

- Editing, `.`, and `:Diffundo earlier` keep working while the pane is up.
  The pane refreshes on buffer changes, which is why the caching is needed.
- The two-float footer machinery and `t:diffundo_history_seq_cur` go away. The
  pane reads the source's state directly because it never owns the cursor.
- `spec/fakevim.lua` and `types/vim.lua` need autocmds, window-relative floats,
  border title/footer, and `b:changedtick`.
- The rendered-tree goldens (`make gen`, `spec/history_spec.lua`,
  `tests/e2e/`) change format: `#seq` replaces the relative-time column,
  pips replace `○ ◉ ●`, and gap rows replace the `+N states` fold captions.
