# History panel — Design

**Project:** vim-diffundo
**Status:** layouts approved — implementation spec written
**Architecture:** docs/superpowers/specs/2026-09-23-history-panel-refactor-design.md
**Last updated:** 2026-09-23

## Goal

A keyboard-first floating panel that browses the current buffer's undo states
and picks one to show in the diff split. Users are nvim power users: they scan
a compact list (time, what changed), filter it, and confirm a state with
`<cr>` to diff against it. The panel lives in the upper right of the editor,
replacing the current flat one-line-per-state float.

**Assumptions (state now, revise when answered):**
- Keyboard-first; mouse is not a primary interaction.
- Panel is a neovim floating window, roughly 40–60 columns.
- Rows are seeded by `require("diffundo.history").rows` (seq, time, save,
  added, removed, label); moving over a row and `<cr>` places that state in
  the diff split (the current "strict-`<cr>`" model).
- Existing keys keep working: `J`/`K` written-only moves, `/` filter,
  `q`/`<esc>` close.

## Directions considered

### Compact picker — chosen scope

The panel stays a single flat list of undo states; the diff split remains the
detail view. Directions below differ only in how the float itself is laid out.

### Direction A — "The tucked list" (today's layout, cleaned)

```
[source] ──:Diffundo──▶ [panel: rows] ──<cr>──▶ [diff split]
                            ▲   │
                            └───┘  J/K, /filter
Row = relative time + change preview + seq, one line, no chrome.
```

Why: zero overhead, every line is a row. Trade-off: the float leans on the
winbar label for context and the seq is fused into the row's time text.

### Direction B — "Selected state in a footer"

```
[source] ──:Diffundo──▶ [panel: rows + footer] ──<cr>──▶ [diff split]
                             ▲      │
                             └──────┘  J/K / filter, footer tracks the selection
Rows = relative time + change preview; footer = seq · absolute time ·
[saved] marker of the selected state.
```

Why: frees row width for the preview, surfaces the selection's identity, and
echoes an active filter inline. Trade-off: one non-row line at the bottom.

### Direction C — "Banded columns"

```
[source] ──:Diffundo──▶ [panel: header + banded rows] ──<cr>──▶ [diff split]
                                   ▲       │
                                   └───────┘  J/K / filter, columns never shift
time | change | seq as fixed-width, aligned columns under a header row.
```

Why: table-style scanning, stable columns. Trade-off: on a ~40-col float the
preview column truncates hard and a header line costs vertical space.

## Screens

### 1. History panel

Direction B, refined: rows show the tree node, the change preview and a
right-aligned relative time; long linear runs fold into one row; a footer
carries the rest — no panel border, one `────` divider before the footer.
Terminal-widths side by side in place of mobile/desktop; mockups are hand-drawn
ASCII, so widths are approximate.

```
 NARROW (~40)                            WIDE (~60)
○  + foo(); a = b                1m      ○  + foo() { a; b }  pass 0 of 3          1m
├  +2 −1                          3m     ├  +2 −1                                  3m
│  +-- 9 states: +5 −3 9 undos   12m     │  +-- 9 states: +5 −3 9 undos  2h       12m
│  − bar(); refund(): a→b        16m     │  − bar(); refund(): 1 mapped → 2       16m
└◉ + initial file                 2h     └◉ + initial file                         2h
─────────────────────────────────        ─────────────────────────────────────────────
#12  ◉ saved  2026-09-23 09:12  +1 −0    #12  ◉ saved  2026-09-23 09:12:41  +1 −0
3/12                          help: g?   3/12                            help: g?
```

Node shapes and tree edges — one circle communicates the state's meaning;
saved-but-not-current states carry no circle, only bold. Plain states are
unadorned tree lines:

| Shape | Means |
|---|---|
| no glyph (plain edges `│` `├`/`└`) | a plain, unsaved undo state |
| bold text, no circle | a saved state that is not the diff's state |
| `○` | the state the diff split is currently showing |
| `◉` | the diff's state **and** saved |
| `◆` | a branch point / alternate branch tip |
| `+-- 9 states …` | a folded run — a real vim fold region, `zo`/`zc` to open/close |

1. **Winbar** — the float's title row (`diffundo history`), above the list.
2. **Tree gutter** — branch edges; `○`/`◉`/`◆` glyphs only where meaningful,
   bold where saved.
3. **Change preview** — middle column, fills the space and ends with `…` when
   it collides with the time column. One line added/removed shows the line
   (`+ foo()`, `− bar()`); several show just the counts (`+2 −1`, green/red).
4. **Time column** — relative time, right-aligned; the preview truncates
   before reaching it.
5. **Fold row** — consecutive same-branch states are a vim fold region; the
   collapsed header renders as `+-- 9 states: +5 −3 9 undos 12m` (visible
   counts + run length; `zo`/`zc` toggles it, the nvim builtin undotree's
   fold idea).
6. **Footer line 1** — the selected row's full identity: seq, node meaning,
   absolute time, exact `+`/`−` counts.
7. **Footer line 2** — filter hit count `3/12` on the left, `help: g?`
   hint on the right (a key that opens the panel's mappings).

Sketch: [sketches/history-panel.html](sketches/history-panel.html)

## Decisions

_(stage 4 fills this in)_

## Open questions

- _(stage 0 — answered in conversation, then moved out)_