local cache = require("diffundo.cache")
local fakevim = require("spec.fakevim")
local pane = require("diffundo.pane")
local restore = require("diffundo.restore")
local split = require("diffundo.split")

local function history()
  return fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } })
end

---@param vim table
---@param seq integer
local function show(vim, seq)
  split.open()
  restore.within_source(function()
    vim.cmd("silent undo " .. seq)
    split.place(vim.api.nvim_buf_get_lines(0, 0, -1, false), seq)
  end)
end

---@param vim table
---@return integer
local function undo_count(vim)
  local count = 0
  for _, command in ipairs(vim.commands) do
    if command:match("^silent undo ") then
      count = count + 1
    end
  end
  return count
end

---@param vim table
---@return table
local function config(vim)
  return vim.windows[vim:pane_window()].config
end

local vim

before_each(function()
  vim = fakevim.new(history())
  vim:install()
  cache.reset(vim.source_bn)
end)

describe("pane.render", function()
  it("opens an unfocused float in the diff window's lower right corner", function()
    show(vim, 2)
    local source = vim.current_win

    pane.render()

    assert.are.equal(source, vim.current_win)
    local diff = vim:window_of_buffer(vim.t.diffundo_diff_bn)
    local found = config(vim)
    assert.are.equal("win", found.relative)
    assert.are.equal(diff, found.win)
    assert.are.equal("SE", found.anchor)
    assert.are.equal(38, found.row)
    assert.are.equal(40, found.col)
    assert.are.equal(38, found.width)
    assert.are.equal(3, found.height)
    assert.are.equal("rounded", found.border)
    assert.is_false(found.focusable)
  end)

  it("titles the pane with the diff's state and footers it with the diff size", function()
    vim.g.diffundo_date_format = "%Y"
    show(vim, 1)

    pane.render()

    local found = config(vim)
    assert.are.equal(" #1  " .. os.date("%Y", vim.history.entries[1].time) .. " ", found.title)
    assert.are.equal(" +2 -0 lines ", found.footer)
  end)

  it("titles #0 without a date", function()
    show(vim, 0)

    pane.render()

    assert.are.equal(" #0 ", config(vim).title)
    assert.are.equal(" +3 -0 lines ", config(vim).footer)
  end)

  it("honors g:diffundo_history_width and g:diffundo_glyphs", function()
    vim.g.diffundo_history_width = 20
    vim.g.diffundo_glyphs = { buffer = "B" }
    show(vim, 2)

    pane.render()

    assert.are.equal(20, config(vim).width)
    assert.are.equal("B + c             #3", vim:pane_lines()[1])
  end)

  it("flips to the upper right when the cursor row would sit under it", function()
    show(vim, 2)
    vim.winline = 36

    pane.render()

    assert.are.equal("NE", config(vim).anchor)
    assert.are.equal(0, config(vim).row)
  end)

  it("moves back down when the cursor leaves the corner", function()
    show(vim, 2)
    vim.winline = 36
    pane.render()
    vim.winline = 2

    vim:fire("CursorMoved", { buffer = vim.source_bn })

    assert.are.equal("SE", config(vim).anchor)
    assert.are.equal(38, config(vim).row)
  end)

  it("paints the rows and defines its highlight groups", function()
    show(vim, 2)

    pane.render()

    assert.is_true(#vim.highlights > 0)
    assert.are.same({ link = "Comment", default = true }, vim.hl_groups.DiffundoGap)
    assert.are.same(
      { link = "CursorLine", bold = true, default = true },
      vim.hl_groups.DiffundoDiff
    )
    assert.are.same({ bold = true, default = true }, vim.hl_groups.DiffundoBuffer)
  end)

  it("stays closed when g:diffundo_history is false", function()
    vim.g.diffundo_history = false
    show(vim, 2)

    pane.render()

    assert.is_nil(vim:pane_window())
  end)

  it("closes when the split is gone", function()
    show(vim, 2)
    pane.render()
    vim:close_window(vim:window_of_buffer(vim.t.diffundo_diff_bn))

    pane.render()

    assert.is_nil(vim:pane_window())
  end)

  it("reuses the rows and the diff state's lines while nothing changed", function()
    show(vim, 2)
    pane.render()
    vim.commands = {}

    pane.render()

    assert.are.equal(0, undo_count(vim))
  end)
end)

describe("the pane's autocmds", function()
  before_each(function()
    show(vim, 2)
    pane.render()
  end)

  it("follows a new edit in the source buffer", function()
    vim.history:branch(3, { "a", "b", "c", "d" })
    vim.buffers[vim.source_bn].lines = { "a", "b", "c", "d" }
    vim.buffers[vim.source_bn].tick = vim.buffers[vim.source_bn].tick + 1

    vim:fire("TextChanged", { buffer = vim.source_bn })

    assert.are.equal("@ + d                               #4", vim:pane_lines()[1])
    assert.are.equal(" +2 -0 lines ", config(vim).footer)
  end)

  it("closes with the diff window", function()
    local diff = vim:window_of_buffer(vim.t.diffundo_diff_bn)
    vim:close_window(diff)

    vim:fire("WinClosed", { pattern = tostring(diff) })

    assert.is_nil(vim:pane_window())
    assert.are.same({}, vim.autocmds)
  end)
end)

describe("pane.focus", function()
  before_each(function()
    show(vim, 2)
    pane.render()
    pane.focus()
  end)

  it("expands into the whole tree and lands on the diff's row", function()
    assert.are.equal(vim:pane_window(), vim.current_win)
    assert.are.same({
      "@ + c                               #3",
      "╷ + b                               #2",
      "╷ + a                               #1",
      "╷                                   #0",
    }, vim:pane_lines())
    assert.are.same({ 2, 0 }, vim.windows[vim:pane_window()].cursor)
    assert.is_true(config(vim).focusable)
    assert.is_true(vim.windows[vim:pane_window()].options.cursorline)
  end)

  it("titles and footers the row under the cursor", function()
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 4, 0 })

    vim:fire("CursorMoved", { buffer = vim.windows[vim:pane_window()].buf })

    assert.are.equal(" #0 ", config(vim).title)
    assert.are.equal(" +3 -0 lines ", config(vim).footer)
  end)

  it("remembers the diff sizes until the buffer changes", function()
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 3, 0 })
    pane.update_labels()
    vim.commands = {}
    local calls = 0
    local counted = vim.api.nvim_buf_get_changedtick
    vim.api.nvim_buf_get_changedtick = function(buf)
      calls = calls + 1
      return counted(buf)
    end

    pane.update_labels()

    assert.are.equal(0, undo_count(vim))
    assert.are.equal(1, calls)
    assert.are.equal(" +2 -0 lines ", config(vim).footer)
  end)

  it("<cr> shows the row under the cursor in the diff and stays in the pane", function()
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 3, 0 })

    vim:press("<cr>")

    assert.are.equal(1, vim.t.diffundo_diff_undonr)
    assert.are.same({ "a" }, vim:diff_buffer().lines)
    assert.are.equal(vim:pane_window(), vim.current_win)
  end)

  it("<cr> on nothing does nothing", function()
    vim.t.diffundo_pane_seqs = { -1 }
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 1, 0 })

    vim:press("<cr>")

    assert.are.equal(2, vim.t.diffundo_diff_undonr)
  end)

  it("q collapses and returns to the source window", function()
    vim:press("q")

    assert.are.equal(vim:window_of_buffer(vim.source_bn), vim.current_win)
    assert.are.equal(3, #vim:pane_lines())
    assert.is_false(config(vim).focusable)
  end)

  it("<esc> collapses too", function()
    vim:press("<esc>")

    assert.are.equal(3, #vim:pane_lines())
  end)

  it("collapses when another window is entered", function()
    local pane_buf = vim.windows[vim:pane_window()].buf
    vim.current_win = vim:window_of_buffer(vim.source_bn)

    vim:fire("WinLeave", { buffer = pane_buf })

    assert.are.equal(3, #vim:pane_lines())
  end)

  it("stays expanded when it is still the current window", function()
    vim:fire("WinLeave", { buffer = vim.windows[vim:pane_window()].buf })

    assert.are.equal(4, #vim:pane_lines())
  end)

  it("g? notifies the key list", function()
    vim:press("g?")

    assert.matches("J/K written", vim:last_notification())
  end)

  it("/ keeps only the matching rows with gap rows between and footers the filter", function()
    local asked = "b"
    vim.fn.input = function()
      return asked
    end

    vim:press("/")

    assert.are.same({
      "┆   1 undo",
      "╷ + b                               #2",
      "┆   1 undo",
    }, vim:pane_lines())
    assert.are.same({ 2, 0 }, vim.windows[vim:pane_window()].cursor)
    assert.are.equal(" filter: b ", config(vim).footer)

    asked = ""
    vim:press("/")
    assert.are.equal(4, #vim:pane_lines())
    assert.are.equal(" +1 -0 lines ", config(vim).footer)
  end)

  it("keeps the filter when it collapses", function()
    vim.fn.input = function()
      return "a"
    end
    vim:press("/")

    vim:press("q")

    assert.are.same(
      { "┆   2 undos", "╷ + a                               #1" },
      vim:pane_lines()
    )
    assert.are.equal(" filter: a ", config(vim).footer)
  end)
end)

describe("pane.set_filter", function()
  it("footers a removed-line filter with filter!", function()
    show(vim, 2)
    pane.set_filter("c", true)

    pane.render()

    assert.are.equal(" filter!: c ", config(vim).footer)
    assert.are.same({ "┆   3 undos" }, vim:pane_lines())
  end)

  it("rejects a bad pattern before storing it", function()
    vim.regex = function()
      error("Vim:E54: Unmatched \\(", 0)
    end

    assert.has_error(function()
      pane.set_filter("(", false)
    end)
    assert.is_nil(vim.t.diffundo_pane_filter)
  end)
end)

describe("pane.move_save", function()
  it("jumps between written states", function()
    vim.history.entries[3].save = 1
    vim.history.entries[1].save = 2
    show(vim, 2)
    pane.focus()
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 4, 0 })

    vim:press("K")
    assert.are.same({ 3, 0 }, vim.windows[vim:pane_window()].cursor)

    vim:press("K")
    assert.are.same({ 1, 0 }, vim.windows[vim:pane_window()].cursor)

    vim:press("J")
    assert.are.same({ 3, 0 }, vim.windows[vim:pane_window()].cursor)
  end)

  it("does nothing without a pane", function()
    assert.is_true(pcall(pane.move_save, 1))
  end)
end)

describe("pane folds", function()
  it("folds long branch stretches in the expanded pane with gap captions", function()
    local h = fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } })
    h:branch(2, { "x" })
    h:branch(4, { "x", "y" })
    h:branch(5, { "x", "y", "z" })
    h:branch(6, { "x", "y", "z", "w" })
    h:branch(7, { "x", "y", "z", "w", "v" })
    h:branch(8, { "x", "y", "z", "w", "v", "u" })
    h:branch(2, { "a", "b", "c", "d" })
    vim = fakevim.new(h)
    vim:install()
    cache.reset(vim.source_bn)
    show(vim, 10)

    pane.focus()

    assert.are.same({ { first = 3, last = 7 } }, vim.folds)
    assert.are.same({ ["3"] = "┆    5 undos" }, vim.t.diffundo_pane_captions)
    assert.are.equal(0, vim.windows[vim:pane_window()].options.foldlevel)
  end)

  it("keeps an opened fold open when <cr> shows a state inside it", function()
    local h = fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } })
    h:branch(2, { "x" })
    h:branch(4, { "x", "y" })
    h:branch(5, { "x", "y", "z" })
    h:branch(6, { "x", "y", "z", "w" })
    h:branch(7, { "x", "y", "z", "w", "v" })
    h:branch(8, { "x", "y", "z", "w", "v", "u" })
    h:branch(2, { "a", "b", "c", "d" })
    vim = fakevim.new(h)
    vim:install()
    cache.reset(vim.source_bn)
    show(vim, 10)
    pane.focus()
    vim.cmd("3,7foldopen")
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 5, 0 })

    vim:press("<cr>")

    assert.are.equal(6, vim.t.diffundo_diff_undonr)
    assert.are.equal(-1, vim.fn.foldclosed(5))
    assert.are.same({ 5, 0 }, vim.windows[vim:pane_window()].cursor)
  end)
end)

describe("pane.focus without a split", function()
  it("does nothing", function()
    pane.focus()

    assert.is_nil(vim:pane_window())
  end)
end)

describe("pane.close", function()
  it("is safe without a pane", function()
    assert.is_true(pcall(pane.close))
  end)
end)
