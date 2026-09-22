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

    window.map(win, "q", function()
      called = true
    end)
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
