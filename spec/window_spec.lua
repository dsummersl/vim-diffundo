local fakevim = require("spec.fakevim")
local window = require("diffundo.window")

describe("window.open", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
  end)

  it("creates a focused float in the upper right with no winbar", function()
    local win = window.open({ lines = { "one", "two" }, width = 40 })

    assert.are.equal(win, vim.current_win)
    local config = vim.windows[win].config
    assert.are.equal("editor", config.relative)
    assert.are.equal(0, config.row)
    assert.are.equal(40, config.col)
    assert.are.equal(40, config.width)
    assert.are.equal(2, config.height)
    assert.is_nil(vim.windows[win].options.winbar)
  end)

  it("turns off inherited padding columns and wrapping", function()
    local win = window.open({ lines = { "one" }, width = 40 })
    local options = vim.windows[win].options

    assert.are.equal("no", options.signcolumn)
    assert.are.equal("0", options.foldcolumn)
    assert.is_false(options.number)
    assert.is_false(options.relativenumber)
    assert.is_false(options.spell)
    assert.is_false(options.wrap)
  end)

  it("clamps the column to the editor width", function()
    vim.o.columns = 30
    local win = window.open({ lines = { "one" }, width = 40 })

    assert.are.equal(0, vim.windows[win].config.col)
  end)

  it("configures a scratch buffer and fills the lines", function()
    local win = window.open({ lines = { "one", "two" }, width = 40 })
    local buffer = vim.buffers[vim.windows[win].buf]

    assert.are.equal("nofile", buffer.options.buftype)
    assert.are.equal("wipe", buffer.options.bufhidden)
    assert.are.same({ "one", "two" }, buffer.lines)
  end)

  it("honors opts.height for the drawn lines", function()
    local lines = {}
    for index = 1, 8 do
      lines[index] = "row " .. index
    end
    local win = window.open({ lines = lines, height = 8, width = 40 })

    assert.are.equal(8, vim.windows[win].config.height)
  end)

  it("caps the height at the terminal", function()
    vim.o.lines = 5
    local win = window.open({ lines = { "a", "b", "c" }, width = 40 })

    assert.are.equal(2, vim.windows[win].config.height)
  end)

  it("caps opts.height at the terminal", function()
    vim.o.lines = 10
    local lines = {}
    for index = 1, 36 do
      lines[index] = "row " .. index
    end
    local win = window.open({ lines = lines, height = 36, width = 40 })

    assert.are.equal(6, vim.windows[win].config.height)
  end)

  it("defaults to row 0 and focuses the float", function()
    local win = window.open({ lines = { "one" }, width = 40 })

    assert.are.equal(0, vim.windows[win].config.row)
    assert.are.equal(win, vim.current_win)
  end)

  it("honors row and leaves the current window alone with enter=false", function()
    local win = window.open({ lines = { "one" }, width = 40, row = 5, enter = false })

    assert.are.equal(5, vim.windows[win].config.row)
    assert.are_not.equal(win, vim.current_win)
  end)
end)

describe("window.render and window.map", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
  end)

  it("replaces lines and re-heights", function()
    local win = window.open({ lines = { "one" }, width = 40 })

    window.render(win, { "one", "two", "three" })

    assert.are.same({ "one", "two", "three" }, vim.buffers[vim.windows[win].buf].lines)
    assert.are.equal(3, vim.windows[win].config.height)
  end)

  it("keeps opts.height when rendering", function()
    local win = window.open({ lines = { "one" }, width = 40 })

    window.render(win, { "one", "two" }, { height = 8 })

    assert.are.equal(8, vim.windows[win].config.height)
  end)

  it("does not shrink below opts.height when lines exceed it", function()
    local win = window.open({ lines = { "one" }, width = 40 })
    local lines = {}
    for index = 1, 10 do
      lines[index] = "row " .. index
    end

    window.render(win, lines, { height = 8 })

    assert.are.equal(8, vim.windows[win].config.height)
  end)

  it("binds a normal-mode keymap to the buffer", function()
    local win = window.open({ lines = { "one" }, width = 40 })
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

    local win = window.open({ lines = { "one" }, width = 40 })
    local buf = vim.windows[win].buf

    window.close(win)

    assert.is_false(window.is_open(win))
    assert.is_nil(vim.buffers[buf])
  end)
end)

describe("fake: highlight and fold APIs", function()
  it("reports a float's config from the api", function()
    local vim = fakevim.new(fakevim.history({ {}, { "a" } }))
    vim:install()
    local win = window.open({ lines = { "one" }, width = 40, row = 3 })

    local config = vim.api.nvim_win_get_config(win)

    assert.are.equal(3, config.row)
    assert.are.equal(40, config.width)
    assert.are.equal("editor", config.relative)
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
