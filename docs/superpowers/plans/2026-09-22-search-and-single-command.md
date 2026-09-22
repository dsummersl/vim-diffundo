# Search and the single `:Diffundo` command — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `:DiffEarlier`/`:DiffLater`/`:DiffSearch` with one `:Diffundo` command whose `search[!]` subcommand walks the undo *tree* through a reusable, cursor-neutral Lua API.

**Architecture:** Three layers. `tree.lua` (pure) turns `vim.fn.undotree()` into states with parents; `walker.lua` iterates them newest-first, running `:undo parent` / `:undo seq` and a multiset line diff to yield what each edit added/removed. `init.lua` exposes `earlier`/`later`/`search` (cursor-neutral, raise errors) and a `command` layer that is the only code allowed to notify, register with vim-repeat, or move the cursor.

**Tech Stack:** Lua (LuaJIT / neovim 0.10+), busted + `spec/fakevim.lua` for unit tests, deno + denops.vim for e2e, selene/stylua/ast-grep/lua-language-server via `make ci`.

**Spec:** `docs/superpowers/specs/2026-09-21-search-and-single-command-design.md`

## Global Constraints

- Neovim 0.10 or newer; no classic Vim.
- No comments in Lua except `---@param`/`---@return`/`---@class`/`---@field` annotations (ast-grep rule `no-comments-lua`). No `---` prose lines.
- `require` calls only at the top of a file (ast-grep rule `no-require-in-function-lua`).
- Modules return a local table `M`; no globals.
- Cyclomatic complexity ≤ 5 per function, functions < 80 lines (`make complexity`).
- lua-language-server strict + type-check diagnostics at error level; every public function annotated; every new `vim` API declared in `types/vim.lua` and modelled in `spec/fakevim.lua`.
- Unit tests never launch neovim. Run a single spec with `eval $(luarocks --tree lua_modules path --bin) && busted spec/<name>_spec.lua`.
- `make ci` must pass at the end of every task. `make e2e` (needs `deno` + `nvim`) at the end of Task 8.
- Commit messages: present-tense third-person subject like the existing history ("Adds …", "Ports …"), ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Only the command layer (`M.command` in `init.lua`) may `vim.notify`, call `repeat#set`, change the current window on return, or set the cursor. `split.open()` keeps its existing "No changes to view!" notify.
- `@/` and the search history are never written.

## File Structure

| File | Responsibility |
|---|---|
| `lua/diffundo/lines.lua` (new) | Pure multiset helpers: `added_lines`, `removed_lines`, `index_of`. Replaces `additions.lua`. |
| `lua/diffundo/tree.lua` (new) | Pure: `undotree()` → `diffundo.State[]` (seq, parent, time, save), descending seq. |
| `lua/diffundo/walker.lua` (new) | Drives the source buffer: lazy iterator of `diffundo.Step` newest-first from behind a seq. |
| `lua/diffundo/cursor.lua` (new) | Pure: where the source cursor lands after a hit. |
| `lua/diffundo/subcommand.lua` (new) | Pure: parse `:Diffundo` args into `{name, bang, rest}`; completion candidates. |
| `lua/diffundo/init.lua` (modify) | Public API `earlier`/`later`/`search` (cursor-neutral, raising); `command`, `repeat_last`. |
| `lua/diffundo/label.lua` (modify) | `diffundo.UndoEntry` gains `save`. |
| `lua/diffundo/additions.lua` (delete) | Superseded by `lines.lua`. |
| `plugin/diffundo.lua` (modify) | One `:Diffundo` command with completion. |
| `spec/fakevim.lua` (modify) | Undo tree (`branch`, nested `alt`, `undo N`), windows with cursors, `vim.regex`. |
| `spec/lines_spec.lua`, `tree_spec.lua`, `walker_spec.lua`, `cursor_spec.lua`, `subcommand_spec.lua` (new), `spec/init_spec.lua` (modify), `spec/additions_spec.lua` (delete) | Unit tests. |
| `types/vim.lua` (modify) | `vim.regex`, cursor/window APIs, `save` on entries. |
| `tests/e2e/diffundo_test.ts` (modify) | `:Diffundo` end to end, including search. |
| `README.md` (modify), `doc/diffundo.txt` (new) | Docs. |

---

### Task 1: `lines.lua` — multiset added/removed/index_of

**Files:**
- Create: `lua/diffundo/lines.lua`
- Create: `spec/lines_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `lines.added_lines(before: string[], after: string[]) -> string[]` — lines of `after` not in `before`, multiset, in `after` order.
  - `lines.removed_lines(before: string[], after: string[]) -> string[]` — lines of `before` not in `after`, multiset, in `before` order.
  - `lines.index_of(lines: string[], line: string) -> integer|nil` — 1-based index of the first equal line.

- [ ] **Step 1: Write the failing spec**

```lua
local lines = require("diffundo.lines")

describe("lines.added_lines", function()
  it("returns lines only present after", function()
    assert.are.same({ "b" }, lines.added_lines({ "a" }, { "a", "b" }))
  end)

  it("counts repeated lines", function()
    assert.are.same({ "x" }, lines.added_lines({ "x" }, { "x", "x" }))
  end)

  it("ignores removed lines", function()
    assert.are.same({}, lines.added_lines({ "a", "b" }, { "a" }))
  end)

  it("keeps the order of the after side", function()
    assert.are.same({ "c", "b" }, lines.added_lines({ "a" }, { "c", "a", "b" }))
  end)
end)

describe("lines.removed_lines", function()
  it("returns lines only present before", function()
    assert.are.same({ "b" }, lines.removed_lines({ "a", "b" }, { "a" }))
  end)

  it("counts repeated lines", function()
    assert.are.same({ "x" }, lines.removed_lines({ "x", "x" }, { "x" }))
  end)

  it("ignores added lines", function()
    assert.are.same({}, lines.removed_lines({ "a" }, { "a", "b" }))
  end)
end)

describe("lines.index_of", function()
  it("finds the first equal line", function()
    assert.are.equal(2, lines.index_of({ "a", "b", "b" }, "b"))
  end)

  it("returns nil when absent", function()
    assert.is_nil(lines.index_of({ "a" }, "b"))
  end)

  it("compares whole lines, not substrings", function()
    assert.is_nil(lines.index_of({ "abc" }, "b"))
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/lines_spec.lua`
Expected: FAIL — `module 'diffundo.lines' not found`.

- [ ] **Step 3: Write the implementation**

```lua
local M = {}

---@param lines string[]
---@return table<string, integer>
local function counts(lines)
  local result = {}
  for _, line in ipairs(lines) do
    result[line] = (result[line] or 0) + 1
  end
  return result
end

---@param pool string[]
---@param candidates string[]
---@return string[]
local function not_in(pool, candidates)
  local remaining = counts(pool)
  local result = {}
  for _, line in ipairs(candidates) do
    if (remaining[line] or 0) > 0 then
      remaining[line] = remaining[line] - 1
    else
      table.insert(result, line)
    end
  end
  return result
end

---@param before string[]
---@param after string[]
---@return string[]
function M.added_lines(before, after)
  return not_in(before, after)
end

---@param before string[]
---@param after string[]
---@return string[]
function M.removed_lines(before, after)
  return not_in(after, before)
end

---@param lines string[]
---@param line string
---@return integer|nil
function M.index_of(lines, line)
  for index, candidate in ipairs(lines) do
    if candidate == line then
      return index
    end
  end
  return nil
end

return M
```

- [ ] **Step 4: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/lines_spec.lua && make ci`
Expected: all PASS, ci green (`additions.lua` still exists and is still used by `init.lua`; it is deleted in Task 6).

- [ ] **Step 5: Commit**

```bash
git add lua/diffundo/lines.lua spec/lines_spec.lua
git commit -m "Adds multiset added/removed line helpers

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `tree.lua` — states with parents from `undotree()`

**Files:**
- Create: `lua/diffundo/tree.lua`
- Create: `spec/tree_spec.lua`
- Modify: `lua/diffundo/label.lua` (the `diffundo.UndoEntry` class, lines 3-6)

**Interfaces:**
- Consumes: `vim.undotree` shape (`entries` with nested `alt`), already declared in `types/vim.lua`.
- Produces:
  - `---@class diffundo.State` with `seq: integer`, `parent: integer`, `time: integer`, `save: integer|nil`.
  - `tree.states(undotree: vim.undotree) -> diffundo.State[]` sorted by seq descending.

Real-nvim shape reminder for fixtures: after states 1, 2, then `:undo 1` and a new edit (seq 3), `undotree().entries` is `{ {seq=1}, {seq=3, alt={ {seq=2} }} }`. A third sibling nests further: `{seq=4, alt={ {seq=3, alt={ {seq=2} }} }}`. An alt chain continues with its own children: `alt = { {seq=2}, {seq=5} }` means 5 is a child of 2.

- [ ] **Step 1: Add `save` to the entry class in `label.lua`**

Replace lines 3-6 of `lua/diffundo/label.lua` with:

```lua
---@class diffundo.UndoEntry
---@field seq integer
---@field time integer
---@field save integer|nil
---@field alt diffundo.UndoEntry[]|nil
```

- [ ] **Step 2: Write the failing spec**

```lua
local tree = require("diffundo.tree")

---@param seq integer
---@param alt table|nil
---@return table
local function entry(seq, alt)
  return { seq = seq, time = 1000 + seq, alt = alt }
end

describe("tree.states", function()
  it("returns nothing for an empty history", function()
    assert.are.same({}, tree.states({ seq_last = 0, seq_cur = 0, entries = {} }))
  end)

  it("chains a linear history from the original text", function()
    local states = tree.states({
      seq_last = 3,
      seq_cur = 3,
      entries = { entry(1), entry(2), entry(3) },
    })

    assert.are.same({
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("gives an alt branch the parent of the entry it hangs off", function()
    local states = tree.states({
      seq_last = 3,
      seq_cur = 3,
      entries = { entry(1), entry(3, { entry(2) }) },
    })

    assert.are.same({
      { seq = 3, parent = 1, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("follows an alt chain and nested alts", function()
    local states = tree.states({
      seq_last = 5,
      seq_cur = 5,
      entries = {
        entry(1),
        entry(4, { entry(3, { entry(2), entry(5) }) }),
      },
    })

    assert.are.same({
      { seq = 5, parent = 2, time = 1005 },
      { seq = 4, parent = 1, time = 1004 },
      { seq = 3, parent = 1, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("keeps the save number", function()
    local states = tree.states({
      seq_last = 1,
      seq_cur = 1,
      entries = { { seq = 1, time = 1001, save = 1 } },
    })

    assert.are.same({ { seq = 1, parent = 0, time = 1001, save = 1 } }, states)
  end)

  it("gives an alt hanging off the first root entry the original text as parent", function()
    local states = tree.states({
      seq_last = 2,
      seq_cur = 2,
      entries = { entry(2, { entry(1) }) },
    })

    assert.are.same({
      { seq = 2, parent = 0, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)
end)
```

- [ ] **Step 3: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/tree_spec.lua`
Expected: FAIL — `module 'diffundo.tree' not found`.

- [ ] **Step 4: Write the implementation**

```lua
local M = {}

---@class diffundo.State
---@field seq integer
---@field parent integer
---@field time integer
---@field save integer|nil

---@param entries diffundo.UndoEntry[]
---@param parent integer
---@param states diffundo.State[]
local function collect(entries, parent, states)
  local previous = parent
  for _, entry in ipairs(entries) do
    table.insert(states, { seq = entry.seq, parent = previous, time = entry.time, save = entry.save })
    if entry.alt then
      collect(entry.alt, previous, states)
    end
    previous = entry.seq
  end
end

---@param undotree vim.undotree
---@return diffundo.State[]
function M.states(undotree)
  local states = {}
  collect(undotree.entries, 0, states)
  table.sort(states, function(a, b)
    return a.seq > b.seq
  end)
  return states
end

return M
```

- [ ] **Step 5: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/tree_spec.lua && make ci`
Expected: PASS, ci green.

- [ ] **Step 6: Commit**

```bash
git add lua/diffundo/tree.lua spec/tree_spec.lua lua/diffundo/label.lua
git commit -m "Derives undo states and their parents from undotree()

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Teach the fake an undo tree, window cursors and `vim.regex`

**Files:**
- Modify: `spec/fakevim.lua` (the `History` type at lines 13-55; `api()` at lines 150-181; `fn()` at lines 185-202; `M.new` at lines 219-256)
- Modify: `types/vim.lua`

**Interfaces:**
- Produces (fake, for specs):
  - `fakevim.history(states, times?)` unchanged for linear histories; seq `i-1` has parent `i-2`.
  - `History:branch(parent: integer, lines: string[], opts?: {time?: integer, save?: integer}) -> integer` — adds a new newest seq with that parent and moves the history to it.
  - `History:undo(seq)`, `History:earlier(count)`, `History:later(count)`, `History:lines()`, `History:undotree()` (now builds nested `alt` lists in the real-nvim shape; `save` copied when set).
  - `vim.api.nvim_get_current_win()`, `nvim_win_is_valid(win)`, `nvim_win_get_cursor(win) -> {lnum, col}`, `nvim_win_set_cursor(win, {lnum, col})`; `win == 0` means current. Every fake window has `cursor = {1, 0}`.
  - `vim.regex(pattern)` returning `{ match_str = fun(self, line) -> start0|nil, end|nil }` that strips a leading `\V` and does a plain `string.find`.
- Produces (types): the same names on `vim.api`, `---@class vim.regex`, `vim.regex`.

- [ ] **Step 1: Replace the `History` section of `spec/fakevim.lua` (lines 13-55)**

```lua
local History = {}
History.__index = History

---@param states string[][]
---@param times integer[]|nil
function M.history(states, times)
  local self = setmetatable({}, History)
  self.entries = {}
  for index, lines in ipairs(states) do
    local seq = index - 1
    self.entries[seq] = {
      lines = copy(lines),
      parent = math.max(0, seq - 1),
      time = times and times[index] or 1627784659 + seq * 60,
    }
  end
  self.seq_last = #states - 1
  self.seq = self.seq_last
  return self
end

---@param parent integer
---@param lines string[]
---@param opts { time?: integer, save?: integer }|nil
---@return integer
function History:branch(parent, lines, opts)
  local options = opts or {}
  local seq = self.seq_last + 1
  self.entries[seq] = {
    lines = copy(lines),
    parent = parent,
    time = options.time or 1627784659 + seq * 60,
    save = options.save,
  }
  self.seq_last = seq
  self.seq = seq
  return seq
end

---@return string[]
function History:lines()
  return self.entries[self.seq].lines
end

---@param seq integer
function History:undo(seq)
  self.seq = math.max(0, math.min(seq, self.seq_last))
end

---@param count integer
function History:earlier(count)
  self:undo(self.seq - count)
end

---@param count integer
function History:later(count)
  self:undo(self.seq + count)
end

---@param self table
---@param parent integer
---@return integer[]
local function children(self, parent)
  local result = {}
  for seq = self.seq_last, 1, -1 do
    if self.entries[seq].parent == parent then
      table.insert(result, seq)
    end
  end
  return result
end

---@param self table
---@param seq integer
---@param siblings integer[]
---@return table[]
local function chain(self, seq, siblings)
  local entry = self.entries[seq]
  local head = { seq = seq, time = entry.time, save = entry.save }
  if siblings[1] then
    head.alt = chain(self, siblings[1], { unpack(siblings, 2) })
  end
  local list = { head }
  local kids = children(self, seq)
  if kids[1] then
    for _, item in ipairs(chain(self, kids[1], { unpack(kids, 2) })) do
      table.insert(list, item)
    end
  end
  return list
end

function History:undotree()
  local kids = children(self, 0)
  local entries = kids[1] and chain(self, kids[1], { unpack(kids, 2) }) or {}
  return { seq_last = self.seq_last, seq_cur = self.seq, entries = entries }
end
```

- [ ] **Step 2: Give windows a cursor and add the window API**

In `spec/fakevim.lua`, every place a window table is created gets `cursor = { 1, 0 }`. There are two: in the `vert` command handler (`self.windows[win] = { buf = ..., options = {} }`) and in `M.new` (`self.windows[win] = { buf = self.source_bn, options = {} }`). Change both to:

```lua
      self.windows[win] = { buf = self.windows[self.current_win].buf, options = {}, cursor = { 1, 0 } }
```
and
```lua
  self.windows[win] = { buf = self.source_bn, options = {}, cursor = { 1, 0 } }
```

Add a helper above `api()`:

```lua
---@param self table
---@param win integer
---@return table
local function window(self, win)
  local resolved = win == 0 and self.current_win or win
  local found = self.windows[resolved]
  if found == nil then
    error("Invalid window id: " .. tostring(win), 0)
  end
  return found
end
```

Add these entries to the table returned by `api(self)`:

```lua
    nvim_get_current_win = function()
      return self.current_win
    end,
    nvim_win_is_valid = function(win)
      return self.windows[win] ~= nil
    end,
    nvim_win_get_cursor = function(win)
      return copy(window(self, win).cursor)
    end,
    nvim_win_set_cursor = function(win, pos)
      window(self, win).cursor = { pos[1], pos[2] }
    end,
```

- [ ] **Step 3: Add `vim.regex` to the fake**

In `M.new`, after `self.keycode = ...`:

```lua
  self.regex = function(pattern)
    local literal = pattern:gsub("^\\V", "")
    return {
      match_str = function(_, line)
        local start, stop = line:find(literal, 1, true)
        if start == nil then
          return nil
        end
        return start - 1, stop
      end,
    }
  end
```

Leave the `search` and `escape` entries in `fn(self)` and `self.searches` in `M.new` alone for now: `init_spec.lua` still asserts on `vim.searches` until Task 6 rewrites that test and deletes all three.

- [ ] **Step 4: Declare the new API in `types/vim.lua`**

Add to `---@class vim.api`:

```lua
---@field nvim_get_current_win fun(): integer
---@field nvim_win_is_valid fun(window: integer): boolean
---@field nvim_win_get_cursor fun(window: integer): integer[]
---@field nvim_win_set_cursor fun(window: integer, pos: integer[])
```

Add before `---@class vim`:

```lua
---@class vim.regex
---@field match_str fun(self: vim.regex, str: string): integer|nil, integer|nil
```

Add to `---@class vim`:

```lua
---@field regex fun(pattern: string): vim.regex
```

- [ ] **Step 5: Run the whole suite and `make ci`**

Run: `make ci`
Expected: all existing specs PASS unchanged (linear histories behave as before), lint/type/complexity green. `spec/` is linted and formatted but not complexity-checked (`check_complexity.sh` only scans `lua plugin`).

- [ ] **Step 6: Commit**

```bash
git add spec/fakevim.lua types/vim.lua
git commit -m "Models an undo tree, window cursors and vim.regex in the fake

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `walker.lua` — lazy tree-aware step iterator

**Files:**
- Create: `lua/diffundo/walker.lua`
- Create: `spec/walker_spec.lua`

**Interfaces:**
- Consumes: `tree.states`, `lines.added_lines`, `lines.removed_lines`, `vim.fn.undotree()`, `vim.cmd("silent undo N")`, `vim.api.nvim_buf_get_lines(0, 0, -1, false)`.
- Produces:
  - `---@class diffundo.Step`: `seq`, `parent`, `time`, `save`, `lines: string[]`, `parent_lines: string[]`, `added: string[]`, `removed: string[]`.
  - `walker.steps(from_seq: integer) -> fun(): diffundo.Step|nil` — states with `seq < from_seq`, newest first, lazy. Requires the source buffer to be current; leaves the buffer at the last visited seq (callers wrap in `within_source`).

- [ ] **Step 1: Write the failing spec**

```lua
local fakevim = require("spec.fakevim")
local walker = require("diffundo.walker")

---@param iterator fun(): diffundo.Step|nil
---@return diffundo.Step[]
local function collect(iterator)
  local steps = {}
  for step in iterator do
    table.insert(steps, step)
  end
  return steps
end

describe("walker.steps", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } }))
    vim:install()
  end)

  it("yields what each edit added, newest first", function()
    local steps = collect(walker.steps(4))

    assert.are.same({ 3, 2, 1 }, { steps[1].seq, steps[2].seq, steps[3].seq })
    assert.are.same({ "c" }, steps[1].added)
    assert.are.same({ "b" }, steps[2].added)
    assert.are.same({ "a" }, steps[3].added)
    assert.are.same({}, steps[1].removed)
  end)

  it("carries the text of the state and its parent", function()
    local step = walker.steps(4)()

    assert.are.same({ "a", "b", "c" }, step.lines)
    assert.are.same({ "a", "b" }, step.parent_lines)
    assert.are.equal(2, step.parent)
    assert.are.equal(vim.history.entries[3].time, step.time)
  end)

  it("starts strictly behind from_seq", function()
    local steps = collect(walker.steps(3))

    assert.are.same({ 2, 1 }, { steps[1].seq, steps[2].seq })
  end)

  it("never yields the original text", function()
    assert.are.same({}, collect(walker.steps(1)))
  end)

  it("yields removals", function()
    vim.history:branch(3, { "a", "c" })

    local step = walker.steps(5)()

    assert.are.equal(4, step.seq)
    assert.are.same({}, step.added)
    assert.are.same({ "b" }, step.removed)
  end)

  it("diffs against the parent, not the chronological neighbour", function()
    vim.history:branch(1, { "a", "x" })

    local steps = collect(walker.steps(5))

    assert.are.equal(4, steps[1].seq)
    assert.are.equal(1, steps[1].parent)
    assert.are.same({ "x" }, steps[1].added)
    assert.are.same({}, steps[1].removed)
    assert.are.same({ "c" }, steps[2].added)
  end)

  it("is lazy", function()
    local iterator = walker.steps(4)

    iterator()

    assert.are.same({ "silent undo 2", "silent undo 3" }, vim.commands)
  end)

  it("passes save through", function()
    vim.history:branch(3, { "a", "b", "c", "d" }, { save = 2 })

    assert.are.equal(2, walker.steps(5)().save)
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/walker_spec.lua`
Expected: FAIL — `module 'diffundo.walker' not found`.

- [ ] **Step 3: Write the implementation**

```lua
local lines = require("diffundo.lines")
local tree = require("diffundo.tree")

local M = {}

---@class diffundo.Step
---@field seq integer
---@field parent integer
---@field time integer
---@field save integer|nil
---@field lines string[]
---@field parent_lines string[]
---@field added string[]
---@field removed string[]

---@param seq integer
---@return string[]
local function lines_at(seq)
  vim.cmd("silent undo " .. seq)
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@param state diffundo.State
---@return diffundo.Step
local function step_for(state)
  local parent_lines = lines_at(state.parent)
  local current = lines_at(state.seq)
  return {
    seq = state.seq,
    parent = state.parent,
    time = state.time,
    save = state.save,
    lines = current,
    parent_lines = parent_lines,
    added = lines.added_lines(parent_lines, current),
    removed = lines.removed_lines(parent_lines, current),
  }
end

---@param from_seq integer
---@return fun(): diffundo.Step|nil
function M.steps(from_seq)
  local states = tree.states(vim.fn.undotree())
  local index = 0
  return function()
    repeat
      index = index + 1
    until states[index] == nil or states[index].seq < from_seq
    local state = states[index]
    if state == nil then
      return nil
    end
    return step_for(state)
  end
end

return M
```

- [ ] **Step 4: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/walker_spec.lua && make ci`
Expected: PASS, ci green.

- [ ] **Step 5: Commit**

```bash
git add lua/diffundo/walker.lua spec/walker_spec.lua
git commit -m "Walks undo states newest first with per-edit added and removed lines

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `cursor.lua` — where the source cursor lands

**Files:**
- Create: `lua/diffundo/cursor.lua`
- Create: `spec/cursor_spec.lua`

**Interfaces:**
- Consumes: `lines.index_of`.
- Produces:
  - `---@class diffundo.Hit`: `seq: integer`, `time: integer`, `save: integer|nil`, `line: string`, `col: integer` (0-based), `lnum: integer` (1-based, in the state that had the line). Declared here; `init.lua` builds it in Task 6.
  - `cursor.locate(source: string[], hit: diffundo.Hit) -> integer, integer` — `(lnum 1-based, col 0-based)` for `nvim_win_set_cursor`.

- [ ] **Step 1: Write the failing spec**

```lua
local cursor = require("diffundo.cursor")

---@param line string
---@param col integer
---@param lnum integer
---@return diffundo.Hit
local function hit(line, col, lnum)
  return { seq = 7, time = 1000, line = line, col = col, lnum = lnum }
end

describe("cursor.locate", function()
  it("lands on the matched line and column when the line is still there", function()
    local lnum, col = cursor.locate({ "x", "a needle" }, hit("a needle", 2, 9))

    assert.are.same({ 2, 2 }, { lnum, col })
  end)

  it("falls back to the line number when the line is gone", function()
    local lnum, col = cursor.locate({ "x", "y", "z" }, hit("gone", 3, 2))

    assert.are.same({ 2, 0 }, { lnum, col })
  end)

  it("clamps the fallback to the buffer length", function()
    local lnum, col = cursor.locate({ "x" }, hit("gone", 0, 9))

    assert.are.same({ 1, 0 }, { lnum, col })
  end)

  it("uses line one for an empty buffer", function()
    local lnum, col = cursor.locate({}, hit("gone", 0, 3))

    assert.are.same({ 1, 0 }, { lnum, col })
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/cursor_spec.lua`
Expected: FAIL — `module 'diffundo.cursor' not found`.

- [ ] **Step 3: Write the implementation**

```lua
local lines = require("diffundo.lines")

local M = {}

---@class diffundo.Hit
---@field seq integer
---@field time integer
---@field save integer|nil
---@field line string
---@field col integer
---@field lnum integer

---@param source string[]
---@param hit diffundo.Hit
---@return integer, integer
function M.locate(source, hit)
  local index = lines.index_of(source, hit.line)
  if index then
    return index, hit.col
  end
  return math.max(1, math.min(hit.lnum, #source)), 0
end

return M
```

- [ ] **Step 4: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/cursor_spec.lua && make ci`
Expected: PASS, ci green.

- [ ] **Step 5: Commit**

```bash
git add lua/diffundo/cursor.lua spec/cursor_spec.lua
git commit -m "Locates the source cursor for a search hit

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The public API — `search` on the walker, cursor-neutral, raising

**Files:**
- Modify: `lua/diffundo/init.lua` (whole file; the final version is below)
- Modify: `spec/init_spec.lua`
- Delete: `lua/diffundo/additions.lua`, `spec/additions_spec.lua`
- Modify: `spec/fakevim.lua` (remove `search`/`escape` from `fn()` and `self.searches`)
- Modify: `types/vim.lua` (remove `escape` and `search` from `vim.fn`)

**Interfaces:**
- Consumes: `walker.steps`, `split.open/is_open/place/focus`, `count.normalize`, `lines.index_of`, `vim.regex`, cursor/window API from Task 3, `diffundo.Hit` from Task 5.
- Produces (`require("diffundo")`):
  - `M.earlier(count: string|nil)`, `M.later(count: string|nil)` — raise on error, cursor-neutral.
  - `---@class diffundo.SearchOpts` with `removed: boolean|nil`.
  - `M.search(pattern: string, opts: diffundo.SearchOpts|nil) -> diffundo.Hit|nil` — compiles the regex first, opens the split if needed, walks from `t:diffundo_diff_undonr` when the split was already open, else from `changenr() + 1`; on a hit places the diff window at `step.seq`; returns `nil` on no hit or when there is no undo history.
  - `M.command_earlier/command_later/command_search` and `M.search_earlier` are **removed**. `M.repeat_last` and a new `M.command(args)` exist only as stubs after this task (Step 5) so that `plugin/diffundo.lua` type-checks; Task 7 implements them.

- [ ] **Step 1: Rewrite the `search_earlier` and `repeat_last` tests in `spec/init_spec.lua`**

Delete the `describe("search_earlier", ...)` and `describe("repeat_last", ...)` blocks and the tests `"reports an invalid count"` (both in `earlier` and `later`), `"reports a vim error"`, `"reports a source window that is gone"`, `"reports a buffer without undo history"` (they move to the command layer in Task 7). Add:

```lua
  describe("earlier errors", function()
    it("raises an invalid count", function()
      assert.has_error(function()
        diffundo.earlier("1w")
      end, "invalid count: 1w (expected a number, optionally followed by s, m, h, d or f)")
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("raises a vim error and restores the source buffer", function()
      split.open()
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      assert.has_error(function()
        diffundo.earlier()
      end, "Vim(earlier):E475: Invalid argument")
      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
    end)

    it("raises when the source window is gone", function()
      split.open()
      vim:close_window(vim:window_of_buffer(vim.source_bn))
      vim.t.diffundo_source_bn = vim.source_bn

      assert.has_error(function()
        diffundo.earlier()
      end, "The diffundo source window is no longer open in this tab.")
    end)

    it("notifies for a buffer without undo history", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      diffundo.earlier()

      assert.are.equal("No changes to view!", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)
  end)

  describe("cursor neutrality", function()
    it("leaves the window and cursor where they were", function()
      vim.windows[vim.current_win].cursor = { 3, 1 }
      local win = vim.current_win

      diffundo.earlier()
      diffundo.search("second")

      assert.are.equal(win, vim.current_win)
      assert.are.same({ 3, 1 }, vim.windows[win].cursor)
    end)

    it("restores the window even when the body raises", function()
      split.open()
      local win = vim.current_win
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      pcall(diffundo.earlier)

      assert.are.equal(win, vim.current_win)
    end)
  end)

  describe("search", function()
    it("shows the state whose edit added the line", function()
      split.open()

      local hit = diffundo.search("second")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(2, vim.t.diffundo_diff_undonr)
      assert.are.same(
        { seq = 2, time = vim.history.entries[2].time, line = "second", col = 0, lnum = 2 },
        hit
      )
    end)

    it("opens the split itself and considers the live state first", function()
      local hit = diffundo.search("third")

      assert.are.equal(3, hit.seq)
      assert.are.same({ "first", "second", "third" }, vim:diff_buffer().lines)
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("starts behind the displayed state when the split is already open", function()
      split.open()

      assert.is_nil(diffundo.search("third"))
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("skips states that did not add the line", function()
      split.open()

      local hit = diffundo.search("first")

      assert.are.equal(1, hit.seq)
      assert.are.same({ "first" }, vim:diff_buffer().lines)
    end)

    it("returns nil and leaves the split alone when nothing matches", function()
      split.open()

      assert.is_nil(diffundo.search("nonesuch"))
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
      assert.are.same({ "first", "second", "third" }, vim:diff_buffer().lines)
    end)

    it("restores the source buffer", function()
      split.open()

      diffundo.search("nonesuch")

      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
      assert.are.same("diffupdate", vim.commands[#vim.commands])
    end)

    it("continues from the previous match", function()
      vim = fakevim.new(
        fakevim.history({ {}, { "a" }, { "a", "x" }, { "a", "x", "b" }, { "a", "x", "b", "x" } })
      )
      vim:install()

      assert.are.equal(4, diffundo.search("x").seq)
      assert.are.equal(2, diffundo.search("x").seq)
      assert.is_nil(diffundo.search("x"))
    end)

    it("finds removals with opts.removed", function()
      vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a" } }))
      vim:install()

      local hit = diffundo.search("b", { removed = true })

      assert.are.same({ seq = 3, time = vim.history.entries[3].time, line = "b", col = 0, lnum = 2 }, hit)
      assert.are.same({ "a" }, vim:diff_buffer().lines)
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("does not report a branch switch as a removal", function()
      vim.history:branch(1, { "first", "other" })

      assert.is_nil(diffundo.search("second", { removed = true }))
    end)

    it("reports the match column", function()
      vim = fakevim.new(fakevim.history({ {}, { "xx needle" } }))
      vim:install()

      assert.are.equal(3, diffundo.search("needle").col)
    end)

    it("returns nil for a buffer without undo history", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      assert.is_nil(diffundo.search("x"))
      assert.are.equal("No changes to view!", vim:last_notification())
    end)

    it("compiles the pattern before touching anything", function()
      vim.regex = function()
        error("Vim:E54: Unmatched \\(", 0)
      end

      assert.has_error(function()
        diffundo.search("\\(")
      end, "Vim:E54: Unmatched \\(")
      assert.is_nil(vim.t.diffundo_diff_bn)
      assert.are.same({}, vim.commands)
    end)
  end)
```

Also delete `assert.are.same({ "\\Vsecond" }, vim.searches)` anywhere it remains.

- [ ] **Step 2: Run the spec to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/init_spec.lua`
Expected: FAIL — `diffundo.search` is nil; the error-raising tests fail because errors are notified.

- [ ] **Step 3: Rewrite `lua/diffundo/init.lua`**

```lua
local count = require("diffundo.count")
local lines = require("diffundo.lines")
local split = require("diffundo.split")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.SearchOpts
---@field removed boolean|nil

---@generic T
---@param fn fun(): T
---@return T
local function cursor_neutral(fn)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok, result = pcall(fn)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

---@param fn fun()
local function within_source(fn)
  split.focus(true)
  local undonr = vim.fn.changenr()

  local ok, err = pcall(fn)

  split.focus(true)
  vim.cmd("silent undo " .. undonr)
  vim.cmd("diffupdate")
  if not ok then
    error(err, 0)
  end
end

---@return string[]
local function current_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@param command string
---@param amount string
local function early_late(command, amount)
  within_source(function()
    vim.cmd("silent undo " .. vim.t.diffundo_diff_undonr)
    vim.cmd("silent " .. command .. " " .. amount)
    split.place(current_lines(), vim.fn.changenr())
  end)
end

---@param step diffundo.Step
---@param line string
---@param col integer
---@param removed boolean
---@return diffundo.Hit
local function hit_for(step, line, col, removed)
  local had = removed and step.parent_lines or step.lines
  return {
    seq = step.seq,
    time = step.time,
    save = step.save,
    line = line,
    col = col,
    lnum = lines.index_of(had, line) or 1,
  }
end

---@param regex vim.regex
---@param step diffundo.Step
---@param removed boolean
---@return diffundo.Hit|nil
local function match_in(regex, step, removed)
  local candidates = removed and step.removed or step.added
  for _, line in ipairs(candidates) do
    local col = regex:match_str(line)
    if col then
      return hit_for(step, line, col, removed)
    end
  end
  return nil
end

---@param regex vim.regex
---@param from_seq integer
---@param removed boolean
---@return diffundo.Hit|nil
local function find(regex, from_seq, removed)
  for step in walker.steps(from_seq) do
    local hit = match_in(regex, step, removed)
    if hit then
      split.place(step.lines, step.seq)
      return hit
    end
  end
  return nil
end

---@param amount string|nil
function M.earlier(amount)
  cursor_neutral(function()
    local normalized = count.normalize(amount)
    if split.open() then
      early_late("earlier", normalized)
    end
  end)
end

---@param amount string|nil
function M.later(amount)
  cursor_neutral(function()
    local normalized = count.normalize(amount)
    if split.open() then
      early_late("later", normalized)
    end
  end)
end

---@param pattern string
---@param opts diffundo.SearchOpts|nil
---@return diffundo.Hit|nil
function M.search(pattern, opts)
  return cursor_neutral(function()
    local regex = vim.regex(pattern)
    local was_open = split.is_open()
    if not split.open() then
      return nil
    end
    local from_seq = was_open and vim.t.diffundo_diff_undonr or vim.fn.changenr() + 1
    ---@type diffundo.Hit|nil
    local hit
    within_source(function()
      hit = find(regex, from_seq, opts ~= nil and opts.removed == true)
    end)
    return hit
  end)
end

function M.repeat_last() end

return M
```

- [ ] **Step 4: Delete the old module and its fake support**

```bash
git rm lua/diffundo/additions.lua spec/additions_spec.lua
```

In `spec/fakevim.lua` remove the `escape` and `search` entries from `fn(self)` and `self.searches = {}` from `M.new`. In `types/vim.lua` remove `---@field escape ...` and `---@field search ...` from `vim.fn`.

- [ ] **Step 5: Point `plugin/diffundo.lua` at the new API (temporary form)**

Replace the three `nvim_create_user_command` calls with:

```lua
vim.api.nvim_create_user_command("Diffundo", function(opts)
  diffundo.command(opts.args)
end, { nargs = "*" })
```

and add to `init.lua` above `M.repeat_last`:

```lua
---@param args string
function M.command(args)
  vim.notify("diffundo: " .. args)
end
```

(Task 7 replaces both `M.command` and `M.repeat_last` with the real ones.)

- [ ] **Step 6: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/init_spec.lua && make ci`
Expected: PASS, ci green. If `make complexity` flags `M.search`, move the `from_seq` computation into a local `search_from(was_open)` helper.

- [ ] **Step 7: Commit**

```bash
git add -A lua/diffundo plugin spec types
git commit -m "Rebuilds search on the tree walker behind a cursor-neutral API

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `:Diffundo` — subcommand parsing, command layer, cursor, repeat

**Files:**
- Create: `lua/diffundo/subcommand.lua`
- Create: `spec/subcommand_spec.lua`
- Modify: `lua/diffundo/init.lua` (replace the `M.command` stub and `M.repeat_last`)
- Modify: `plugin/diffundo.lua`
- Modify: `spec/init_spec.lua` (add `describe("command", ...)`)

**Interfaces:**
- Consumes: `M.earlier/later/search`, `cursor.locate`, `split.focus/is_open`, `vim.fn["repeat#set"]`, `vim.keycode`, `nvim_win_set_cursor`.
- Produces:
  - `---@class diffundo.Subcommand`: `name: string`, `bang: boolean`, `rest: string`.
  - `subcommand.parse(args: string) -> diffundo.Subcommand|nil` — `nil` for unknown/missing name or a bang on a subcommand that takes none.
  - `subcommand.complete(arglead: string, cmdline: string) -> string[]` — names starting with `arglead` while the cursor is still on the first argument, else `{}`.
  - `subcommand.names` = `{ "earlier", "later", "search", "search!" }`.
  - `M.command(args: string)` — the only notifying/cursor-moving entry point. `M.repeat_last()` re-runs the last `M.command(args)`.

- [ ] **Step 1: Write the failing subcommand spec**

```lua
local subcommand = require("diffundo.subcommand")

describe("subcommand.parse", function()
  it("parses a bare subcommand", function()
    assert.are.same({ name = "earlier", bang = false, rest = "" }, subcommand.parse("earlier"))
  end)

  it("passes the rest verbatim, spaces included", function()
    assert.are.same(
      { name = "search", bang = false, rest = "foo  bar" },
      subcommand.parse("search foo  bar")
    )
  end)

  it("accepts a bang on search", function()
    assert.are.same({ name = "search", bang = true, rest = "x" }, subcommand.parse("search! x"))
  end)

  it("rejects a bang on earlier", function()
    assert.is_nil(subcommand.parse("earlier! 2"))
  end)

  it("rejects unknown and missing subcommands", function()
    assert.is_nil(subcommand.parse("nonesuch"))
    assert.is_nil(subcommand.parse(""))
    assert.is_nil(subcommand.parse("   "))
  end)

  it("ignores leading whitespace", function()
    assert.are.same({ name = "later", bang = false, rest = "2f" }, subcommand.parse("  later 2f"))
  end)
end)

describe("subcommand.complete", function()
  it("offers every name for an empty first argument", function()
    assert.are.same({ "earlier", "later", "search", "search!" }, subcommand.complete("", "Diffundo "))
  end)

  it("filters by prefix", function()
    assert.are.same({ "search", "search!" }, subcommand.complete("se", "Diffundo se"))
  end)

  it("offers nothing past the first argument", function()
    assert.are.same({}, subcommand.complete("", "Diffundo search "))
    assert.are.same({}, subcommand.complete("fo", "Diffundo search fo"))
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/subcommand_spec.lua`
Expected: FAIL — `module 'diffundo.subcommand' not found`.

- [ ] **Step 3: Write `lua/diffundo/subcommand.lua`**

```lua
local M = {}

---@class diffundo.Subcommand
---@field name string
---@field bang boolean
---@field rest string

M.names = { "earlier", "later", "search", "search!" }

local takes_bang = { earlier = false, later = false, search = true }

---@param args string
---@return diffundo.Subcommand|nil
function M.parse(args)
  local head, rest = args:match("^%s*(%S+)%s?(.*)$")
  if head == nil then
    return nil
  end
  local name, bang = head:match("^(%a+)(!?)$")
  local allowed = name and takes_bang[name]
  if allowed == nil or (bang == "!" and not allowed) then
    return nil
  end
  return { name = name, bang = bang == "!", rest = rest }
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local before = cmdline:sub(1, #cmdline - #arglead)
  if not before:match("^%s*%S+%s+$") then
    return {}
  end
  local result = {}
  for _, name in ipairs(M.names) do
    if name:sub(1, #arglead) == arglead then
      table.insert(result, name)
    end
  end
  return result
end

return M
```

- [ ] **Step 4: Run the subcommand spec**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/subcommand_spec.lua`
Expected: PASS.

- [ ] **Step 5: Write the failing command-layer tests in `spec/init_spec.lua`**

```lua
  describe("command", function()
    it("dispatches earlier with its count", function()
      diffundo.command("earlier 2")

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("dispatches later", function()
      diffundo.command("earlier 2")
      diffundo.command("later")

      assert.are.equal(2, vim.t.diffundo_diff_undonr)
    end)

    it("reports an unknown subcommand", function()
      diffundo.command("nonesuch 1")

      assert.are.equal(
        'diffundo: unknown subcommand "nonesuch" (earlier, later, search, search!)',
        vim:last_notification()
      )
    end)

    it("reports a missing subcommand", function()
      diffundo.command("")

      assert.matches('unknown subcommand ""', vim:last_notification())
    end)

    it("reports an invalid count", function()
      diffundo.command("earlier 1w")

      assert.matches("^diffundo: invalid count: 1w", vim:last_notification())
    end)

    it("reports a vim error", function()
      split.open()
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      diffundo.command("earlier")

      assert.are.equal("diffundo: Vim(earlier):E475: Invalid argument", vim:last_notification())
    end)

    it("requires a pattern for search", function()
      diffundo.command("search")

      assert.are.equal("diffundo: search needs a pattern", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("moves the source cursor onto the match", function()
      vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "xx needle" }, { "a", "xx needle", "b" } }))
      vim:install()

      diffundo.command("search needle")

      local source_win = vim:window_of_buffer(vim.source_bn)
      assert.are.equal(source_win, vim.current_win)
      assert.are.same({ 2, 3 }, vim.windows[source_win].cursor)
    end)

    it("falls back to the old line number when the line is gone", function()
      vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a" } }))
      vim:install()

      diffundo.command("search! b")

      assert.are.same({ 1, 0 }, vim.windows[vim:window_of_buffer(vim.source_bn)].cursor)
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("reports no match for additions and removals", function()
      diffundo.command("search nonesuch")
      assert.are.equal("diffundo: no state adds a line matching nonesuch", vim:last_notification())

      diffundo.command("search! nonesuch")
      assert.are.equal("diffundo: no state removes a line matching nonesuch", vim:last_notification())
    end)

    it("does not double-report a buffer without undo history", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      diffundo.command("search x")

      assert.are.same({ "No changes to view!" }, vim.notifications)
    end)
  end)

  describe("repeat_last", function()
    it("does nothing before any command ran", function()
      diffundo.repeat_last()

      assert.are.equal(0, #vim.commands)
    end)

    it("replays the last command with its arguments", function()
      diffundo.command("earlier 1")
      diffundo.repeat_last()

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("registers with vim-repeat when it is installed", function()
      local registered = {}
      vim.fn["repeat#set"] = function(keys)
        table.insert(registered, keys)
      end

      diffundo.command("search second")

      assert.are.same({ "<Plug>(DiffundoRepeat)" }, registered)
    end)

    it("registers with vim-repeat again on every repeat", function()
      local registered = 0
      vim.fn["repeat#set"] = function()
        registered = registered + 1
      end

      diffundo.command("earlier 1")
      diffundo.repeat_last()

      assert.are.equal(2, registered)
    end)
  end)
```

Note: `repeat_last` in the fake must not leak `last` between tests. `init.lua` is `require`d once per busted run, so add to the top-level `before_each` in `init_spec.lua`: `diffundo.command("")` is *not* acceptable (it notifies); instead expose nothing and accept that `"does nothing before any command ran"` must be the first `repeat_last` test — busted runs tests in file order, and the `command` block runs before it. To make it robust, reset via `package.loaded["diffundo"] = nil; diffundo = require("diffundo")` in `before_each` and change `local diffundo = require("diffundo")` at the top to `local diffundo`. **Do this**; it is the pattern that keeps module state out of test order.

- [ ] **Step 6: Run to verify the new tests fail**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/init_spec.lua`
Expected: the `command` and `repeat_last` tests FAIL (stub notifies the raw args; `repeat_last` is a no-op).

- [ ] **Step 7: Replace the stubs in `lua/diffundo/init.lua`**

Add `local cursor = require("diffundo.cursor")` and `local subcommand = require("diffundo.subcommand")` to the requires (keep them alphabetical). Replace `M.command` and `M.repeat_last` with:

```lua
---@param sub diffundo.Subcommand
---@return diffundo.Hit|nil
local function dispatch(sub)
  if sub.name == "earlier" then
    M.earlier(sub.rest)
    return nil
  end
  if sub.name == "later" then
    M.later(sub.rest)
    return nil
  end
  if sub.rest == "" then
    error("search needs a pattern", 0)
  end
  return M.search(sub.rest, { removed = sub.bang })
end

---@param hit diffundo.Hit
local function place_cursor(hit)
  split.focus(true)
  local lnum, col = cursor.locate(current_lines(), hit)
  vim.api.nvim_win_set_cursor(0, { lnum, col })
end

---@param sub diffundo.Subcommand
---@param hit diffundo.Hit|nil
local function finish_search(sub, hit)
  if hit then
    place_cursor(hit)
  elseif split.is_open() then
    local verb = sub.bang and "removes" or "adds"
    vim.notify(("diffundo: no state %s a line matching %s"):format(verb, sub.rest))
  end
end

---@type string|nil
local last_args

---@param args string
function M.command(args)
  last_args = args
  pcall(vim.fn["repeat#set"], vim.keycode("<Plug>(DiffundoRepeat)"))
  local sub = subcommand.parse(args)
  if sub == nil then
    local head = args:match("^%s*(%S*)") or ""
    vim.notify(('diffundo: unknown subcommand "%s" (%s)'):format(head, table.concat(subcommand.names, ", ")))
    return
  end
  local ok, hit = pcall(dispatch, sub)
  if not ok then
    vim.notify("diffundo: " .. tostring(hit))
  elseif sub.name == "search" then
    finish_search(sub, hit)
  end
end

function M.repeat_last()
  if last_args then
    M.command(last_args)
  end
end
```

- [ ] **Step 8: Finish `plugin/diffundo.lua`**

```lua
local diffundo = require("diffundo")
local subcommand = require("diffundo.subcommand")

if vim.g.loaded_diffundo then
  return
end
vim.g.loaded_diffundo = true

vim.api.nvim_create_user_command("Diffundo", function(opts)
  diffundo.command(opts.args)
end, { nargs = "*", complete = subcommand.complete })

vim.keymap.set("n", "<Plug>(DiffundoRepeat)", diffundo.repeat_last, { silent = true })
```

- [ ] **Step 9: Run everything**

Run: `make ci`
Expected: PASS, ci green. If `M.command` exceeds complexity 5, move the unknown-subcommand notify into a `report_unknown(args)` helper.

- [ ] **Step 10: Commit**

```bash
git add lua/diffundo/subcommand.lua spec/subcommand_spec.lua lua/diffundo/init.lua plugin/diffundo.lua spec/init_spec.lua
git commit -m "Replaces the Diff* commands with :Diffundo and its subcommands

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: End-to-end coverage in a real neovim

**Files:**
- Modify: `tests/e2e/diffundo_test.ts`

**Interfaces:**
- Consumes: `:Diffundo` from Task 7, the existing `prelude`, `buildHistory`, `appendState`, `assertDiffSplit`, `assertSourceAlone`, `pressDot`.
- Produces: helpers `setState` (may shrink the buffer) and `assertCursor`, plus the search tests.

- [ ] **Step 1: Rename the command in every existing test**

Replace all `DiffEarlier` with `Diffundo earlier` in `denops.cmd(...)` calls and test names, and change the first assertion to `assertEquals(await denops.call("exists", ":Diffundo"), 2);`.

- [ ] **Step 2: Add the helpers below `buildHistory`**

```ts
// Records `lines` as one undo state even when it is shorter than the buffer.
async function setState(denops: Denops, lines: string[]): Promise<void> {
  await denops.call("setline", 1, lines);
  await denops.call("deletebufline", "%", lines.length + 1, "$");
  await denops.cmd("let &undolevels = &undolevels");
}

async function assertCursor(
  denops: Denops,
  expected: { lnum: number; col: number },
): Promise<void> {
  // WHY: the command must leave the user in their own buffer, not the diff.
  assertEquals(await denops.eval("&buftype"), "");
  assertEquals(await denops.eval("[line('.'), col('.')]"), [
    expected.lnum,
    expected.col,
  ]);
}

async function assertNoMatch(denops: Denops, verb: string, pattern: string): Promise<void> {
  const messages = await denops.call("execute", "messages") as string;
  assert(
    messages.includes(`diffundo: no state ${verb} a line matching ${pattern}`),
    messages,
  );
  await denops.cmd("messages clear");
}
```

- [ ] **Step 3: Add the search tests at the end of the file**

```ts
test({
  mode: "nvim",
  name: ":Diffundo search shows the state that added the line and puts the cursor on it",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "xx two"], [
      "one",
      "xx two",
      "three",
    ]]);

    await denops.cmd("Diffundo search two");

    await assertDiffSplit(denops, {
      undoLines: ["one", "xx two"],
      sourceLines: ["one", "xx two", "three"],
      undonr: 2,
    });
    await assertCursor(denops, { lnum: 2, col: 4 });
    assertEquals(await denops.eval("@/"), "");

    // WHY: the label and t:diffundo_diff_undonr agree, so earlier steps once.
    await denops.cmd("Diffundo earlier");

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "xx two", "three"],
      undonr: 1,
    });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search! shows the state that removed the line",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await setState(denops, ["a"]);
    await setState(denops, ["a", "b"]);
    await setState(denops, ["a"]);

    await denops.cmd("Diffundo search! b");

    await assertDiffSplit(denops, {
      undoLines: ["a"],
      sourceLines: ["a"],
      undonr: 3,
    });
    await assertCursor(denops, { lnum: 1, col: 1 });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search diffs each state against its parent across undo branches",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await setState(denops, ["one"]);
    await setState(denops, ["one", "two"]);
    await denops.cmd("silent undo 1");
    await setState(denops, ["one", "three"]);
    assertEquals(await denops.call("changenr"), 3);

    // WHY: no edit removed "two"; a chronological walk would blame seq 3.
    await denops.cmd("Diffundo search! two");
    await assertNoMatch(denops, "removes", "two");

    await denops.cmd("only");
    await denops.cmd("Diffundo search two");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "three"],
      undonr: 2,
    });
    await assertCursor(denops, { lnum: 2, col: 1 });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search follows 'ignorecase' and 'smartcase' like /",
  prelude,
  fn: async (denops) => {
    await denops.cmd("set ignorecase smartcase");
    await denops.cmd("enew");
    await buildHistory(denops, [["x"], ["x", "Foo"]]);

    await denops.cmd("Diffundo search foo");

    await assertDiffSplit(denops, {
      undoLines: ["x", "Foo"],
      sourceLines: ["x", "Foo"],
      undonr: 2,
    });

    await denops.cmd("only");
    await denops.cmd("Diffundo search FOO");
    await assertNoMatch(denops, "adds", "FOO");
  },
});

test({
  mode: "nvim",
  name: "`.` repeats :Diffundo search to the next older match",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "x"], ["a", "x", "b"], [
      "a",
      "x",
      "b",
      "x",
    ]]);

    await denops.cmd("Diffundo search x");
    await assertDiffSplit(denops, {
      undoLines: ["a", "x", "b", "x"],
      sourceLines: ["a", "x", "b", "x"],
      undonr: 4,
    });

    await pressDot(denops);
    await assertDiffSplit(denops, {
      undoLines: ["a", "x"],
      sourceLines: ["a", "x", "b", "x"],
      undonr: 2,
    });
  },
});
```

- [ ] **Step 4: Run the e2e suite**

Run: `make e2e`
Expected: all tests PASS. If the `search!` cursor test lands on column 0 rather than 1, note that `col('.')` is 1-based: `assertCursor` compares against vim's 1-based column, so `hit.col` 0 → `col('.')` 1 and `hit.col` 3 → 4, as the expectations above already assume.

- [ ] **Step 5: Run `make ci` (lint covers nothing in `tests/`, but confirm nothing regressed) and commit**

```bash
make ci
git add tests/e2e/diffundo_test.ts
git commit -m "Covers :Diffundo search end to end, including undo branches

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md` (Commands, Setup, Repeating sections)
- Create: `doc/diffundo.txt`
- Commit (already written, uncommitted): `docs/adr/0004-single-command-cursor-neutral-api-and-tree-aware-undo-walker.md`, `docs/superpowers/specs/2026-09-21-search-and-single-command-design.md`, `docs/superpowers/plans/2026-09-22-search-and-single-command.md`

- [ ] **Step 1: Rewrite the README's Commands section**

Replace everything from `Commands` through the end of the `Repeating` section with:

````markdown
Commands
--------

One command, `:Diffundo`, with subcommands (tab-completes):

*:Diffundo earlier [count]* : compare your current buffer against the buffer if you had typed `:earlier [count]`. Accepts the same count as the builtin: `3`, `10s`, `2f` ... (default `1`).

*:Diffundo later [count]* : the same for `:later`.

*:Diffundo search {pattern}* : find the undo state whose edit **added** a line matching `{pattern}` (a vim regex, so `'ignorecase'` and `'smartcase'` apply as with `/`), show it in the diff split, and put your cursor on the match. Repeat it to find the next older one.

*:Diffundo search! {pattern}* : the same for a line that was **removed**.

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
````

- [ ] **Step 2: Write `doc/diffundo.txt`**

```text
*diffundo.txt*  Diff your buffer against its undo history

==============================================================================
CONTENTS                                                     *diffundo-contents*

  1. Command ..................................... |:Diffundo|
  2. Lua API ..................................... |diffundo-api|
  3. Repeating ................................... |diffundo-repeat|

==============================================================================
1. COMMAND                                                          *:Diffundo*

:Diffundo earlier [count]                                  *:Diffundo-earlier*
    Open (or update) a vertical diff split showing the buffer as it was
    after |:earlier| [count]. [count] is anything |:earlier| accepts:
    `3`, `10s`, `2f` ... Default `1`. Relative to the state the split
    already shows, so repeating it walks further back.

:Diffundo later [count]                                      *:Diffundo-later*
    The same for |:later|.

:Diffundo search {pattern}                                  *:Diffundo-search*
    Find the undo state whose edit added a line matching {pattern}, show
    it in the diff split, and move the cursor to the match in your buffer
    (or to where the line was, if it is gone). {pattern} is a Vim regex:
    'ignorecase', 'smartcase' and 'magic' apply as for |/|. The search
    register |quote/| is not changed. Repeat to find the next older state.

:Diffundo search! {pattern}
    The same for a line that was removed.

    Search compares each undo state with the state it was edited from
    (its parent in the undo tree, see |undo-branches|), so switching
    branches never counts as an addition or removal.

The diff window's 'statusline' and 'winbar' show the timestamp and
sequence number (|changenr()|) of the state it displays.

==============================================================================
2. LUA API                                                        *diffundo-api*

All functions leave the current window and cursor unchanged and raise
errors instead of printing them. >lua

    local diffundo = require("diffundo")
    diffundo.earlier(count)            -- count: string|nil, as :earlier
    diffundo.later(count)
    diffundo.search(pattern, opts)     -- opts.removed = true for search!
<
`search` returns nil when nothing matches, otherwise a table: >
    { seq, time, save, line, col, lnum }
<
`seq` is the state shown in the split, `line` the matched text, `col` the
0-based match column and `lnum` the line's number in the state that had it.

`require("diffundo.walker").steps(from_seq)` returns an iterator over undo
states with seq below `from_seq`, newest first, each `{ seq, parent,
time, save, lines, parent_lines, added, removed }`. It runs |:undo| in the
current buffer, so call it with the source buffer current and restore
afterwards.

==============================================================================
3. REPEATING                                                   *diffundo-repeat*

With tpope/vim-repeat installed, |.| runs the last :Diffundo command
again with the same arguments.

 vim:tw=78:ts=8:ft=help:norl:
```

- [ ] **Step 3: Check the help file loads**

Run: `nvim --headless -u NONE --cmd "set rtp^=$PWD" -c "helptags doc" -c "help :Diffundo-search" -c "echo expand('%:t')" -c "qa!" 2>&1`
Expected: prints `diffundo.txt`, no `E149`. Then `rm doc/tags` (generated; keep it out of git — add `doc/tags` to `.gitignore`).

- [ ] **Step 4: `make ci` and commit**

```bash
make ci
git add README.md doc/diffundo.txt .gitignore docs/adr/0004-single-command-cursor-neutral-api-and-tree-aware-undo-walker.md docs/superpowers
git commit -m "Documents :Diffundo, the Lua API and the tree-aware search

ADR 4 records the single command, the cursor-neutral API layering and
the tree-aware walker; the design spec and plan it came from are kept
under docs/superpowers.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Close the loop on GitHub**

After the branch is merged:

```bash
gh issue close 7 --repo dsummersl/vim-diffundo --comment "Closed by the tree-aware search: \`:Diffundo search[!] {pattern}\` (ADR 4)."
gh issue comment 8 --repo dsummersl/vim-diffundo --body "Sub-project 1 (undo-state walker + search) is done: \`lua/diffundo/walker.lua\` + \`:Diffundo search[!]\`. Next: sub-project 3 (sidebar)."
```
