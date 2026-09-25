# History Panel Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the diffundo history sidebar into a tree gutter + preview + right-aligned-time layout with vim-folded same-branch runs and a two-line footer.

**Architecture:** `history.lua` becomes the pure layout engine (rows → `Display`); `sidebar.lua` orchestrates rendering, folds, highlighting, and keymaps; `label.lua` gains a compact timer; `fakevim.lua` and `types/vim.lua` grow the new API surface. Independent tracks: (T1) fake+types, (T2) label short-time, (T3→T4) history engine, (T5→T7) sidebar/e2e/docs.

**Tech Stack:** Lua + busted (unit, against a hand-rolled `fakevim` fake, never launching nvim), deno + denops for e2e.

**Spec:** `docs/superpowers/specs/2026-09-23-history-panel-refactor-design.md` and the product design `docs/designs/history-panel/design.md`. The plan argues from the spec; executors read both.

## Parallelization

Dispatch order: **T1, T2, and T3 can start in parallel.** T4 needs T3 (it extends the same files). T5 needs T1 + T4. T6 needs T5. T7 is independent and can run any time. Each task commits on its own; later tasks read the merged tree, so keep commit messages in the repo style (`feat: ...`).

## Global Constraints

- No comments in source. Use `---@param` / `---@return` / `---@class` annotations only, never `---` prose lines.
- Modules return a local table `M`; no globals. `require` calls only at the top of the file.
- Development commands go through the Makefile: `make ci` = busted + selene + stylua --check + ast-grep + lua-language-server + complexity. Set up once with `make setup`.
- Tests never launch neovim. `spec/fakevim.lua` fakes the vim API the plugin uses; when the plugin uses a new part of the API, add it to the fake *and* declare it in `types/vim.lua`.
- In buffer text use ASCII `-` (never the typographic `−`). Box-drawing/unicode glyphs (`│ ┊ ├ ┐ ┬ └ ─`) are fine in layout text.
- One row is one undo change. At most one row in a view shows the current marker (`○`/`◉`).
- Config: `g:diffundo_fold_min` (default `3`), read by the sidebar, passed to `history.display` as `opts.fold_min`. `g:diffundo_history_width` (default 40) already exists.
- Count summaries always use `lines` (a single-line change shows the line itself, so `line` never occurs).

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `lua/diffundo/label.lua` | time formatting | add `short(time)` |
| `lua/diffundo/history.lua` | pure display engine | major changes |
| `lua/diffundo/sidebar.lua` | sidebar orchestration | major changes |
| `lua/diffundo/window.lua` | generic float helper | unchanged |
| `spec/fakevim.lua` | nvim fake | add APIs + fold command |
| `spec/label_spec.lua` | label tests | add `short` tests |
| `spec/history_spec.lua` | display engine tests | rewrite most |
| `spec/sidebar_spec.lua` | sidebar tests | update + extend |
| `spec/init_spec.lua`, `spec/window_spec.lua` | integration bits | update float-line/cursor asserts |
| `types/vim.lua` | type stubs | add api/wo fields |
| `tests/e2e/diffundo_test.ts` | e2e | update + add fold/g? tests |
| `README.md` | user docs | describe new layout, `g:diffundo_fold_min`, `g?` |

---

### Task 1: Extend the fake and the types

**Files:**
- Modify: `spec/fakevim.lua`
- Modify: `types/vim.lua`

**Interfaces:**
- Produces: the fake exposes `vim.api.nvim_create_namespace`, `vim.api.nvim_buf_add_highlight`, `vim.api.nvim_buf_clear_namespace`, `vim.api.nvim_buf_call`, and `vim.cmd` supports `N,Mfold` / `%delfold`. `self.highlights` and `self.folds` record state for the sidebar tests. `vim.wo.foldlevel`/`vim.wo.foldtext` ride the existing option proxy, so they work without extra fake code.

- [ ] **Step 1: Add API fakes**

In `Fake.new` (`spec/fakevim.lua`, around line 336), after the other `self.*` lists:

```lua
self.highlights = {}
self.folds = {}
```

In `api(self)`, after `nvim_buf_delete`, add:

```lua
nvim_create_namespace = function(name)
  return name
end,
nvim_buf_add_highlight = function(buf, ns, hl, line, col_start, col_end)
  self.highlights[#self.highlights + 1] = {
    buf = buf,
    ns = ns,
    hl = hl,
    line = line,
    col_start = col_start,
    col_end = col_end,
  }
end,
nvim_buf_clear_namespace = function()
  self.highlights = {}
end,
nvim_buf_call = function(buf, fn)
  local win = window_of_buffer(self, buf)
  local saved = self.current_win
  if win then
    self.current_win = win
  end
  local ok, err = pcall(fn)
  self.current_win = saved
  if not ok then
    error(err, 0)
  end
end,
```

- [ ] **Step 2: Teach the command parser ranges + `fold`/`delfold`**

Replace `run_command` in `spec/fakevim.lua`:

```lua
---@param self table
---@param command string
local function run_command(self, command)
  table.insert(self.commands, command)
  local stripped = command:gsub("^silent ", "")
  local head, rest = stripped:match("^(%S+)%s*(.*)$")
  local range_first, range_last
  local name = head:match("^(%d+),(%d+)%a+$")
  if name then
    range_first, range_last, head = head:match("^(%d+),(%d+)(%a+)$")
  else
    head = head:match("^%%(%a+)$") and head:sub(2) or head
    if head == "delfold" then
      range_first, range_last = 1, -1
    end
  end
  local handler = commands(self)[head]
  if handler == nil then
    error("unsupported command: " .. command, 0)
  end
  handler(rest, range_first, range_last)
end
```

Add to `commands(self)`:

```lua
fold = function(_, first, last)
  self.folds[#self.folds + 1] = { first = tonumber(first), last = tonumber(last) }
end,
delfold = function()
  self.folds = {}
end,
```

Existing handlers keep their `(rest)` signature; Lua ignores extra args.

- [ ] **Step 3: Declare the new API in `types/vim.lua`**

Under `---@class vim.api`, add:

```lua
---@field nvim_create_namespace fun(name: string): integer
---@field nvim_buf_add_highlight fun(buffer: integer, ns_id: integer, hl_group: string, line: integer, col_start: integer, col_end: integer)
---@field nvim_buf_clear_namespace fun(buffer: integer, ns_id: integer)
---@field nvim_buf_call fun(buffer: integer, fn: fun())
```

Under `---@class vim.wo`, add `foldlevel integer` and `foldtext string` (keep the existing `foldmethod string`).

- [ ] **Step 4: Add fake-behavior tests to `spec/window_spec.lua`**

Append a new describe block:

```lua
describe("fake: highlight and fold APIs", function()
  it("records highlights and clears the namespace", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
    local ns = vim.api.nvim_create_namespace("diffundo")
    vim.api.nvim_buf_add_highlight(vim.source_bn, ns, "DiffAdd", 0, 2, 5)
    vim.api.nvim_buf_add_highlight(vim.source_bn, ns, "Bold", 1, 0, 10)
    assert.are.equal(2, #vim.highlights)

    vim.api.nvim_buf_clear_namespace()

    assert.are.equal(0, #vim.highlights)
  end)

  it("records fold and delfold commands", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
    vim.cmd("4,9fold")
    assert.are.same({ { first = 4, last = 9 } }, vim.folds)

    vim.cmd("%delfold")
    assert.are.same({}, vim.folds)
  end)

  it("nvim_buf_call runs with the buffer's window current", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {})
    assert.are_not.equal(win, vim.current_win)

    local seen
    vim.api.nvim_buf_call(buf, function()
      seen = vim.current_win
    end)

    assert.are.equal(win, seen)
  end)
end)
```

- [ ] **Step 5: Run, lint, commit**

Run: `make test` and `make lint` — expected: pass.

```bash
git add spec/fakevim.lua spec/window_spec.lua types/vim.lua
git commit -m "feat: extend the fake and types for the history panel"
```

---

### Task 2: Add a compact timer to `label`

**Files:**
- Modify: `lua/diffundo/label.lua`
- Test: `spec/label_spec.lua`

**Interfaces:**
- Produces: `M.short(time: integer) -> string` — `"now"` for `< 60s`, else `"<N><unit>"` with no `" ago"` suffix (units `m h d w mo y`, largest that fits). Example: `label.short(os.time() - 120)` → `"2m"`. Used by `history` for the time column.

- [ ] **Step 1: Write the failing tests in `spec/label_spec.lua`**

```lua
describe("label.short", function()
  it("compacts the time to a bare unit", function()
    assert.are.equal("now", label.short(os.time()))
    assert.are.equal("2m", label.short(os.time() - 120))
    assert.are.equal("1h", label.short(os.time() - 3600))
    assert.are.equal("3d", label.short(os.time() - 3 * 86400))
    assert.are.equal("2w", label.short(os.time() - 14 * 86400))
    assert.are.equal("4mo", label.short(os.time() - 120 * 86400))
    assert.are.equal("2y", label.short(os.time() - 2 * 365 * 86400))
  end)
end)
```

- [ ] **Step 2: Run to confirm failure**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/label_spec.lua` — expected: FAIL (`label.short` is nil).

- [ ] **Step 3: Implement `M.short`**

`lua/diffundo/label.lua` already has a module-level `spans` table. Add:

```lua
---@param time integer
---@return string
function M.short(time)
  local delta = os.time() - time
  if delta < 60 then
    return "now"
  end
  for _, span in ipairs(spans) do
    local count = math.floor(delta / span[1])
    if count >= 1 then
      return count .. span[2]
    end
  end
  return "now"
end
```

- [ ] **Step 4: Run, lint, commit**

Run: `make test` then `make lint` — expected: pass.

```bash
git add lua/diffundo/label.lua spec/label_spec.lua
git commit -m "feat: add a compact time formatter for the sidebar"
```

---

### Task 3: History row model, previews, and time column

**Files:**
- Modify: `lua/diffundo/history.lua`
- Test: `spec/history_spec.lua`

**Interfaces:**
- Consumes: `label.short(time)` (Task 2).
- Produces:
  - `diffundo.Row` gains `parent` (set in `row_for` from `step.parent`; the `older` sentinel gets `parent = 0`).
  - `M.preview_parts(row) -> text, spans` — `spans` are `{ hl, from, to }` with 0-based `from` (inclusive) / `to` (exclusive) offsets into `text`. Single add → `"+ <line>"`, whole-text `DiffAdd` span; single remove → `"- <line>"`, `DiffDelete`; otherwise counts: nonzero `+N`/`-M` parts + `lines` (e.g. `"+2 -1 lines"`, `"-3 lines"`), each `+N`/`-M` part colored.
  - `M.time_width(view) -> integer` = `max(#label.short(row.time) over rows) + 1`.

- [ ] **Step 1: Update the row model**

In `lua/diffundo/history.lua`, update the `diffundo.Row` class annotation and the sentinel:

```lua
---@class diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]
---@field removed string[]
---@field parent integer
---@field label string

local older = {
  seq = 0,
  time = 0,
  save = nil,
  added = {},
  removed = {},
  parent = 0,
  label = "",
}
```

In `M.row_for`, add `parent = step.parent`.

- [ ] **Step 2: Write the failing tests in `spec/history_spec.lua`**

Add these describes (keep the existing `row_for`/`rows`/`next`/`filtered` blocks):

```lua
describe("history.preview_parts", function()
  local function row(over)
    local base = { seq = 4, time = 1004, save = nil, added = {}, removed = {}, parent = 3 }
    for key, value in pairs(over or {}) do
      base[key] = value
    end
    return base
  end

  it("shows a single added line colored DiffAdd", function()
    local text, spans = history.preview_parts(row({ added = { "foo()" } }))

    assert.are.equal("+ foo()", text)
    assert.are.equal("DiffAdd", spans[1].hl)
    assert.are.equal("+ foo()", text:sub(spans[1].from + 1, spans[1].to))
  end)

  it("shows a single removed line colored DiffDelete", function()
    local text, spans = history.preview_parts(row({ removed = { "bar()" } }))

    assert.are.equal("- bar()", text)
    assert.are.equal("DiffDelete", spans[1].hl)
  end)

  it("shows counts with the lines unit for mixed changes", function()
    local text, spans = history.preview_parts(row({ added = { "a", "b" }, removed = { "c" } }))

    assert.are.equal("+2 -1 lines", text)
    assert.are.equal("DiffAdd", spans[1].hl)
    assert.are.equal("DiffDelete", spans[2].hl)
  end)

  it("omits zero sides and pluralises", function()
    assert.are.equal("-3 lines", history.preview_parts(row({ removed = { "a", "b", "c" } })))
    assert.are.equal("+2 lines", history.preview_parts(row({ added = { "a", "b" } })))
  end)
end)

describe("history.time_width", function()
  it("sizes the time column to the longest row", function()
    local view = {
      { seq = 3, time = os.time() - 2 * 86400 },
      { seq = 2, time = os.time() - 120 },
    }

    assert.are.equal(3, history.time_width(view))
  end)
end)
```

- [ ] **Step 3: Run to confirm failure**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/history_spec.lua` — expected: FAIL (`preview_parts`/`time_width` nil).

- [ ] **Step 4: Implement the piece-builders**

Remove the old `preview_for` local (`~ N added, M removed` format) and add:

```lua
---@param row diffundo.Row
---@return string, { hl: string, from: integer, to: integer }[]
local function preview_parts(row)
  local a, r = #row.added, #row.removed
  if a == 1 and r == 0 then
    local text = "+ " .. row.added[1]
    return text, { { hl = "DiffAdd", from = 0, to = #text } }
  end
  if a == 0 and r == 1 then
    local text = "- " .. row.removed[1]
    return text, { { hl = "DiffDelete", from = 0, to = #text } }
  end
  local names = {}
  if a > 0 then
    names[#names + 1] = "+" .. a
  end
  if r > 0 then
    names[#names + 1] = "-" .. r
  end
  if #names == 0 then
    names[#names + 1] = "+0"
  end
  names[#names + 1] = "lines"
  local text = table.concat(names, " ")
  local spans = {}
  local col = 0
  for _, name in ipairs(names) do
    local hl = name:sub(1, 1) == "+" and "DiffAdd" or (name:sub(1, 1) == "-" and "DiffDelete")
    if hl then
      spans[#spans + 1] = { hl = hl, from = col, to = col + #name }
    end
    col = col + #name + 1
  end
  return text, spans
end

---@param view diffundo.Row[]
---@return integer
function M.time_width(view)
  local longest = 1
  for _, row in ipairs(view) do
    longest = math.max(longest, #label.short(row.time))
  end
  return longest + 1
end

function M.preview_parts(row)
  return preview_parts(row)
end
```

`label` is already required at the top of `history.lua`.

- [ ] **Step 5: Run, lint, commit**

Run `make test` (history tests pass, including new ones), then `make lint`.

```bash
git add lua/diffundo/history.lua spec/history_spec.lua
git commit -m "feat: add history preview parts and time column sizing"
```

---

### Task 4: History topology, gutter, folds, footer, and `display`

**Files:**
- Modify: `lua/diffundo/history.lua`
- Test: `spec/history_spec.lua`

**Interfaces:**
- Consumes: Task 3's `preview_parts`/`time_width`, `label.short`.
- Produces:
  - `M.display(view, opts) -> diffundo.Display` with `opts = { current?, width, selected?, total?, fold_min? }`.
  - `diffundo.Display = { lines: string[], spans: diffundo.Span[], folds: diffundo.Fold[], row_to_line: integer[], footer_start: integer }`.
  - `diffundo.Span = { line: integer (0-based buffer line), hl: string, col_start: integer (0-based, inclusive), col_end: integer (0-based, exclusive) }`.
  - `diffundo.Fold = { start: integer, stop: integer }` (1-based buffer line range, caption first).

**Layout rules (from the spec; tests pin them):**
- Topology: `depth[1] = 1`. For `i > 1`, `depth[i] = depth[i-1]` when `view[i-1].parent == view[i].seq` (the list walks newest→oldest, so this is a same-branch run step) else `depth[i] = depth[i-1] + 1` (a new lane opens; lanes never close). `children[parent_index]` collects every row whose `parent == view[parent_index].seq`.
- Gutter per row: `depth - 1` outer cells, each `┊` (dashed, a lane the row passes under). The innermost cell is: a fork junction when the row has ≥ 2 children (`├` + `┬` for each arm before the last + `┐` for the last); else `└` when the row is the last in the view; else the glyph (`◉` current+saved, `○` current, `●` saved, `│` plain).
- Preview fills between gutter and a right-aligned time column (`time_width`), truncating with `…` (single char) if it would collide.
- A fold run = maximal consecutive same-branch rows of length ≥ `opts.fold_min`; it renders as a **caption line** (first buffer line of the fold) followed by the run's rows. Caption text: `+<N> states: +<A> -<R> lines <N> undos`. Caption gutter mirrors the run's lane.
- Footer: a `────…` divider, then line 1 `#<seq>  <meaning>  <absolute time>  <preview counts>`, then line 2 `<shown>/<total>` left + right-aligned `help: g?`. `<meaning>` = `◉ saved` / `○` / `● saved` / empty.

- [ ] **Step 1: Write the failing `display` tests**

Add a `describe("history.display", ...)` block to `spec/history_spec.lua`:

```lua
describe("history.display", function()
  local function row(over)
    local base = { seq = 4, time = os.time() - 120, save = nil, added = {}, removed = {}, parent = 3 }
    for key, value in pairs(over or {}) do
      base[key] = value
    end
    return base
  end

  it("renders a linear chain with flat gutters and right-aligned time", function()
    local rows = {
      row({ seq = 3, parent = 2, time = os.time() - 120, added = { "foo()" } }),
      row({ seq = 2, parent = 1, time = os.time() - 240 }),
      row({ seq = 1, parent = 0, time = os.time() - 300 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│%+ foo%(%)", display.lines[1])
    assert.matches("2m$", display.lines[1])
    assert.matches("^│", display.lines[2])
    assert.matches("^└", display.lines[3])
    assert.are.same({ 1, 2, 3 }, display.row_to_line)
  end)

  it("marks the diff's state with the current glyph", function()
    local rows = {
      row({ seq = 2, parent = 1, save = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { current = 2, width = 30 })

    assert.matches("^◉", display.lines[1])
    assert.matches("^└", display.lines[2])
  end)

  it("nests a lane on a branch switch and draws the fork junction", function()
    local rows = {
      row({ seq = 4, parent = 2 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│", display.lines[1])
    assert.matches("^┊│", display.lines[2])
    assert.matches("^┊├┐", display.lines[3])
    assert.matches("^┊└", display.lines[4])
  end)

  it("renders a saved alternate with the ● glyph on the dashed lane", function()
    local rows = {
      row({ seq = 4, parent = 2 }),
      row({ seq = 3, parent = 1, save = 1, added = { "x" } }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│", display.lines[1])
    assert.matches("^┊●", display.lines[2])
  end)

  it("folds a long same-branch run into a caption and a vim fold", function()
    local rows = {
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30, fold_min = 3 })

    assert.matches("%+5 states: %+0 %-0 lines 5 undos", display.lines[1])
    assert.are.same({ { start = 1, stop = 5 } }, display.folds)
    assert.are.same({ 2, 3, 4, 5, 6 }, display.row_to_line)
  end)

  it("appends the footer under a divider", function()
    local rows = { row({ seq = 2, parent = 1 }), row({ seq = 1, parent = 0 }) }
    local display = history.display(rows, { width = 30, selected = 1, total = 4 })

    assert.are.equal(3, display.footer_start)
    assert.matches("^%-%-%-", display.lines[3])
    assert.matches("^#2", display.lines[4])
    assert.matches("2/4", display.lines[5])
    assert.matches("help: g%?$", display.lines[5])
  end)
end)
```

- [ ] **Step 2: Run to confirm failure**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/history_spec.lua -p display -v` — expected: FAIL (`history.display` nil).

- [ ] **Step 3: Implement `display` and its builders**

Add to `history.lua` after `M.preview_parts`. First the topology and gutter helpers:

```lua
---@param view diffundo.Row[]
---@return integer[], integer[][]
local function topology_for(view)
  local seq_index = {}
  for i, r in ipairs(view) do
    seq_index[r.seq] = i
  end
  local depth = { 1 }
  local children = {}
  for i = 2, #view do
    if view[i - 1].parent == view[i].seq then
      depth[i] = depth[i - 1]
    else
      depth[i] = depth[i - 1] + 1
    end
    local parent = seq_index[view[i].parent]
    if parent then
      children[parent] = children[parent] or {}
      table.insert(children[parent], i)
    end
  end
  return depth, children
end

---@param i integer
---@param depth integer
---@param children integer[][]
---@param last integer
---@param is_current boolean
---@param save boolean
---@return string
local function gutter_for(i, depth, children, last, is_current, save)
  local kids = children[i] or {}
  local cells = {}
  for c = 1, depth - 1 do
    cells[c] = "┊"
  end
  if #kids >= 2 then
    for k = 1, #kids - 1 do
      cells[depth + k - 1] = k < #kids - 1 and "┬" or "┐"
    end
    cells[depth] = "├"
  elseif i == last then
    cells[depth] = "└"
  else
    local glyph = is_current and (save and "◉" or "○") or (save and "●" or "│")
    cells[depth] = glyph
  end
  return table.concat(cells, "")
end
```

Then the row-line assembler:

```lua
---@param view diffundo.Row[]
---@param i integer
---@param depth integer[]
---@param children integer[][]
---@param time_w integer
---@param width integer
---@param current integer|nil
---@return string, diffundo.Span[]
local function row_line(view, i, depth, children, time_w, width, current)
  local r = view[i]
  local gutter = gutter_for(i, depth[i], children, #view, r.seq == current, r.save ~= nil)
  local preview, marks = preview_parts(r)
  local time = label.short(r.time)
  local body_w = width - #gutter - time_w
  if #preview > body_w then
    preview = preview:sub(1, body_w - 1) .. "…"
    marks = {}
  end
  local line = gutter
    .. preview
    .. string.rep(" ", body_w - #preview)
    .. string.rep(" ", time_w - #time)
    .. time
  local spans = {}
  local base = #gutter
  for _, mark in ipairs(marks) do
    spans[#spans + 1] = {
      line = 0,
      hl = mark.hl,
      col_start = base + mark.from,
      col_end = base + mark.to,
    }
  end
  return line, spans
end
```

The caption and footer builders:

```lua
---@param view diffundo.Row[]
---@param first integer
---@param count integer
---@param depth integer[]
---@param time_w integer
---@param width integer
---@return string
local function caption_for(view, first, count, depth, time_w, width)
  local added, removed = 0, 0
  for offset = 0, count - 1 do
    added = added + #view[first + offset].added
    removed = removed + #view[first + offset].removed
  end
  local text = string.format(
    "+%d states: +%d -%d lines %d undos",
    count,
    added,
    removed,
    count
  )
  local gutter = gutter_for(first, depth[first], {}, #view, false, false)
  local time = label.short(view[first].time)
  local body_w = width - #gutter - time_w
  if #text > body_w then
    text = text:sub(1, body_w - 1) .. "…"
  end
  return gutter
    .. text
    .. string.rep(" ", body_w - #text)
    .. string.rep(" ", time_w - #time)
    .. time
end

---@param view diffundo.Row[]
---@param opts { selected?: integer, total?: integer }
---@param width integer
---@return string[]
local function footer_lines(view, opts, width)
  local index = opts.selected and math.max(1, math.min(opts.selected, #view)) or 1
  local r = view[index]
  local meaning = r.save and "● saved" or ""
  local absolute = os.date("%Y-%m-%d %I:%M:%S %p", r.time)
  local preview, _ = preview_parts(r)
  local shown = #view
  local total = opts.total or shown
  local line1 = ("#%d %s %s %s"):format(r.seq, meaning, absolute, preview)
  if #line1 > width then
    line1 = line1:sub(1, width)
  end
  local hint = "help: g?"
  local line2 = ("%d/%d"):format(shown, total)
  line2 = line2 .. string.rep(" ", math.max(0, width - #line2 - #hint)) .. hint
  return { line1, line2 }
end
```

Finally `M.display`:

```lua
---@param view diffundo.Row[]
---@param opts { current?: integer, width: integer, selected?: integer, total?: integer, fold_min?: integer }
---@return diffundo.Display
function M.display(view, opts)
  local width = opts.width
  local depth, children = topology_for(view)
  local time_w = M.time_width(view)
  local fold_min = opts.fold_min or 3
  local lines = {}
  local spans = {}
  local folds = {}
  local row_to_line = {}

  local buf = 1
  local i = 1
  while i <= #view do
    local run_end = i
    while run_end < #view and view[run_end].parent == view[run_end + 1].seq do
      run_end = run_end + 1
    end
    local run_len = run_end - i + 1
    if run_len >= fold_min then
      local caption = caption_for(view, i, run_len, depth, time_w, width)
      lines[buf] = caption
      local fold_start = buf
      buf = buf + 1
      for index = i, run_end do
        row_to_line[index] = buf
        local text, row_spans = row_line(view, index, depth, children, time_w, width, opts.current)
        lines[buf] = text
        for _, span in ipairs(row_spans) do
          span.line = buf - 1
          spans[#spans + 1] = span
        end
        buf = buf + 1
      end
      folds[#folds + 1] = { start = fold_start, stop = buf - 1 }
      i = run_end + 1
    else
      row_to_line[i] = buf
      local text, row_spans = row_line(view, i, depth, children, time_w, width, opts.current)
      lines[buf] = text
      for _, span in ipairs(row_spans) do
        span.line = buf - 1
        spans[#spans + 1] = span
      end
      buf = buf + 1
      i = i + 1
    end
  end

  lines[buf] = string.rep("-", width)
  local footer_start = buf
  buf = buf + 1
  for _, line in ipairs(footer_lines(view, opts, width)) do
    lines[buf] = line
    buf = buf + 1
  end

  return {
    lines = lines,
    spans = spans,
    folds = folds,
    row_to_line = row_to_line,
    footer_start = footer_start,
  }
end
```

Note: `display` calls `caption_for(view, i, run_len, depth, time_w, width)` (signature matches the builder above).

- [ ] **Step 4: Run, verify, commit**

Run `make test` and `make lint`. All `history` tests must pass, including the six new ones. (Note: the fold test's chained fixture produces a single run of 5 — the whole chain folds, so the caption counts `+0 -0 lines` because no row carries added/removed; that matches the assertion.)

```bash
git add lua/diffundo/history.lua spec/history_spec.lua
git commit -m "feat: build the history display layout with folds and footer"
```

---

### Task 5: Sidebar orchestration

**Files:**
- Modify: `lua/diffundo/sidebar.lua`
- Test: `spec/sidebar_spec.lua`, `spec/init_spec.lua`

**Interfaces:**
- Consumes: `history.display` (Task 4), Task 1's fake APIs.
- Produces: `sidebar.open/close/toggle/place/move_save/filter/reveal` keep their signatures. The float renders from `history.display`; cursor↔view-index translation happens through the stored `vim.t.diffundo_history_display.row_to_line`.

- [ ] **Step 1: Add the render/fold/select helpers**

In `sidebar.lua`, replace `rendered_lines()` with these locals:

```lua
---@return integer|nil
local function current_index()
  return index_of_seq(vim.t.diffundo_diff_undonr)
end

---@param line integer
---@return integer
local function index_at_line(line)
  local display = vim.t.diffundo_history_display
  if display == nil then
    return line
  end
  for index, target in ipairs(display.row_to_line) do
    if target == line then
      return index
    end
  end
  return line
end

local history_ns

local function render_float()
  local float = win()
  if float == nil or not window.is_open(float) then
    return
  end
  local view = vim.t.diffundo_history_view
  local display = history.display(view, {
    current = vim.t.diffundo_diff_undonr,
    width = vim.g.diffundo_history_width or 40,
    selected = current_index(),
    total = #rows(),
    fold_min = vim.g.diffundo_fold_min or 3,
  })
  vim.t.diffundo_history_display = display
  local buf = vim.api.nvim_win_get_buf(float)
  window.render(float, display.lines)
  if history_ns == nil then
    history_ns = vim.api.nvim_create_namespace("diffundo_history")
  end
  vim.api.nvim_buf_clear_namespace(buf, history_ns)
  for _, span in ipairs(display.spans) do
    vim.api.nvim_buf_add_highlight(buf, history_ns, span.hl, span.line, span.col_start, span.col_end)
  end
  vim.api.nvim_buf_call(buf, function()
    vim.bo.foldmethod = "manual"
    vim.cmd("%delfold")
    for _, fold in ipairs(display.folds) do
      vim.cmd(fold.start .. "," .. fold.stop .. "fold")
    end
    vim.wo.foldlevel = 0
    vim.wo.foldtext = "getline(v:foldstart)"
  end)
end
```

Remove `rendered_lines`. (`rows()` — the unfiltered list for `total` — still exists; `view()` still exists.)

- [ ] **Step 2: Rewire the cursor-using methods**

`select_row` now goes through `row_to_line`:

```lua
---@param seq integer|nil
local function select_row(seq)
  local index = index_of_seq(seq)
  local float = win()
  if index and float then
    local display = vim.t.diffundo_history_display
    local line = display and display.row_to_line[index] or index
    vim.api.nvim_win_set_cursor(float, { line, 0 })
  end
end
```

`row_at` (used by `M.place`) translates the cursor line back:

```lua
---@param float integer|nil
---@return diffundo.Row|nil
local function row_at(float)
  local index = index_at_line(vim.api.nvim_win_get_cursor(float)[1])
  local row = view()[index]
  if row == nil or row.seq == 0 then
    return nil
  end
  return row
end
```

In `M.open`, after the existing key mappings and before `select_row(...)`, call `render_float()`. `M.open` already builds `vim.t.diffundo_history_view` from `history.rows({})`.

`M.move_save` — replace the cursor-line read with the index, then move the cursor through `row_to_line`:

```lua
function M.move_save(dir)
  local float = win()
  if float == nil or not window.is_open(float) then
    return
  end
  local index = index_at_line(vim.api.nvim_win_get_cursor(float)[1])
  local moved = history.next(view(), index, { dir = dir, written = true })
  if moved ~= index then
    local display = vim.t.diffundo_history_display
    local line = display and display.row_to_line[moved] or moved
    vim.api.nvim_win_set_cursor(float, { line, 0 })
  end
end
```

`M.place` — after `split.place(...)` and before refocusing the float, call `render_float()` (so the `○`/`◉` marker follows the newly diffed state).

`M.filter` — after computing the new `vim.t.diffundo_history_view`, call `render_float()` instead of `window.render(float, rendered_lines())`.

`M.reveal` — after resetting the filter/view, call `render_float()` instead of `window.render(float, rendered_lines())`.

`M.close` — add `vim.t.diffundo_history_display = nil` beside the other state clears.

- [ ] **Step 3: Add the `g?` hint**

In `M.open`, after the other `window.map` calls:

```lua
window.map(float, "g?", function()
  vim.notify("J/K saved jumps · <cr> place · / filter · g? help · q close")
end)
```

- [ ] **Step 4: Add/update tests**

Add to `spec/sidebar_spec.lua`:

```lua
describe("sidebar layout integration", function()
  it("renders via history.display with a footer", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()

    local buf = vim.buffers[vim.windows[float_win(vim)].buf]
    assert.is_not_nil(vim.t.diffundo_history_display)
    assert.are.equal(#vim.t.diffundo_history_display.lines, #buf.lines)
    assert.matches("help: g?", buf.lines[#buf.lines])
  end)

  it("creates manual folds for long runs and collapses them", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" }, { "a", "b", "c", "d" } }))
    vim:install()
    sidebar.open()

    assert.are.equal(1, #vim.folds)
    assert.are.equal(0, vim.windows[float_win(vim)].options.foldlevel)
  end)

  it("applies the highlight spans", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()

    assert.is_true(#vim.highlights > 0)
  end)

  it("g? notifies the key list", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()
    vim:press("g?")

    assert.matches("saved jumps", vim:last_notification())
  end)
end)
```

The existing `history()` helper (3 states) has no run ≥ 3, so the folds test builds a 5-state history inline, as above.

Update the existing sidebar/init tests that assert float buffer line counts or the old preview text (`[saved]`, `~ N added, M removed`) to the new layout. These show up as failures in `make test`; fix them by expecting the new rows (gutter + preview + time) and counting the extra footer/divider lines. In `spec/init_spec.lua`, tests that assert the history float's cursor (`vim.windows[vim.t.diffundo_history_win].cursor`) survive; any `#buf.lines` counts need the footer added (`rows + 3`).

- [ ] **Step 5: Run, fix, commit**

Run `make test`; fix fallout across `sidebar_spec`/`init_spec`/`window_spec`. Then `make lint` and `make type`.

```bash
git add lua/diffundo/sidebar.lua spec/sidebar_spec.lua spec/init_spec.lua
git commit -m "feat: wire the sidebar to the display layout, folds, and g? help"
```

---

### Task 6: End-to-end test updates

**Files:**
- Modify: `tests/e2e/diffundo_test.ts`

- [ ] **Step 1: Fix the float-line assertions**

In the `:Diffundo history` toggle test, replace `assert(lines[0].includes("- 2"), lines[0])` with a footer check:

```ts
const blob = lines.join("\n");
assert(blob.includes("#2"), blob);
```

`assertHistory` keeps its exact-lines self-comparison; `assertDiffSplit` needs no float-line changes.

- [ ] **Step 2: Add a fold e2e test**

```ts
test({
  mode: "nvim",
  name: "a long same-branch run folds into a caption and zo unfolds it",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
      ["one", "two", "three", "four"],
    ]);

    await denops.cmd("Diffundo history");

    const wins = await winIds(denops);
    const floats: number[] = [];
    for (const w of wins) {
      if (await isFloat(denops, w)) floats.push(w);
    }
    assertEquals(floats.length, 1);
    const buf = await denops.call("nvim_win_get_buf", floats[0]) as number;
    const all = await denops.call("nvim_buf_get_lines", buf, 0, -1, false) as string[];
    const caption = all.findIndex((l) => /states:/.test(l));
    assert(caption >= 0, all.join("\n"));
    const captionLine = caption + 1;

    assertEquals(await denops.call("foldclosed", captionLine), captionLine);
    await denops.cmd(`${captionLine}normal! zo`);
    assertEquals(await denops.call("foldclosed", captionLine), -1);
  },
});
```

- [ ] **Step 3: Add a `g?` e2e assertion**

In the `moving in the history ... <cr>` test, after the float is focused (the first `assertEquals` on `[line('.'), col('.')]`), append:

```ts
await denops.call("feedkeys", "g?", "x");
const hint = await denops.call("execute", "messages") as string;
assert(hint.includes("saved jumps"), hint);
await denops.cmd("messages clear");
```

- [ ] **Step 4: Run the full suite, commit**

Run: `make e2e` — expected: all pass.

```bash
git add tests/e2e/diffundo_test.ts
git commit -m "test: cover folds and the g? hint in the e2e suite"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README**

In the `:Diffundo history` paragraph, describe: the tree gutter with branch lanes (`│` active, `┊` ancestors) and glyphs (`○`/`◉` current, `●` saved), the preview + right-aligned relative time, and vim-fold runs collapsed by default (`zo`/`zc`). Document `g:diffundo_fold_min` (default 3) next to `g:diffundo_history_width`, and mention `g?` shows the key list from the sidebar.

- [ ] **Step 2: Verify nothing references the old format**

Grep `spec/`, `lua/`, `README.md` for `[saved]` and `rendered_lines`; update README wording that mentions the old row format.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe the tree-gutter history panel and fold config"
```

---

## Self-Review Checklist

Run this after writing the plan (not during execution):

- [ ] **Spec coverage:** `Target behavior` bullets → tasks: depth/glyphs (T4), previews/units (T3), time column (T3/T4), folds (T4/T5), footer (T4), `g?` (T5), config (T4/T5/T7), fake/types (T1), e2e (T6).
- [ ] **Placeholder scan:** no TBD/TODO; every step carries concrete code; no leftover "the executor fixes P" commentary.
- [ ] **Type consistency:** `diffundo.Display`/`Span`/`Fold`, `row_to_line`, `footer_start`, `preview_parts`, `time_width`, `label.short` names match across all tasks.