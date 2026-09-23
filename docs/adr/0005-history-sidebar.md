# 5. Floating history sidebar with strict <cr> display

Date: 2026-09-22

## Status

Accepted

## Context

The roadmap (issue #8, sub-project 3) wants a mundo-style undo list. The core
(ADR 4) is a cursor-neutral Lua API over a tree-aware walker; the front-end
must not disturb it. An in-session "live, throttled" diff update idea was
rejected: it added timers and placed a diff behind every keystroke for no win
over inline previews.

## Decision

**A floating, focusable list** (sidebar.lua over a hand-rolled window.lua on
nvim_open_win; no UI library — one float needs a third of nui.nvim and the
faked vim surface stays honest). **The diff opens and changes only on <cr>**;
cursor moves never touch it. **Commands open the float by default**; a leading
-no-history flag or g:diffundo_history=false keeps the minimal layout;
:Diffundo history toggles it standalone. **history.lua computes the rows**
(rows over the walker; pure render/next/filtered), so a telescope picker or
quickfix list can render the same list later. The float takes focus when it
opens; :only fails while it is open (verified). The row.label slot carries the
state label; RCS shas/tags (sub-project 2) drop into it without interface
change.

## Consequences

- Commands have a richer default; scripts and the e2e suite pass -no-history.
- The sidebar is coupled to the diff split at the command layer only; API
  users never see the float.
- The fake models floats, buffer-local keymaps (fake:press) and vim.input;
  e2e detects floats via nvim_win_get_config().relative.
- Walking the whole history per float open is finite (the limit cap and the
  …older… sentinel); the ADR-4 memoisation remains the measured fallback.