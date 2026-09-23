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

---@param vim table
---@return integer|nil
local function footer_win(vim)
  return vim.t.diffundo_history_footer_win
end

---@param map table|nil
---@return integer
local function count_keymaps(map)
  local n = 0
  for _ in pairs(map or {}) do
    n = n + 1
  end
  return n
end

describe("sidebar.open", function()
  local vim

  before_each(function()
    vim = fakevim.new(history())
    vim:install()
  end)

  it("opens a focused float with an unfocused footer", function()
    assert.is_true(sidebar.open())

    local win = float_win(vim)
    assert.are_not.equal(nil, win)
    assert.are.equal(win, vim.current_win)
    local footer = footer_win(vim)
    assert.are_not.equal(nil, footer)
    assert.are_not.equal(footer, vim.current_win)
    assert.are.equal("nofile", vim.buffers[vim.windows[win].buf].options.buftype)
  end)

  it("renders rows only in the tree and the footer in its own float", function()
    sidebar.open()

    local tree = vim.buffers[vim.windows[float_win(vim)].buf]
    local footer = vim.buffers[vim.windows[footer_win(vim)].buf]
    assert.are.equal(3, #tree.lines)
    assert.matches("^│%+ c", tree.lines[1])
    assert.matches("^│%+ b", tree.lines[2])
    assert.matches("^└%+ a", tree.lines[3])
    assert.are.equal(2, #footer.lines)
    assert.matches("^#", footer.lines[1])
    assert.matches("help: g%?", footer.lines[2])
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
    assert.are.equal(7, count_keymaps(vim.keymaps[vim.windows[win].buf]))
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
    vim.fn.input = function()
      return "b"
    end
    sidebar.filter()
    assert.are.equal(1, #vim.buffers[vim.windows[float_win(vim)].buf].lines)

    sidebar.reveal(3)

    assert.are.equal(3, #vim.buffers[vim.windows[float_win(vim)].buf].lines)
    assert.are.same({ 1, 0 }, vim.windows[float_win(vim)].cursor)
  end)

  it("keeps the floats rendering when the filter matches nothing", function()
    vim.fn.input = function()
      return "zzzz"
    end

    assert.is_true(pcall(sidebar.filter))

    local tree = vim.buffers[vim.windows[float_win(vim)].buf]
    local footer = vim.buffers[vim.windows[footer_win(vim)].buf]
    assert.are.equal(0, #tree.lines)
    assert.matches("no matches", footer.lines[1])
    assert.matches("0/3", footer.lines[2])
    assert.matches("help: g%?", footer.lines[2])
  end)
end)

describe("the float's keymaps", function()
  it("drives move, filter, place and close", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()

    vim:press("J")
    vim:press("K")
    vim:press("/")
    vim:press("<cr>")
    vim:press("q")
    sidebar.open()
    vim:press("<esc>")
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
    local vim = fakevim.new(history())
    vim:install()
    split.open()
    sidebar.open()
    vim.t.diffundo_history_rows = { { seq = 0, added = {}, removed = {} } }
    vim.t.diffundo_history_view = vim.t.diffundo_history_rows
    vim.api.nvim_win_set_cursor(float_win(vim), { 1, 0 })

    assert.is_true(pcall(sidebar.place))
    assert.are.equal(3, vim.t.diffundo_diff_undonr)
  end)

  it("raises the documented error when the recorded source window is gone", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()
    vim.t.diffundo_history_source_win = 9999

    assert.has_error(sidebar.place, "The diffundo source window is no longer open in this tab.")
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
    vim.api.nvim_win_set_cursor(float_win(vim), { 3, 0 })

    sidebar.move_save(-1)

    assert.are.same({ 2, 0 }, vim.windows[float_win(vim)].cursor)
  end)

  it("narrows the list and clears on an empty prompt", function()
    sidebar.open()
    local asked = "b"
    vim.fn.input = function()
      return asked
    end
    sidebar.filter()

    local buf = vim.buffers[vim.windows[float_win(vim)].buf]
    assert.are.equal(1, #buf.lines)
    assert.matches("b", buf.lines[1])

    asked = ""
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
    assert.is_nil(vim.t.diffundo_history_footer_win)
    assert.are.equal(source, vim.current_win)
  end)

  it("toggles open and closed", function()
    local vim = fakevim.new(history())
    vim:install()

    assert.is_nil(vim.t.diffundo_history_win)
    sidebar.toggle()
    assert.are_not.equal(nil, vim.t.diffundo_history_win)
    sidebar.toggle()
    assert.is_nil(vim.t.diffundo_history_win)
  end)
end)

describe("sidebar layout integration", function()
  it("renders the tree from history.display and the footer separately", function()
    local vim = fakevim.new(history())
    vim:install()
    sidebar.open()

    local display = vim.t.diffundo_history_display
    local tree = vim.buffers[vim.windows[float_win(vim)].buf]
    local footer = vim.buffers[vim.windows[footer_win(vim)].buf]
    assert.is_not_nil(display)
    assert.are.equal(display.footer_start - 1, #tree.lines)
    assert.are.equal(2, #footer.lines)
    assert.matches("help: g?", footer.lines[2])
  end)

  it("creates manual folds for long runs and collapses them", function()
    local vim = fakevim.new(
      fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" }, { "a", "b", "c", "d" } })
    )
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

  it("opens a fold when J/K lands inside one", function()
    local vim = fakevim.new(
      fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" }, { "a", "b", "c", "d" } })
    )
    vim:install()
    vim.history.entries[3].save = 3
    split.open()
    sidebar.open()

    assert.are.equal(1, #vim.folds)
    sidebar.move_save(1)

    assert.are.same({ 3, 0 }, vim.windows[float_win(vim)].cursor)
    local opened = false
    for _, command in ipairs(vim.commands) do
      if command:match("normal! zv") then
        opened = true
      end
    end
    assert.is_true(opened)
  end)

  it("revealing a seq opens the fold around it", function()
    local vim = fakevim.new(
      fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" }, { "a", "b", "c", "d" } })
    )
    vim:install()
    sidebar.open()

    assert.are.equal(1, #vim.folds)
    sidebar.reveal(3)

    assert.are.same({ 3, 0 }, vim.windows[float_win(vim)].cursor)
    local opened = false
    for _, command in ipairs(vim.commands) do
      if command:match("normal! zv") then
        opened = true
      end
    end
    assert.is_true(opened)
  end)
end)
