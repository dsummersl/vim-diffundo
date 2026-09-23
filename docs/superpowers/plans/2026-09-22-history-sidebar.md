# History Sidebar (the floating undo list) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `:Diffundo` a floating, keyboard-first history sidebar — one line per undo state carrying a one-line preview diff — that commands open by default, that `-no-history` suppresses, and whose `<cr>` places the selected state into the existing diff split.

**Architecture:** Three new layers behind the existing command layer. `history.lua` computes the list (`row_for`, the walk-collecting `rows`, and pure `render`/`next`/`filtered`); `window.lua` is a thin `nvim_open_win` float (mirrors `split.lua`); `sidebar.lua` is the controller — open/close/toggle/reveal/place/move_save/filter — wired into `command()` by `subcommand.lua` gaining the `-no-history` flag and the `history` subcommand. The diff opens/changes **only** on `<cr>`; cursor moves never touch it.

**Tech Stack:** Lua (LuaJIT / neovim 0.10+), busted + `spec/fakevim.lua` for unit tests, deno + denops.vim for e2e, selene/stylua/ast-grep/lua-language-server via `make ci`.

**Spec:** `docs/superpowers/specs/2026-09-22-history-sidebar-design.md`

## Global Constraints

- Neovim 0.10 or newer; no classic Vim (nothing here needs the 0.11 floor yet).
- No comments in Lua except `---@param`/`---@return`/`---@class`/`---@field` annotations (ast-grep rule `no-comments-lua`). No `---` prose lines.
- `require` calls only at the top of a file (ast-grep rule `no-require-in-function-lua`).
- Modules return a local table `M`; no globals.
- Cyclomatic complexity ≤ 5 per function, functions < 80 lines (`make complexity`; only scans `lua/ plugin/`).
- lua-language-server strict diagnostics; every public function annotated; every new `vim` API declared in `types/vim.lua` and modelled in `spec/fakevim.lua`.
- Unit tests never launch neovim. Run one spec with `eval $(luarocks --tree lua_modules path --bin) && busted spec/<name>_spec.lua`.
- `make ci` must pass at the end of every task; `make e2e` at the end of Task 8.
- Commit messages: present-tense third-person subject like the existing history ("Adds …", "Extracts …"), ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Only the command layer (`M.command` in `init.lua`) may `vim.notify`, call `repeat#set`, or move the cursor. `split.open()` keeps its "No changes to view!" notify; `sidebar.open()` adds its own for `:Diffundo history` with empty history.
- The diff split opens/changes **only** on `<cr>` (strict; no timers, no debounce). Floating window facts (verified against real nvim): floats **count** in `winnr('$')`, are detectable via `nvim_win_get_config(w).relative == "editor"`, and `:only` **errors with E5601 while a float is open** — the e2e suite must close the history float before running `:only`.
- All of `history.render`/`next`/`filtered` are pure (no `vim` state). Small recorded deviations from the spec's wording: `history.rows` and `row_for` need `vim` (the walker drives `:undo`, and the row label comes from `label.for_undonr`, read-only) — their tests install the fake, like every other spec.

## File Structure

| File | Responsibility |
|---|---|
| `lua/diffundo/restore.lua` (new) | `within_source`: the source guard, extracted unchanged from `init.lua`; tolerates a closed split (the sidebar's standalone case). |
| `lua/diffundo/pattern.lua` (new) | `pattern.compile(pattern)` = `vim.regex` with `\C`/`\c` case flags, extracted (as `with_case_flag`) from `init.lua`; shared by `search` and the sidebar's `/`. |
| `lua/diffundo/lines.lua` (modify) | Adds pure `first_match(regex, candidates) -> line|nil, col|nil`, shared by `init.lua`'s `match_in` and `history.filtered`. |
| `lua/diffundo/history.lua` (new) | `row_for(step)`, `rows(opts)`, `render(row, width)`, `next(rows, index, opts)`, `filtered(rows, regex, opts)`. |
| `lua/diffundo/window.lua` (new) | Float mechanics on `nvim_*`: `open`, `render`, `map`, `close`, `is_open`. |
| `lua/diffundo/sidebar.lua` (new) | Controller: `open`, `close`, `toggle`, `reveal`, `place`, `move_save`, `filter`. Tab state in `t:diffundo_history_*`. |
| `lua/diffundo/subcommand.lua` (modify) | `-no-history` leading flag; `history` name; completion includes both. |
| `lua/diffundo/init.lua` (modify) | Uses `restore.within_source` + `pattern.compile`; dispatch handles `history`; command reveals the sidebar after successful actions. |
| `spec/fakevim.lua` (modify), `types/vim.lua` (modify) | `nvim_create_buf`, `nvim_open_win`, `nvim_win_close`, `nvim_win_set_config`, `nvim_buf_set_keymap` (registry + `fake:press`), `nvim_buf_delete`, `vim.fn.input`, `vim.o.lines`, `vim.g`. |
| `spec/restore_spec.lua`, `pattern_spec.lua`, `history_spec.lua`, `window_spec.lua`, `sidebar_spec.lua` (new); `spec/lines_spec.lua`, `spec/init_spec.lua`, `spec/subcommand_spec.lua` (modify) | Unit tests. |
| `tests/e2e/diffundo_test.ts` (modify) | Float-aware helpers; existing tests close the float before `:only`/cursor asserts; new float tests. |
| `README.md`, `doc/diffundo.txt` (modify), `docs/adr/0005-*.md` (new) | Docs. |

---

### Task 1: Extract `restore.within_source`

**Files:**
- Create: `lua/diffundo/restore.lua`
- Create: `spec/restore_spec.lua`
- Modify: `lua/diffundo/init.lua` (remove the local `within_source`, call the module)

**Interfaces:**
- Consumes: `split.is_open`, `split.focus`, `vim.fn.changenr`, `vim.cmd`.
- Produces:
  - `restore.within_source(fn: fun())` — if the diff split is open, focus the source window; record `changenr()`; `pcall(fn)`; focus the source window again; `silent undo <undonr>`; `diffupdate`; on failure re-`error(err, 0)`. When the split is closed it skips the focus calls and acts on the current window (the sidebar's standalone case).
- Note: behaviour is identical to today's `within_source` for every existing call site (they all run with the split open), so `spec/init_spec.lua` must stay green unchanged.

- [ ] **Step 1: Write the failing spec**

```lua
local fakevim = require("spec.fakevim")
local restore = require("diffundo.restore")
local split = require("diffundo.split")

local function history()
  return fakevim.history({ {}, { "first" }, { "first", "second" }, { "first", "second", "third" } })
end

describe("restore.within_source", function()
  it("runs the body with the source buffer current", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()

    local seen
    restore.within_source(function()
      seen = vim.history.seq
    end)

    assert.are.equal(3, seen)
  end)

  it("restores the live state and runs diffupdate afterwards", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()

    restore.within_source(function()
      vim.history:undo(1)
    end)

    assert.are.equal(3, vim.history.seq)
    assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
    assert.are.equal("diffupdate", vim.commands[#vim.commands])
  end)

  it("restores even when the body raises", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()

    assert.has_error(function()
      restore.within_source(function()
        error("boom", 0)
      end)
    end, "boom")
    assert.are.equal(3, vim.history.seq)
  end)

  it("acts on the current buffer when no split is open", function()
    local vim = fakevim.new(history())
    vim:install()

    restore.within_source(function()
      vim.history:undo(1)
    end)

    assert.are.equal(3, vim.history.seq)
    assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/restore_spec.lua`
Expected: FAIL — `module 'diffundo.restore' not found`.

- [ ] **Step 3: Write `lua/diffundo/restore.lua`**

```lua
local split = require("diffundo.split")

local M = {}

---@param fn fun()
function M.within_source(fn)
  local has_split = split.is_open()
  if has_split then
    split.focus(true)
  end
  local undonr = vim.fn.changenr()

  local ok, err = pcall(fn)

  if has_split then
    split.focus(true)
  end
  vim.cmd("silent undo " .. undonr)
  vim.cmd("diffupdate")
  if not ok then
    error(err, 0)
  end
end

return M
```

- [ ] **Step 4: Point `init.lua` at the module**

In `lua/diffundo/init.lua`, add `local restore = require("diffundo.restore")` to the requires (alphabetical, before `split`), delete the local `within_source` function, and replace both `within_source(...)` call sites (in `early_late` and `M.search`) with `restore.within_source(...)`.

- [ ] **Step 5: Run both specs and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/restore_spec.lua spec/init_spec.lua && make ci`
Expected: all PASS, ci green.

- [ ] **Step 6: Commit**

```bash
git add lua/diffundo/restore.lua spec/restore_spec.lua lua/diffundo/init.lua
git commit -m "Extracts within_source into a shared source guard

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Shared predicate and pattern compilation

**Files:**
- Create: `lua/diffundo/pattern.lua`
- Create: `spec/pattern_spec.lua`
- Modify: `lua/diffundo/lines.lua` (add `first_match`)
- Modify: `spec/lines_spec.lua` (add `first_match` cases)
- Modify: `lua/diffundo/init.lua` (`match_in` uses `lines.first_match`; `search` uses `pattern.compile`; delete the local `with_case_flag`)

**Interfaces:**
- Produces:
  - `lines.first_match(regex: vim.regex, candidates: string[]) -> string|nil, integer|nil` — the first candidate `regex:match_str` matches, and its 0-based column.
  - `pattern.compile(pattern: string) -> vim.regex` — `vim.regex` with `\C` when `'ignorecase'` is off or when `'smartcase'` is on with an uppercase letter, else `\c` (identical to the `with_case_flag` being moved out of `init.lua`).

- [ ] **Step 1: Write the failing pattern spec**

```lua
local fakevim = require("spec.fakevim")
local pattern = require("diffundo.pattern")

describe("pattern.compile", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {} }))
    vim:install()
  end)

  local function capture(compile_this)
    local given
    vim.regex = function(p)
      given = p
      return { match_str = function() return 0, 1 end }
    end
    pattern.compile(compile_this)
    return given
  end

  it("forces case sensitivity when ignorecase is off", function()
    assert.are.equal("\\Cfoo", capture("foo"))
  end)

  it("forces case sensitivity for a smartcase uppercase pattern", function()
    vim.o.ignorecase = true
    vim.o.smartcase = true

    assert.are.equal("\\CFoo", capture("Foo"))
  end)

  it("celebrates a lowercase pattern under smartcase", function()
    vim.o.ignorecase = true
    vim.o.smartcase = true

    assert.are.equal("\\cfoo", capture("foo"))
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/pattern_spec.lua`
Expected: FAIL — `module 'diffundo.pattern' not found`.

- [ ] **Step 3: Write `lua/diffundo/pattern.lua`**

```lua
local M = {}

---@param pattern string
---@return string
local function with_case_flag(pattern)
  if not vim.o.ignorecase then
    return "\\C" .. pattern
  end
  if vim.o.smartcase and pattern:find("%u") then
    return "\\C" .. pattern
  end
  return "\\c" .. pattern
end

---@param pattern string
---@return vim.regex
function M.compile(pattern)
  return vim.regex(with_case_flag(pattern))
end

return M
```

- [ ] **Step 4: Run the pattern spec**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/pattern_spec.lua`
Expected: PASS.

- [ ] **Step 5: Add `lines.first_match`**

Append to `lua/diffundo/lines.lua` (before `return M`):

```lua
---@param regex vim.regex
---@param candidates string[]
---@return string|nil, integer|nil
function M.first_match(regex, candidates)
  for _, line in ipairs(candidates) do
    local col = regex:match_str(line)
    if col then
      return line, col
    end
  end
  return nil
end
```

Append to `spec/lines_spec.lua` a new `describe("lines.first_match", ...)`:

```lua
local function sub_regex(needle)
  return {
    match_str = function(_, line)
      local start = line:find(needle, 1, true)
      if start then
        return start - 1, start
      end
      return nil
    end,
  }
end

describe("lines.first_match", function()
  it("returns the first matching candidate and its column", function()
    assert.are.same({ "ax", 1 }, { lines.first_match(sub_regex("x"), { "no", "ax", "x" }) })
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(lines.first_match(sub_regex("z"), { "a", "b" }))
  end)
end)
```

- [ ] **Step 6: Refactor `init.lua` onto the seam**

In `lua/diffundo/init.lua`:
- Add `local pattern = require("diffundo.pattern")` to the requires (alphabetical).
- Delete the local `with_case_flag` function.
- Replace the body of the local `match_in` with:

```lua
---@param regex vim.regex
---@param step diffundo.Step
---@param removed boolean
---@return diffundo.Hit|nil
local function match_in(regex, step, removed)
  local candidates = removed and step.removed or step.added
  local line, col = lines.first_match(regex, candidates)
  if line then
    return hit_for(step, line, col, removed)
  end
  return nil
end
```

- Replace `local regex = vim.regex(with_case_flag(pattern))` in `M.search` with `local regex = pattern.compile(pattern)`.

- [ ] **Step 7: Run the specs and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/pattern_spec.lua spec/lines_spec.lua spec/init_spec.lua && make ci`
Expected: all PASS, ci green. (`init_spec` "compiles the pattern before touching anything" still holds: the `vim.regex` override raises inside `pattern.compile`.)

- [ ] **Step 8: Commit**

```bash
git add lua/diffundo/pattern.lua spec/pattern_spec.lua lua/diffundo/lines.lua spec/lines_spec.lua lua/diffundo/init.lua
git commit -m "Shares the search predicate and case-flag regex builder

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Teach the fake floats, keymaps, input and buffer APIs

**Files:**
- Modify: `spec/fakevim.lua`
- Modify: `types/vim.lua`

**Interfaces:**
- Produces (fake, for specs):
  - `nvim_create_buf(scratch, listed) -> integer` — a new empty, unnamed buffer.
  - `nvim_open_win(buf, enter, config) -> integer` — a new window (`cursor = {1,0}`, `config` stored) appended to `win_order`; current when `enter` is true.
  - `nvim_win_close(win, force)`, `nvim_win_set_config(win, config)` (merges `config`), `nvim_buf_delete(buf, opts)`.
  - `nvim_buf_set_keymap(buf, mode, lhs, rhs, opts)` — stores `opts.callback` in `self.keymaps[buf][lhs]`; `fake:press(lhs)` invokes the current buffer's map or errors.
  - `vim.fn.input(...)` returns `""` by default (tests override by replacing `vim.fn.input`).
  - `vim.o.lines = 40`; `vim.g = {}`.
  - Window tables gain a `config = nil` field.
- Produces (types): the same names on `vim.api`, `vim.fn.input`, `vim.o.lines`, `vim.g`.

- [ ] **Step 1: Add the window/buffer API**

In `spec/fakevim.lua`, add to `api(self)`:

```lua
    nvim_create_buf = function()
      return new_buffer(self)
    end,
    nvim_open_win = function(buf, enter, config)
      local win = self.next_win
      self.next_win = win + 1
      self.windows[win] = { buf = buf, options = {}, cursor = { 1, 0 }, config = config or {} }
      table.insert(self.win_order, win)
      if enter then
        self.current_win = win
      end
      return win
    end,
    nvim_win_close = function(win)
      self:close_window(win)
    end,
    nvim_win_set_config = function(win, config)
      local found = window(self, win)
      for key, value in pairs(config) do
        found.config[key] = value
      end
    end,
    nvim_buf_set_keymap = function(buf, mode, lhs, _, opts)
      if mode ~= "n" then
        return
      end
      self.keymaps[buf] = self.keymaps[buf] or {}
      self.keymaps[buf][lhs] = opts.callback
    end,
    nvim_buf_delete = function(buf)
      self.buffers[buf] = nil
    end,
```

- [ ] **Step 2: Add `input`, `lines`, `g` and keymaps to `M.new`**

In `M.new`:
- change `self.o = { ignorecase = false, smartcase = false }` to also carry `lines = 40`;
- add `self.g = {}` and `self.keymaps = {}` next to `self.commands = {}`;
- after the `self.notify = ...` line add `self.fn.input = function() return "" end` (set the field on the already-built `fn` table).

- [ ] **Step 3: Add the `press` helper**

Add a method next to `Fake:install`:

```lua
---@param keys string
function Fake:press(keys)
  local buf = current_buffer(self).number
  local map = self.keymaps[buf] and self.keymaps[buf][keys]
  if map == nil then
    error("no keymap for " .. keys .. " in buffer " .. buf, 0)
  end
  map()
end
```

- [ ] **Step 4: Declare the new API in `types/vim.lua`**

Add to `---@class vim.api`:

```lua
---@field nvim_create_buf fun(scratch: boolean, listed: boolean): integer
---@field nvim_open_win fun(buffer: integer, enter: boolean, config: table): integer
---@field nvim_win_close fun(window: integer, force: boolean)
---@field nvim_win_set_config fun(window: integer, config: table)
---@field nvim_buf_set_keymap fun(buffer: integer, mode: string, lhs: string, rhs: string, opts: table)
---@field nvim_buf_delete fun(buffer: integer, opts: table)
```

Add to `---@class vim.fn`: `---@field input fun(prompt: any): string`.
Add to `---@class vim.o`: `---@field lines integer`.
Add to `---@class vim`: `---@field g table<string, any>`.

- [ ] **Step 5: Run the whole suite and `make ci`**

Run: `make ci`
Expected: all existing specs PASS unchanged, ci green. (`nvim_win_close` in the fake removes the window and, via `close_window`, wipes `bufhidden = "wipe"` buffers — matching what `split_spec` already asserts for `:only`-free paths.)

- [ ] **Step 6: Commit**

```bash
git add spec/fakevim.lua types/vim.lua
git commit -m "Models floats, keymaps, input and buffer creation in the fake

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `history.lua` — the list computation

**Files:**
- Create: `lua/diffundo/history.lua`
- Create: `spec/history_spec.lua`

**Interfaces:**
- Consumes: `walker.steps`, `label.for_undonr`, `lines.first_match`, `restore.within_source`, `vim.fn.undotree`.
- Produces:
  - `---@class diffundo.Row`: `seq`, `time`, `save`, `added: string[]`, `removed: string[]`, `label: string`.
  - `history.row_for(step: diffundo.Step) -> diffundo.Row` — copies the diff fields, labels via `label.for_undonr(step.seq)`.
  - `history.rows(opts: {limit?: integer}|nil) -> diffundo.Row[]` — newest first, collected inside `restore.within_source` from `walker.steps(seq_last + 1)`; stops at `limit` (default 500) and appends a sentinel `{seq = 0, ...}` row when a further state exists.
  - `history.render(row, width: integer) -> string` — sentinel -> `…older…`; else `label .. (" [saved]" when save) .. "  " .. preview`, truncated to `width`.
  - `history.next(rows, index, opts: {dir?: integer, written?: boolean}|nil) -> integer` — nearest neighbour in `dir` (default 1) skipping non-`save` rows when `written`; returns `index` at the edges (clamp-safe).
  - `history.filtered(rows, regex: vim.regex, opts: {removed?: boolean}|nil) -> diffundo.Row[]` — rows whose `added` (or `removed`) lines match via `lines.first_match`.
  - Preview rule: 1 added & 0 removed -> `+ {line}`; 0 added & 1 removed -> `- {line}`; else `~ {n} added, {m} removed`.

- [ ] **Step 1: Write the failing spec**

```lua
local fakevim = require("spec.fakevim")
local history = require("diffundo.history")

---@param over table|nil
---@return diffundo.Step
local function step(over)
  local base = { seq = 4, parent = 3, time = 1004, added = {}, removed = {}, lines = {}, parent_lines = {} }
  for key, value in pairs(over or {}) do
    base[key] = value
  end
  return base
end

local vim

before_each(function()
  vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } }))
  vim:install()
end)

describe("history.row_for", function()
  it("copies the step's diff fields", function()
    local row = history.row_for(step({ added = { "x" }, removed = { "y" }, save = 2 }))

    assert.are.equal(4, row.seq)
    assert.are.equal(2, row.save)
    assert.are.same({ "x" }, row.added)
    assert.are.same({ "y" }, row.removed)
  end)

  it("labels from the undotree entry", function()
    local row = history.row_for(step({ seq = 2 }))

    assert.matches("%- 2$", row.label)
  end)
end)

describe("history.render", function()
  it("previews a single addition", function()
    local row = history.row_for(step({ added = { "foo()" } }))

    assert.matches("+ foo%(%)", history.render(row, 40))
  end)

  it("previews a single removal", function()
    local row = history.row_for(step({ removed = { "bar" } }))

    assert.matches("%- bar", history.render(row, 40))
  end)

  it("summarises mixed changes", function()
    local row = history.row_for(step({ added = { "a", "b" }, removed = { "c" } }))

    assert.matches("~ 2 added, 1 removed", history.render(row, 40))
  end)

  it("marks saved rows and truncates to the width", function()
    local row = history.row_for(step({ save = 1 }))

    assert.matches("%[saved%]", history.render(row, 10))
    assert.is_true(#history.render(row, 10) <= 10)
  end)

  it("renders the sentinel as an ellipsis", function()
    assert.are.equal("…older…", history.render({ seq = 0, added = {}, removed = {} }, 40))
  end)
end)

describe("history.rows", function()
  it("walks the whole history newest first and restores the live state", function()
    local rows = history.rows({})

    assert.are.same({ 3, 2, 1 }, { rows[1].seq, rows[2].seq, rows[3].seq })
    assert.are.same({ "c" }, rows[1].added)
    assert.are.equal(3, vim.history.seq)
  end)

  it("caps at the limit and appends the sentinel", function()
    local rows = history.rows({ limit = 1 })

    assert.are.same({ 3, 0 }, { rows[1].seq, rows[2].seq })
  end)

  it("does not append the sentinel when the limit is not reached", function()
    local rows = history.rows({ limit = 10 })

    assert.are.equal(3, #rows)
  end)

  it("returns nothing for an empty history", function()
    local empty = fakevim.new(fakevim.history({ {} }))
    empty:install()

    assert.are.same({}, history.rows({}))
  end)
end)

describe("history.next", function()
  local function rows()
    return {
      { seq = 3, save = nil },
      { seq = 2, save = 2 },
      { seq = 1, save = nil },
    }
  end

  it("moves down by default and up with dir -1", function()
    assert.are.equal(2, history.next(rows(), 1))
    assert.are.equal(1, history.next(rows(), 3, { dir = -1 }))
  end)

  it("skips non-save rows when written", function()
    assert.are.equal(2, history.next(rows(), 1, { written = true }))
    assert.are.equal(1, history.next(rows(), 3, { dir = -1, written = true }))
  end)

  it("clamps at the edges", function()
    assert.are.equal(3, history.next(rows(), 3))
    assert.are.equal(1, history.next(rows(), 1, { dir = -1 }))
  end)
end)

describe("history.filtered", function()
  it("keeps rows with a matching added line", function()
    local regex = vim.regex("x")
    local rows = { { seq = 3, added = { "ax" } }, { seq = 2, added = { "nope" } } }

    local filtered = history.filtered(rows, regex)

    assert.are.equal(1, #filtered)
    assert.are.equal(3, filtered[1].seq)
  end)

  it("matches removed lines with opts.removed", function()
    local regex = vim.regex("x")
    local rows = { { seq = 3, added = {}, removed = { "ax" } } }

    assert.are.equal(3, history.filtered(rows, regex, { removed = true })[1].seq)
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/history_spec.lua`
Expected: FAIL — `module 'diffundo.history' not found`.

- [ ] **Step 3: Write the implementation**

```lua
local label = require("diffundo.label")
local lines = require("diffundo.lines")
local restore = require("diffundo.restore")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]
---@field removed string[]
---@field label string

local older = {
  seq = 0,
  time = 0,
  save = nil,
  added = {},
  removed = {},
  label = "",
}

---@param text string
---@param width integer
---@return string
local function truncate(text, width)
  if #text <= width then
    return text
  end
  return text:sub(1, width)
end

---@param row diffundo.Row
---@return string
local function preview_for(row)
  if #row.added == 1 and #row.removed == 0 then
    return "+ " .. row.added[1]
  end
  if #row.added == 0 and #row.removed == 1 then
    return "- " .. row.removed[1]
  end
  return ("~ %d added, %d removed"):format(#row.added, #row.removed)
end

---@param step diffundo.Step
---@return diffundo.Row
function M.row_for(step)
  return {
    seq = step.seq,
    time = step.time,
    save = step.save,
    added = step.added,
    removed = step.removed,
    label = label.for_undonr(step.seq),
  }
end

---@param opts { limit?: integer }
---@return diffundo.Row[]
function M.rows(opts)
  local limit = opts.limit or 500
  local collected = {}
  restore.within_source(function()
    local count = 0
    for step in walker.steps(vim.fn.undotree().seq_last + 1) do
      if count < limit then
        table.insert(collected, M.row_for(step))
        count = count + 1
      elseif count == limit then
        table.insert(collected, older)
        count = count + 1
      end
    end
  end)
  return collected
end

---@param row diffundo.Row
---@param width integer
---@return string
function M.render(row, width)
  if row.seq == 0 then
    return truncate("…older…", width)
  end
  local marker = row.save and " [saved]" or ""
  return truncate(row.label .. marker .. "  " .. preview_for(row), width)
end

---@param rows diffundo.Row[]
---@param index integer
---@param opts { dir?: integer, written?: boolean }|nil
---@return integer
function M.next(rows, index, opts)
  local options = opts or {}
  local dir = options.dir or 1
  local candidate = index + dir
  local last = #rows
  while candidate >= 1 and candidate <= last do
    if options.written == true and rows[candidate].save == nil then
      candidate = candidate + dir
    else
      return candidate
    end
  end
  return index
end

---@param rows diffundo.Row[]
---@param regex vim.regex
---@param opts { removed?: boolean }|nil
---@return diffundo.Row[]
function M.filtered(rows, regex, opts)
  local removed = opts ~= nil and opts.removed == true
  local result = {}
  for _, row in ipairs(rows) do
    local candidates = removed and row.removed or row.added
    if lines.first_match(regex, candidates) then
      table.insert(result, row)
    end
  end
  return result
end

return M
```

- [ ] **Step 4: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/history_spec.lua && make ci`
Expected: PASS, ci green.
If `M.rows` trips `make complexity`, hoist the walk into a local `collect(limit)` returning `collected` and have `M.rows` call it.

- [ ] **Step 5: Commit**

```bash
git add lua/diffundo/history.lua spec/history_spec.lua
git commit -m "Adds the undo-state list computation for the sidebar

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `window.lua` — float mechanics

**Files:**
- Create: `lua/diffundo/window.lua`
- Create: `spec/window_spec.lua`

**Interfaces:**
- Consumes: `nvim_create_buf`, `nvim_open_win`, `nvim_win_get_buf`, `nvim_win_set_config`, `nvim_win_close`, `nvim_buf_set_keymap`, `nvim_buf_delete`, `nvim_win_is_valid`, `nvim_buf_is_valid`, `vim.bo`, `vim.wo`, `vim.o.lines`.
- Produces:
  - `window.open(opts: {lines: string[], title: string, width: integer}) -> integer` — scratch `bufhidden=wipe` buffer, focused float at the editor's top-left with `height = max(1, min(#lines, o.lines - 4))`; writes the lines.
  - `window.render(win, lines)` — replaces the lines and re-heights the float.
  - `window.map(win, lhs: string, fn: fun())` — normal-mode buffer-local keymap with `opts.callback`.
  - `window.close(win)` — `nvim_win_close(win, true)`, then wipes the buffer if still valid.
  - `window.is_open(win) -> boolean`.

- [ ] **Step 1: Write the failing spec**

```lua
local fakevim = require("spec.fakevim")
local window = require("diffundo.window")

describe("window.open", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
  end)

  it("creates a focused float with the config and winbar", function()
    local win = window.open({ lines = { "one", "two" }, title = "diffundo history", width = 40 })

    assert.are.equal(win, vim.current_win)
    local config = vim.windows[win].config
    assert.are.equal("editor", config.relative)
    assert.are.equal(0, config.row)
    assert.are.equal(0, config.col)
    assert.are.equal(40, config.width)
    assert.are.equal(2, config.height)
    assert.are.equal("diffundo history", vim.windows[win].options.winbar)
  end)

  it("configures a scratch buffer and fills the lines", function()
    local win = window.open({ lines = { "one", "two" }, title = "t", width = 40 })
    local buffer = vim.buffers[vim.windows[win].buf]

    assert.are.equal("nofile", buffer.options.buftype)
    assert.are.equal("wipe", buffer.options.bufhidden)
    assert.are.same({ "one", "two" }, buffer.lines)
  end)

  it("caps the height at the terminal", function()
    vim.o.lines = 5
    local win = window.open({ lines = { "a", "b", "c" }, title = "t", width = 40 })

    assert.are.equal(1, vim.windows[win].config.height)
  end)
end)

describe("window.render and window.map", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
  end)

  it("replaces lines and re-heights", function()
    local win = window.open({ lines = { "one" }, title = "t", width = 40 })

    window.render(win, { "one", "two", "three" })

    assert.are.same({ "one", "two", "three" }, vim.buffers[vim.windows[win].buf].lines)
    assert.are.equal(3, vim.windows[win].config.height)
  end)

  it("binds a normal-mode keymap to the buffer", function()
    local win = window.open({ lines = { "one" }, title = "t", width = 40 })
    local called = false

    window.map(win, "q", function() called = true end)
    vim.current_win = win
    vim:press("q")

    assert.is_true(called)
  end)
end)

describe("window.close and window.is_open", function()
  it("closes the float and wipes its buffer", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()

    local win = window.open({ lines = { "one" }, title = "t", width = 40 })
    local buf = vim.windows[win].buf

    window.close(win)

    assert.is_false(window.is_open(win))
    assert.is_nil(vim.buffers[buf])
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/window_spec.lua`
Expected: FAIL — `module 'diffundo.window' not found`.

- [ ] **Step 3: Write the implementation**

```lua
local M = {}

---@param opts { lines: string[], title: string, width: integer }
---@return integer
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = opts.width,
    height = math.max(1, math.min(#opts.lines, vim.o.lines - 4)),
  })
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.wo.winbar = opts.title
  M.render(win, opts.lines)
  return win
end

---@param win integer
---@param lines string[]
function M.render(win, lines)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, lines)
  vim.api.nvim_win_set_config(win, {
    height = math.max(1, math.min(#lines, vim.o.lines - 4)),
  })
end

---@param win integer
---@param lhs string
---@param fn fun()
function M.map(win, lhs, fn)
  vim.api.nvim_buf_set_keymap(vim.api.nvim_win_get_buf(win), "n", lhs, "", {
    callback = fn,
    silent = true,
  })
end

---@param win integer
function M.close(win)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_close(win, true)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

---@param win integer|nil
---@return boolean
function M.is_open(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

return M
```

- [ ] **Step 4: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/window_spec.lua && make ci`
Expected: PASS, ci green.

- [ ] **Step 5: Commit**

```bash
git add lua/diffundo/window.lua spec/window_spec.lua
git commit -m "Adds the floating window for the history sidebar

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `sidebar.lua` — the controller

**Files:**
- Create: `lua/diffundo/sidebar.lua`
- Create: `spec/sidebar_spec.lua`

**Interfaces:**
- Consumes: `history.rows/render/next/filtered`, `pattern.compile`, `restore.within_source`, `split.is_open/open/place/window_of_buffer`, `window.open/render/map/close/is_open`.
- Produces (`require("diffundo.sidebar")`), with tab state under `t:diffundo_history_*` (`win`, `source_win`, `rows`, `view`, `filter`):
  - `sidebar.open() -> boolean` — focus if already open; else notify "No changes to view!" and return `false` when there is no undo history; else record the current window as source, collect `history.rows({})` with the source buffer current, open the float, bind `J`/`K`/`<cr>`/`/`/`q`/`<esc>`, and put the cursor on the row for `t:diffundo_diff_undonr` (else row 1).
  - `sidebar.close()` — closes the float, clears `t:diffundo_history_*`, returns focus to the recorded source window.
  - `sidebar.toggle()`.
  - `sidebar.reveal(seq)` — open (via `M.open`) if absent; move the cursor to `seq`'s row in the current view; if `seq` is not in the view (filtered out or beyond the cap), clear the filter, re-render the full list, then select.
  - `sidebar.place()` — `<cr>`: the row under the cursor (ignoring the sentinel), focus the source (the diff's source window when a split is open, else the recorded source window), `split.open()` if needed, then `restore.within_source` of `silent undo <seq>`, read lines, `split.place(lines, seq)`, return focus to the float. The float stays open.
  - `sidebar.move_save(dir: 1|-1)` — `history.next(view, cursor, {dir, written = true})`.
  - `sidebar.filter()` — prompt `vim.fn.input("filter: ")`; empty clears (full view), else `pattern.compile` + `history.filtered`; re-render.
- Note on `place()` and the source cursor: like `earlier`/`later` today, placing runs `:undo` through the source buffer and may move its cursor; that is accepted behaviour for v1.

- [ ] **Step 1: Write the failing spec**

```lua
local fakevim = require("spec.fakevim")
local sidebar = require("diffundo.sidebar")
local split = require("diffundo.split")

local function history()
  return fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } })
end

---@param vim table
---@return integer|nil
local function float_win(vim)
  return vim.t.diffundo_history_win
end

describe("sidebar.open", function()
  local vim

  before_each(function()
    vim = fakevim.new(history())
    vim:install()
  end)

  it("opens a focused float", function()
    assert.is_true(sidebar.open())

    local win = float_win(vim)
    assert.is_not_nil(win)
    assert.are.equal(win, vim.current_win)
    assert.are.equal("nofile", vim.buffers[vim.windows[win].buf].options.buftype)
  end)

  it("renders one line per state, newest first", function()
    sidebar.open()

    local lines = vim.buffers[vim.windows[float_win(vim)].buf].lines
    assert.are.equal(3, #lines)
    assert.matches("%- 3", lines[1])
    assert.matches("%- 1", lines[3])
  end)

  it("lands the cursor on the current diff state", function()
    split.open()
    sidebar.open()

    assert.are.same({ 1, 0 }, vim.windows[float_win(vim)].cursor)
  end)

  it("refuses an empty history", function()
    local empty = fakevim.new(fakevim.history({ {} }))
    empty:install()

    assert.is_false(sidebar.open())
    assert.are.equal("No changes to view!", empty:last_notification())
    assert.is_nil(empty.t.diffundo_history_win)
  end)

  it("refocuses when already open", function()
    sidebar.open()
    local win = float_win(vim)
    vim.current_win = 1000

    sidebar.open()

    assert.are.equal(win, float_win(vim))
    assert.are.equal(win, vim.current_win)
    assert.are.equal(6, #vim.keymaps[vim.windows[win].buf])
  end)
end)

describe("sidebar.reveal and the filter", function()
  local vim

  before_each(function()
    vim = fakevim.new(history())
    vim:install()
    sidebar.open()
  end)

  it("moves the cursor to the given seq", function()
    sidebar.reveal(1)

    assert.are.same({ 3, 0 }, vim.windows[float_win(vim)].cursor)
  end)

  it("clears the filter to reveal a filtered-out seq", function()
    vim.fn.input = function() return "b" end
    sidebar.filter()
    assert.are.equal(1, #vim.buffers[vim.windows[float_win(vim)].buf].lines)

    sidebar.reveal(3)

    assert.are.equal(3, #vim.buffers[vim.windows[float_win(vim)].buf].lines)
    assert.are.same({ 1, 0 }, vim.windows[float_win(vim)].cursor)
  end)
end)

describe("sidebar.place", function()
  it("shows the selected state in the diff split and keeps the float", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()
    sidebar.open()
    sidebar.reveal(1)
    local win = float_win(vim)

    sidebar.place()

    assert.are.same({ "a" }, vim:diff_buffer().lines)
    assert.are.equal(1, vim.t.diffundo_diff_undonr)
    assert.are.equal(win, float_win(vim))
    assert.are.equal(win, vim.current_win)
  end)

  it("opens the split itself for a standalone float", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()
    sidebar.reveal(2)

    sidebar.place()

    assert.are.equal(2, vim.t.diffundo_diff_undonr)
    assert.are.equal(vim.source_bn, vim.t.diffundo_source_bn)
    assert.are.same({ "a", "b" }, vim:diff_buffer().lines)
  end)

  it("ignores the sentinel row", function()
    vim.t.diffundo_history_rows = { { seq = 0, added = {}, removed = {} } }
    vim.t.diffundo_history_view = vim.t.diffundo_history_rows
    vim.api.nvim_win_set_cursor(float_win(vim), { 1, 0 })

    assert.is_true(pcall(sidebar.place))
    assert.are.equal(3, vim.t.diffundo_diff_undonr)
  end)
end)

describe("sidebar.move_save and sidebar.filter", function()
  local vim

  before_each(function()
    vim = fakevim.new(history())
    vim:install()
    split.open()
  end)

  it("jumps between saved states", function()
    vim.history:branch(3, { "a", "b", "c", "d" }, { save = 1 })
    sidebar.open()
    vim.api.nvim_win_set_cursor(float_win(vim), { 2, 0 })

    sidebar.move_save(-1)

    assert.are.same({ 1, 0 }, vim.windows[float_win(vim)].cursor)
  end)

  it("narrows the list and clears on an empty prompt", function()
    sidebar.open()
    vim.fn.input = function() return "b" end
    sidebar.filter()

    local buf = vim.buffers[vim.windows[float_win(vim)].buf]
    assert.are.equal(1, #buf.lines)
    assert.matches("b", buf.lines[1])

    vim.fn.input = function() return "" end
    sidebar.filter()

    assert.are.equal(3, #vim.buffers[vim.windows[float_win(vim)].buf].lines)
  end)
end)

describe("sidebar.close and sidebar.toggle", function()
  it("closes and returns focus to the source", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()
    local source = vim.t.diffundo_history_source_win

    sidebar.close()

    assert.is_nil(vim.t.diffundo_history_win)
    assert.are.equal(source, vim.current_win)
  end)

  it("toggles open and closed", function()
    local vim = fakevim.new(history())
    vim:install()

    assert.is_nil(vim.t.diffundo_history_win)
    sidebar.toggle()
    assert.is_not_nil(vim.t.diffundo_history_win)
    sidebar.toggle()
    assert.is_nil(vim.t.diffundo_history_win)
  end)
end)
```

Walkthrough of the tricky expectations so the implementer knows they are deliberate:
- "lands the cursor on the current diff state": `split.open()` records `t:diffundo_diff_undonr = changenr()` = 3 (the fake starts on the newest state), and seq 3 is row 1 (newest first) — cursor `{1, 0}`.
- "jumps between saved states": after the branch (seq 4, `save = 1`) the walk re-runs only when the sidebar opens *after* the branch. Rows are `[4(save), 3, 2, 1]`, opening lands the cursor on seq 4 (row 1); the test parks the cursor on row 2 (`{2, 0}`) and asks `move_save(-1)`, which finds seq 4 again — `{1, 0}`.
- "ignores the sentinel row": `place` returns at the `row.seq == 0` guard before touching the split; `pcall` returns `true, nil`, and `t:diffundo_diff_undonr` is still 3.

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/sidebar_spec.lua`
Expected: FAIL — `module 'diffundo.sidebar' not found`.

- [ ] **Step 3: Write the implementation**

```lua
local history = require("diffundo.history")
local pattern = require("diffundo.pattern")
local restore = require("diffundo.restore")
local split = require("diffundo.split")
local window = require("diffundo.window")

local M = {}

---@return integer|nil
local function win()
  return vim.t.diffundo_history_win
end

---@return diffundo.Row[]
local function rows()
  return vim.t.diffundo_history_rows or {}
end

---@return diffundo.Row[]
local function view()
  return vim.t.diffundo_history_view or rows()
end

---@param seq integer|nil
---@return integer|nil
local function index_of_seq(seq)
  for index, row in ipairs(view()) do
    if row.seq == seq then
      return index
    end
  end
  return nil
end

---@return integer
local function pick_source()
  if split.is_open() then
    local found = split.window_of_buffer(vim.t.diffundo_source_bn)
    if found then
      return found
    end
  end
  return vim.t.diffundo_history_source_win or vim.api.nvim_get_current_win()
end

---@return string[]
local function rendered_lines()
  local width = vim.g.diffundo_history_width or 40
  local lines = {}
  for index, row in ipairs(view()) do
    lines[index] = history.render(row, width)
  end
  return lines
end

---@param seq integer|nil
local function select(seq)
  local index = index_of_seq(seq)
  if index then
    vim.api.nvim_win_set_cursor(win(), { index, 0 })
  end
end

---@return boolean
function M.open()
  local current = win()
  if current and window.is_open(current) then
    vim.api.nvim_set_current_win(current)
    return true
  end
  if vim.fn.undotree().seq_last == 0 then
    vim.notify("No changes to view!")
    return false
  end
  local source = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(source)
  local collected = history.rows({})
  vim.t.diffundo_history_source_win = source
  vim.t.diffundo_history_rows = collected
  vim.t.diffundo_history_view = collected
  vim.t.diffundo_history_filter = nil
  local float = window.open({
    lines = rendered_lines(),
    title = "diffundo history",
    width = vim.g.diffundo_history_width or 40,
  })
  vim.t.diffundo_history_win = float
  window.map(float, "J", function() M.move_save(1) end)
  window.map(float, "K", function() M.move_save(-1) end)
  window.map(float, "<cr>", function() M.place() end)
  window.map(float, "/", function() M.filter() end)
  window.map(float, "q", function() M.close() end)
  window.map(float, "<esc>", function() M.close() end)
  select(vim.t.diffundo_diff_undonr)
  return true
end

---@param seq integer
function M.reveal(seq)
  if not M.open() then
    return
  end
  if index_of_seq(seq) == nil then
    vim.t.diffundo_history_filter = nil
    vim.t.diffundo_history_view = rows()
    window.render(win(), rendered_lines())
  end
  select(seq)
end

function M.place()
  local float = win()
  local index = float and vim.api.nvim_win_get_cursor(float)[1] or 1
  local row = view()[index]
  if row == nil or row.seq == 0 then
    return
  end
  local source = pick_source()
  vim.api.nvim_set_current_win(source)
  if not split.open() then
    return
  end
  restore.within_source(function()
    vim.cmd("silent undo " .. row.seq)
    split.place(vim.api.nvim_buf_get_lines(0, 0, -1, false), row.seq)
  end)
  if float and window.is_open(float) then
    vim.api.nvim_set_current_win(float)
  end
end

---@param dir integer
function M.move_save(dir)
  local float = win()
  if float == nil or not window.is_open(float) then
    return
  end
  local index = vim.api.nvim_win_get_cursor(float)[1]
  local moved = history.next(view(), index, { dir = dir, written = true })
  if moved ~= index then
    vim.api.nvim_win_set_cursor(float, { moved, 0 })
  end
end

function M.filter()
  local asked = vim.fn.input("filter: ")
  if asked == "" then
    vim.t.diffundo_history_filter = nil
    vim.t.diffundo_history_view = rows()
  else
    vim.t.diffundo_history_filter = pattern.compile(asked)
    vim.t.diffundo_history_view = history.filtered(rows(), vim.t.diffundo_history_filter)
  end
  if window.is_open(win()) then
    window.render(win(), rendered_lines())
  end
end

function M.close()
  local float = win()
  if float == nil then
    return
  end
  local fallback = vim.t.diffundo_history_source_win or vim.api.nvim_get_current_win()
  if window.is_open(float) then
    window.close(float)
  end
  vim.t.diffundo_history_win = nil
  vim.t.diffundo_history_source_win = nil
  vim.t.diffundo_history_rows = nil
  vim.t.diffundo_history_view = nil
  vim.t.diffundo_history_filter = nil
  if window.is_open(fallback) then
    vim.api.nvim_set_current_win(fallback)
  end
end

function M.toggle()
  if window.is_open(win()) then
    M.close()
  else
    M.open()
  end
end

return M
```

- [ ] **Step 4: Run the spec and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/sidebar_spec.lua && make ci`
Expected: PASS, ci green. If `M.open` exceeds complexity 5, extract the six `window.map` calls into a local `bind(float)`.

- [ ] **Step 5: Commit**

```bash
git add lua/diffundo/sidebar.lua spec/sidebar_spec.lua
git commit -m "Adds the history sidebar controller

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Wire the command layer — `history` subcommand, `-no-history`, reveal

**Files:**
- Modify: `lua/diffundo/subcommand.lua` (`-no-history` flag, `history` name, completion)
- Modify: `spec/subcommand_spec.lua`
- Modify: `lua/diffundo/init.lua` (`dispatch` handles `history`; `command` reveals after successful actions unless suppressed)
- Modify: `spec/init_spec.lua`
- Note: `plugin/diffundo.lua` already calls `subcommand.complete` — no change.

**Interfaces:**
- Consumes: `sidebar.toggle/open/reveal`, `split.is_open`, `vim.g.diffundo_history`.
- Produces:
  - `---@class diffundo.Subcommand` gains `no_history: boolean`.
  - `subcommand.parse("-no-history earlier 2")` -> `{ name = "earlier", bang = false, rest = "2", no_history = true }`; `subcommand.parse("history")` -> `{ name = "history", ... }`; a bare `-no-history` with no subcommand -> `nil`.
  - `subcommand.names` = `{ "earlier", "later", "search", "search!", "history" }`; `subcommand.flags` = `{ "-no-history" }`. `complete` returns names for a letter prefix and flags for a `-` prefix.
  - `M.command` reveals the sidebar after a successful `earlier`/`later` (when the split is open) and after a `search` hit, unless `sub.no_history` or `vim.g.diffundo_history == false`.

- [ ] **Step 1: Rewrite `spec/subcommand_spec.lua`**

```lua
local subcommand = require("diffundo.subcommand")

describe("subcommand.parse", function()
  it("parses a bare subcommand", function()
    assert.are.same(
      { name = "earlier", bang = false, rest = "", no_history = false },
      subcommand.parse("earlier")
    )
  end)

  it("passes the rest verbatim, spaces included", function()
    assert.are.same(
      { name = "search", bang = false, rest = "foo  bar", no_history = false },
      subcommand.parse("search foo  bar")
    )
  end)

  it("accepts a bang on search", function()
    assert.are.same(
      { name = "search", bang = true, rest = "x", no_history = false },
      subcommand.parse("search! x")
    )
  end)

  it("rejects a bang on earlier and history", function()
    assert.is_nil(subcommand.parse("earlier! 2"))
    assert.is_nil(subcommand.parse("history!"))
  end)

  it("accepts a leading -no-history flag", function()
    assert.are.same(
      { name = "earlier", bang = false, rest = "2", no_history = true },
      subcommand.parse("-no-history earlier 2")
    )
    assert.are.same(
      { name = "search", bang = false, rest = "x", no_history = true },
      subcommand.parse("-no-history   search x")
    )
  end)

  it("rejects a flag with no subcommand", function()
    assert.is_nil(subcommand.parse("-no-history"))
  end)

  it("rejects unknown and missing subcommands", function()
    assert.is_nil(subcommand.parse("nonesuch"))
    assert.is_nil(subcommand.parse(""))
    assert.is_nil(subcommand.parse("   "))
  end)

  it("ignores leading whitespace", function()
    assert.are.same(
      { name = "later", bang = false, rest = "2f", no_history = false },
      subcommand.parse("  later 2f")
    )
  end)

  it("parses the history subcommand", function()
    assert.are.same(
      { name = "history", bang = false, rest = "", no_history = false },
      subcommand.parse("history")
    )
  end)
end)

describe("subcommand.complete", function()
  it("offers every name for an empty first argument", function()
    assert.are.same(
      { "earlier", "later", "search", "search!", "history" },
      subcommand.complete("", "Diffundo ")
    )
  end)

  it("offers the flag for a dash prefix", function()
    assert.are.same({ "-no-history" }, subcommand.complete("-", "Diffundo -"))
  end)

  it("filters by prefix", function()
    assert.are.same({ "search", "search!" }, subcommand.complete("se", "Diffundo se"))
  end)

  it("offers nothing past the first argument", function()
    assert.are.same({}, subcommand.complete("", "Diffundo search "))
  end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/subcommand_spec.lua`
Expected: FAIL — flag and `history` not parsed; completion lists differ.

- [ ] **Step 3: Rewrite `lua/diffundo/subcommand.lua`**

```lua
local M = {}

---@class diffundo.Subcommand
---@field name string
---@field bang boolean
---@field rest string
---@field no_history boolean

M.names = { "earlier", "later", "search", "search!", "history" }
M.flags = { "-no-history" }

local takes_bang = { earlier = false, later = false, search = true, history = false }

---@param head string
---@param rest string
---@return diffundo.Subcommand|nil
local function finish(head, rest)
  local name, bang = head:match("^(%a+)(!?)$")
  local allowed = name and takes_bang[name]
  if allowed == nil or (bang == "!" and not allowed) then
    return nil
  end
  return { name = name, bang = bang == "!", rest = rest, no_history = false }
end

---@param args string
---@return diffundo.Subcommand|nil
function M.parse(args)
  local head, rest = args:match("^%s*(%S+)%s?(.*)$")
  if head == nil then
    return nil
  end
  local parsed = finish(head, rest)
  if parsed == nil and head == "-no-history" then
    local second, tail = rest:match("^(%S+)%s?(.*)$")
    if second == nil then
      return nil
    end
    parsed = finish(second, tail)
    if parsed then
      parsed.no_history = true
    end
  end
  return parsed
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local before = cmdline:sub(1, #cmdline - #arglead)
  if not before:match("^%s*%S+%s+$") then
    return {}
  end
  local candidates = {}
  local pool = arglead:sub(1, 1) == "-" and M.flags or M.names
  for _, candidate in ipairs(pool) do
    if candidate:sub(1, #arglead) == arglead then
      table.insert(candidates, candidate)
    end
  end
  return candidates
end

return M
```

- [ ] **Step 4: Run the subcommand spec**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/subcommand_spec.lua`
Expected: PASS.

- [ ] **Step 5: Add a dedicated command-block to `spec/init_spec.lua`**

The existing `describe("command", ...)` tests assert dispatch, errors and the source cursor. With the float opening by default, every test that asserts the source window is current must close the float first. Read the current block and:
- update the unknown-subcommand message expectation to the new list:
  `'diffundo: unknown subcommand "nonesuch" (earlier, later, search, search!, history)'`;
- in tests that assert `vim.current_win` is the source window (for example "moves the source cursor onto the match"), insert `diffundo.command("history")` right before the assertion so the float gives focus back.

Then append a new block exercising the float integration with its own fixture (module-level `diffundo` state like `last_args` persists across tests, but `vim.t` is per-fake, so the new block is order-independent):

```lua
describe("the history float from commands", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "first" }, { "first", "second" } }))
    vim:install()
  end)

  it("opens by default after earlier and lands on the shown state", function()
    diffundo.command("earlier")

    assert.are.equal(2, vim.t.diffundo_diff_undonr)
    assert.are.equal(vim.t.diffundo_history_win, vim.current_win)
    assert.are.same({ 1, 0 }, vim.windows[vim.t.diffundo_history_win].cursor)
  end)

  it("the -no-history flag leaves the float closed", function()
    diffundo.command("-no-history earlier")

    assert.are.equal(2, vim.t.diffundo_diff_undonr)
    assert.is_nil(vim.t.diffundo_history_win)
  end)

  it("reveals a search hit at its row", function()
    diffundo.command("search first")

    assert.are.same({ 2, 0 }, vim.windows[vim.t.diffundo_history_win].cursor)
  end)

  it("history toggles and does not disturb the diff", function()
    diffundo.command("earlier")
    diffundo.command("-no-history later")

    assert.are.equal(3, vim.t.diffundo_diff_undonr)
    assert.are.equal(vim.t.diffundo_history_win, vim.current_win)
  end)
end)
```

Walkthrough of the expectations: with states `{}, {"first"}, {"first", "second"}` and the fake on the newest state, `earlier` shows seq 2 (row 1, newest first) and `search first` hits seq 1 (row 2) — hence `{1, 0}` and `{2, 0}`. `history` toggles open; `-no-history later` moves the diff to seq 3 and leaves the already-open float untouched (still current).

- [ ] **Step 6: Update `lua/diffundo/init.lua`**

Add `local sidebar = require("diffundo.sidebar")` to the requires (alphabetical, after `split`). In `dispatch`, add at the top:

```lua
  if sub.name == "history" then
    sidebar.toggle()
    return nil
  end
```

Replace the tail of `M.command` (from `local ok, hit = pcall(dispatch, sub)` on) with:

```lua
  local ok, hit = pcall(dispatch, sub)
  if not ok then
    vim.notify("diffundo: " .. tostring(hit))
    return
  end
  if sub.name == "search" then
    finish_search(sub, hit)
  end
  if sub.name == "history" or (sub.name == "search" and hit == nil) then
    return
  end
  if sub.no_history or vim.g.diffundo_history == false then
    return
  end
  if sub.name == "search" then
    sidebar.reveal(hit.seq)
  elseif split.is_open() then
    sidebar.reveal(vim.t.diffundo_diff_undonr)
  end
```

(`history` returns before any reveal; a `search` miss leaves the float untouched per the spec.)

- [ ] **Step 7: Run the specs and `make ci`**

Run: `eval $(luarocks --tree lua_modules path --bin) && busted spec/subcommand_spec.lua spec/init_spec.lua spec/sidebar_spec.lua && make ci`
Expected: PASS, ci green.

- [ ] **Step 8: Commit**

```bash
git add lua/diffundo/subcommand.lua spec/subcommand_spec.lua lua/diffundo/init.lua spec/init_spec.lua
git commit -m "Shows the history float from :Diffundo by default

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: End-to-end coverage in a real neovim

**Files:**
- Modify: `tests/e2e/diffundo_test.ts`

**Interfaces:**
- Consumes: `:Diffundo` and the float from Tasks 5-7, the existing `prelude`, `buildHistory`, `appendState`, `setState`, `assertCursor`, `assertNoMatch`, `pressDot`.
- Verified nvim facts the tests rely on: floats count in `winnr('$')`; a float is `nvim_win_get_config(w).relative == "editor"`; `:only` errors (E5601) while a float is open.

- [ ] **Step 1: Add float-aware helpers**

After `windowStates`, add:

```ts
async function winIds(denops: Denops): Promise<number[]> {
  return await denops.call("nvim_list_wins") as number[];
}

async function isFloat(denops: Denops, win: number): Promise<boolean> {
  const config = await denops.call("nvim_win_get_config", win) as {
    relative?: string;
  };
  return config.relative === "editor";
}
```

After `assertSourceAlone`, add:

```ts
// WHY: :Diffundo now opens the floating history by default.
async function assertHistory(
  denops: Denops,
  expected: string[],
): Promise<void> {
  await assertNoErrors(denops);
  const wins = await winIds(denops);
  const floats: number[] = [];
  for (const win of wins) {
    if (await isFloat(denops, win)) floats.push(win);
  }
  assertEquals(floats.length, 1, "expected exactly one history float");
  const buf = await denops.call("nvim_win_get_buf", floats[0]) as number;
  const lines = await denops.call("nvim_buf_get_lines", buf, 0, -1, false) as string[];
  assertEquals(lines, expected);
  // WHY: the user lands in the float, keyboard-first.
  assertEquals(await denops.call("nvim_get_current_win"), floats[0]);
}

// WHY: :only errors (E5601) while a float is open.
async function closeHistory(denops: Denops): Promise<void> {
  await denops.cmd("Diffundo history");
}
```

- [ ] **Step 2: Update the existing tests for the float**

- In `assertDiffSplit`, delete `assertEquals(await denops.call("winnr", "$"), 2);` and instead require the split pair plus exactly one float:

```ts
  const wins = await winIds(denops);
  const floats = wins.filter((w) => isFloat(denops, w) === true);
  assertEquals(floats.length, 1);
```

  (Move the `wins`/`isFloat` helpers above `assertDiffSplit` if needed — they are module-level functions, so ordering is fine.)
- In every test that calls `:only`, insert `await closeHistory(denops);` immediately before `await denops.cmd("only")` so the float is gone first (E5601).
- In the tests that assert the source cursor after a command (the two repeat tests and the `search` tests), the float holds focus afterwards. Insert `await closeHistory(denops);` before the `assertCursor`/window-content assertions that run while the current window would be the float. Do **not** add it where the test asserts the float's own state.

- [ ] **Step 3: Add the new float tests at the end of the file**

```ts
test({
  mode: "nvim",
  name: ":Diffundo history toggles a floating sidebar on and off",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);

    await denops.cmd("Diffundo history");

    const lines = await denops.eval(
      "getbufline(winbufnr(0), 1, '$')",
    ) as string[];
    assert(lines.length >= 1, "the float shows the newest state first");
    assert(lines[0].endsWith("- 2"), lines[0]);
    await assertHistory(denops, lines);

    await denops.cmd("Diffundo history");
    // WHY: toggled off, the current window is the source again.
    assertEquals((await denops.eval("&buftype")) as string, "");
  },
});

test({
  mode: "nvim",
  name: "moving in the history and confirming with <cr> changes the diff",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
    ]);

    await denops.cmd("Diffundo earlier");

    // WHY: the float is current and shows the state the diff shows (seq 2).
    assertEquals(await denops.eval("[line('.'), col('.')]"), [1, 1]);
    // Move to the oldest row and confirm it into the diff.
    await denops.call("feedkeys", "jj<cr>", "x");

    const window = (await windowStates(denops)).find((w) => w.buftype === "nofile");
    assert(window, "diff split still open");
    assertEquals(window.lines, ["one"]);
    assertEquals(await denops.eval("t:diffundo_diff_undonr"), 1);
  },
});

test({
  mode: "nvim",
  name: ":Diffundo -no-history earlier keeps the minimal layout",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);

    await denops.cmd("Diffundo -no-history earlier");

    const floats: number[] = [];
    for (const win of await winIds(denops)) {
      if (await isFloat(denops, win)) floats.push(win);
    }
    assertEquals(floats.length, 0, "no history float with -no-history");
    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two"],
      undonr: 1,
    });
  },
});
```

- [ ] **Step 4: Run the e2e suite and resolve behaviour drift**

Run: `make e2e`
Expected: PASS. If `feedkeys("jj<cr>", "x")` does not reach the float's `<cr>` map in one pass (typeahead timing), split it into two RPC calls:

```ts
    await denops.call("feedkeys", "jj", "x");
    await denops.call("feedkeys", "<cr>", "x");
```

And if the exact row label assertion (`endsWith("- 2")`) is brittle across the label format, relax it to `assert(/-\s*\d+$/.test(lines[0]), lines[0])`.

- [ ] **Step 5: Run `make ci` and commit**

```bash
make ci
git add tests/e2e/diffundo_test.ts
git commit -m "Covers the history sidebar end to end in a real neovim

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation and ADR

**Files:**
- Modify: `README.md` (Commands, a "History sidebar" section, Setup)
- Modify: `doc/diffundo.txt`
- Create: `docs/adr/0005-history-sidebar.md`
- Commit: `docs/superpowers/specs/2026-09-22-history-sidebar-design.md` and this plan file

- [ ] **Step 1: Update the README**

In the Commands section, append to the `:Diffundo` list:

```markdown
*:Diffundo history* : toggle the floating history sidebar — one line per undo
state with a one-line preview of what that edit changed.

In the sidebar: *j*/*k* move by change (or use counts, *gg*/*G*), *J*/*K* move
between written states, *<cr>* shows the selected state in the diff split,
*/* filters the list (vim regex, empty to clear), *q*/*<esc>* closes it.
```

Add above Setup:

```markdown
History sidebar
---------------

`:Diffundo earlier/later/search` open the history float by default;
`:Diffundo -no-history rather` (or `g:diffundo_history` = `false`) keeps the
minimal layout. `g:diffundo_history_width` (default 40) sets the width. The
float's rows come from `require("diffundo.history").rows`, the same list the
future telescope/quickfix front-ends reuse.
```

- [ ] **Step 2: Update `doc/diffundo.txt`**

Add a `:Diffundo history` entry to section 1 (with the sidebar keys), and a sentence in section 2 that `require("diffundo.history").rows` produces the list. Keep the trailer `vim:tw=78:ts=8:ft=help:norl:`.

- [ ] **Step 3: Write `docs/adr/0005-history-sidebar.md`**

```markdown
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
```

- [ ] **Step 4: Verify the help file loads**

Run: `nvim --headless -u NONE --cmd "set rtp^=$PWD" -c "helptags doc" -c "help :Diffundo-history" -c "qa!" 2>&1`
Expected: no `E149`. Remove the generated `doc/tags` and ensure it is ignored (add `doc/tags` to `.gitignore` if not present).

- [ ] **Step 5: Run `make ci` and commit**

```bash
make ci
git add README.md doc/diffundo.txt docs/adr/0005-history-sidebar.md .gitignore docs/superpowers
git commit -m "Documents the history sidebar and the strict-<cr> display model

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Close the loop on GitHub (after the branch is merged)**

```bash
gh issue comment 8 --repo dsummersl/vim-diffundo --body "Sub-project 3 (sidebar) is done: \`:Diffundo history\`, the \`-no-history\` flag, and \`lua/diffundo/history.lua\`. Next: sub-project 2 (RCS labels) drops into \`history.Row.label\`."
```
