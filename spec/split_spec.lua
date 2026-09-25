local fakevim = require("spec.fakevim")
local split = require("diffundo.split")

local function three_states()
  return fakevim.history({ {}, { "first" }, { "first", "second" }, { "first", "second", "third" } })
end

describe("split.open", function()
  local vim

  before_each(function()
    vim = fakevim.new(three_states())
    vim:install()
  end)

  it("refuses a buffer without undo history", function()
    vim = fakevim.new(fakevim.history({ {} }))
    vim:install()

    assert.is_false(split.open())
    assert.are.equal("No changes to view!", vim:last_notification())
    assert.are.equal(1, #vim.win_order)
    assert.is_nil(vim.t.diffundo_diff_bn)
  end)

  it("accepts history the buffer has already undone", function()
    vim.history:undo(0)

    assert.is_true(split.open())
    assert.are.equal(2, #vim.win_order)
    assert.are.equal(0, vim.t.diffundo_diff_undonr)
  end)

  it("creates a scratch buffer", function()
    split.open()

    assert.are.equal(2, #vim.win_order)
    assert.are.equal(vim.source_bn, vim.t.diffundo_source_bn)
    assert.are_not.equal(vim.t.diffundo_source_bn, vim.t.diffundo_diff_bn)
    assert.are.equal(3, vim.t.diffundo_diff_undonr)
  end)

  it("configures the scratch buffer and window", function()
    split.open()

    local buffer = vim:diff_buffer().options
    assert.are.equal("nofile", buffer.buftype)
    assert.are.equal("wipe", buffer.bufhidden)
    assert.are.equal("lua", buffer.filetype)
    assert.is_true(buffer.readonly)
    local window = vim:diff_window().options
    assert.is_true(window.diff)
    assert.are.equal("diff", window.foldmethod)
  end)

  it("labels the diff window with the buffer name", function()
    split.open()

    local window = vim:diff_window().options
    assert.are.equal(vim:diff_buffer().name, window.statusline)
    assert.matches("%- 3$", vim:diff_buffer().name)
  end)

  it("skips the winbar when the editor has none", function()
    split.open()

    local window = vim:diff_window().options
    assert.is_nil(window.winbar)
  end)

  it("labels the winbar when the editor uses one", function()
    vim.o.winbar = "%f"

    split.open()

    local window = vim:diff_window().options
    assert.are.equal(vim:diff_buffer().name, window.winbar)
  end)

  it("leaves the cursor in the source window", function()
    split.open()

    assert.are.equal(vim.source_bn, vim:current_buffer().number)
  end)

  it("is idempotent", function()
    split.open()
    local diff_bn = vim.t.diffundo_diff_bn

    split.open()

    assert.are.equal(diff_bn, vim.t.diffundo_diff_bn)
    assert.are.equal(2, #vim.win_order)
  end)

  it("returns to the source window before reopening", function()
    split.open()
    vim.current_win = vim:window_of_buffer(vim.t.diffundo_diff_bn)
    vim.t.diffundo_diff_undonr = nil

    split.open()

    assert.are.equal(vim.source_bn, vim.t.diffundo_source_bn)
    assert.are.equal(3, vim.t.diffundo_diff_undonr)
    assert.are.equal(vim.source_bn, vim:current_buffer().number)
  end)

  it("reports a source window that is gone", function()
    split.open()
    vim.current_win = vim:window_of_buffer(vim.t.diffundo_diff_bn)
    vim:close_window(vim:window_of_buffer(vim.source_bn))
    vim.t.diffundo_diff_undonr = nil

    assert.has_error(function()
      split.open()
    end, "The diffundo source window is no longer open in this tab.")
  end)
end)

describe("split.focus", function()
  it("reports a tab without the split", function()
    fakevim.new(three_states()):install()

    assert.has_error(function()
      split.focus(false)
    end, "The diffundo split is no longer open in this tab.")
  end)
end)
