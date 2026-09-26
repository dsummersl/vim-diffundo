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

  it("opens against #0 for a buffer without undo history", function()
    vim = fakevim.new(fakevim.history({ {} }))
    vim:install()

    assert.is_true(split.open())
    assert.are.equal(2, #vim.win_order)
    assert.are.equal(0, vim.t.diffundo_diff_undonr)
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

  it("names the diff buffer after the undo number without a statusline or winbar", function()
    vim.o.winbar = "%f"

    split.open()

    local window = vim:diff_window().options
    assert.are.equal("diffundo://" .. vim.source_bn .. "/#3", vim:diff_buffer().name)
    assert.is_nil(window.statusline)
    assert.is_nil(window.winbar)
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

describe("split.close", function()
  local vim

  before_each(function()
    vim = fakevim.new(three_states())
    vim:install()
  end)

  it("closes the diff window", function()
    split.open()

    split.close()

    assert.is_false(split.is_open())
    assert.are.equal(1, #vim.win_order)
  end)

  it("is a no-op when nothing is open", function()
    split.close()

    assert.is_false(split.is_open())
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
