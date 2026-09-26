local fakevim = require("spec.fakevim")
local window = require("diffundo.window")

local config = { relative = "win", win = 1000, row = 3, col = 40, width = 20, height = 2 }

describe("window.open", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
  end)

  it("opens a float with the given config and leaves focus alone", function()
    local win = window.open(config, false)

    assert.are_not.equal(win, vim.current_win)
    assert.are.same(config, vim.windows[win].config)
  end)

  it("focuses the float when asked to", function()
    local win = window.open(config, true)

    assert.are.equal(win, vim.current_win)
  end)

  it("turns off inherited padding columns and wrapping", function()
    local win = window.open(config, false)
    local options = vim.windows[win].options

    assert.are.equal("no", options.signcolumn)
    assert.are.equal("0", options.foldcolumn)
    assert.is_false(options.number)
    assert.is_false(options.relativenumber)
    assert.is_false(options.spell)
    assert.is_false(options.wrap)
  end)

  it("configures a scratch buffer", function()
    local win = window.open(config, false)
    local buffer = vim.buffers[vim.windows[win].buf]

    assert.are.equal("nofile", buffer.options.buftype)
    assert.are.equal("wipe", buffer.options.bufhidden)
    assert.is_false(buffer.options.swapfile)
  end)
end)

describe("window.render and window.map", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
  end)

  it("replaces the lines and leaves the buffer unmodifiable", function()
    local win = window.open(config, false)

    window.render(win, { "one", "two", "three" })

    local buffer = vim.buffers[vim.windows[win].buf]
    assert.are.same({ "one", "two", "three" }, buffer.lines)
    assert.is_false(buffer.options.modifiable)
  end)

  it("binds a normal-mode keymap to the buffer", function()
    local win = window.open(config, true)
    local called = false

    window.map(win, "q", function()
      called = true
    end)
    vim:press("q")

    assert.is_true(called)
  end)
end)

describe("window.close and window.is_open", function()
  it("closes the float and wipes its buffer", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()

    local win = window.open(config, false)
    local buf = vim.windows[win].buf

    window.close(win)

    assert.is_false(window.is_open(win))
    assert.is_nil(vim.buffers[buf])
    assert.is_false(window.is_open(nil))
  end)
end)

describe("fake: highlight and fold APIs", function()
  it("reports a float's config from the api", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
    local win = window.open(config, false)

    local reported = vim.api.nvim_win_get_config(win)

    assert.are.equal(3, reported.row)
    assert.are.equal(20, reported.width)
    assert.are.equal("win", reported.relative)
  end)

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
