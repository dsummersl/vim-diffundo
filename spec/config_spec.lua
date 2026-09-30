local facade = require("diffundo.api")
local diffundo = require("diffundo")
local fakevim = require("spec.fakevim")
local pane = require("diffundo.pane")
local restore = require("diffundo.restore")
local split = require("diffundo.split")
local config = require("diffundo.config")

---@param t table
---@return integer
local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
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

local pristine = {
  history = config.get().history,
  date_format = config.get().date_format,
  history_width = config.get().history_width,
  fold_min = config.get().fold_min,
  glyphs = {
    buffer = config.get().glyphs.buffer,
    write = config.get().glyphs.write,
    gap = config.get().glyphs.gap,
    ellipsis = config.get().glyphs.ellipsis,
  },
  pane_keys = {},
}

for key in pairs(config.get().keys.pane) do
  pristine.pane_keys[key] = true
end

local vim

before_each(function()
  vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } }))
  vim:install()
  config.setup(nil)
end)

describe("diffundo.setup", function()
  it("applies the built-in defaults without a setup call", function()
    assert.are.equal(true, pristine.history)
    assert.are.equal("%Y-%m-%d %H:%M:%S", pristine.date_format)
    assert.are.equal(40, pristine.history_width)
    assert.are.equal(3, pristine.fold_min)
    assert.are.same({ buffer = "@", write = "w", gap = "┆", ellipsis = "…" }, pristine.glyphs)
    assert.are.equal(6, count(pristine.pane_keys))
    assert.is_true(pristine.pane_keys.J)
    assert.is_true(pristine.pane_keys.K)
    assert.is_true(pristine.pane_keys["<cr>"])
    assert.is_true(pristine.pane_keys["<c-cr>"])
    assert.is_true(pristine.pane_keys.q)
    assert.is_true(pristine.pane_keys["<esc>"])
  end)

  it("overrides history", function()
    diffundo.setup({ history = false })

    assert.is_false(config.get().history)
  end)

  it("overrides glyphs without losing the others", function()
    diffundo.setup({ glyphs = { write = "ⓦ" } })

    local found = config.get().glyphs
    assert.are.equal("ⓦ", found.write)
    assert.are.equal("@", found.buffer)
    assert.are.equal("┆", found.gap)
    assert.are.equal("…", found.ellipsis)
  end)

  it("overrides date_format with a string or a function", function()
    local fn = function(time)
      return "at " .. time
    end

    diffundo.setup({ date_format = "%H:%M" })
    assert.are.equal("%H:%M", config.get().date_format)

    diffundo.setup({ date_format = fn })
    assert.are.equal(fn, config.get().date_format)
  end)

  it("overrides history_width and fold_min", function()
    diffundo.setup({ history_width = 55, fold_min = 7 })

    assert.are.equal(55, config.get().history_width)
    assert.are.equal(7, config.get().fold_min)
  end)

  it("merges replacement pane keys over the defaults", function()
    local replacement = function(api)
      api.apply()
    end

    diffundo.setup({
      keys = { pane = { ["<cr>"] = replacement } },
    })

    local pane_keys = config.get().keys.pane
    assert.are.equal(replacement, pane_keys["<cr>"])
    assert.is_function(pane_keys.J)
    assert.is_function(pane_keys.K)
    assert.is_function(pane_keys["<c-cr>"])
    assert.is_function(pane_keys.q)
    assert.is_function(pane_keys["<esc>"])
  end)

  it("a false pane keymap removes the default binding", function()
    diffundo.setup({ keys = { pane = { q = false } } })

    local pane_keys = config.get().keys.pane
    assert.is_nil(pane_keys.q)
    assert.is_function(pane_keys["<esc>"])
    assert.is_function(pane_keys.J)
  end)

  it("an empty string also removes the default binding", function()
    diffundo.setup({ keys = { pane = { ["<esc>"] = "" } } })

    local pane_keys = config.get().keys.pane
    assert.is_nil(pane_keys["<esc>"])
    assert.is_function(pane_keys.q)
    assert.is_function(pane_keys["<cr>"])
  end)

  it("does not install a disabled keymap in the pane buffer", function()
    diffundo.setup({ keys = { pane = { q = false } } })
    show(vim, 2)
    pane.focus()

    local ok, err = pcall(function()
      vim:press("q")
    end)

    assert.is_false(ok)
    assert.matches("no keymap for q", tostring(err))
  end)

  it("passes the facade to a replacement keymap and reaches the pane action", function()
    local received
    diffundo.setup({
      keys = {
        pane = {
          z = function(api)
            received = api
            api.apply()
          end,
        },
      },
    })
    local apply = facade.apply
    show(vim, 2)
    pane.focus()
    vim.api.nvim_win_set_cursor(vim:pane_window(), { 3, 0 })

    vim:press("z")

    assert.are.same({ "a" }, vim:source_buffer().lines)
    assert.are.equal(1, vim.history.seq)
    assert.are.equal(vim:pane_window(), vim.current_win)
    assert.are.equal(apply, received.apply)
  end)

  it("a replacement keymap reaching a command action steps the diff", function()
    diffundo.setup({
      keys = {
        pane = {
          z = function(api)
            api.earlier()
          end,
        },
      },
    })
    show(vim, 2)
    pane.focus()

    vim:press("z")

    assert.are.equal(1, vim.t.diffundo_diff_undonr)
    assert.are.same({ "a" }, vim:diff_buffer().lines)
  end)

  it("the facade exposes the command and pane actions together", function()
    assert.are.equal(diffundo.earlier, facade.earlier)
    assert.are.equal(diffundo.later, facade.later)
    assert.are.equal(diffundo.undo, facade.undo)
    assert.are.equal(diffundo.search, facade.search)
    assert.are.equal(diffundo.focus, facade.focus)
    assert.are.equal(diffundo.close, facade.close)
    assert.are.equal(pane.move_save, facade.move_save)
    assert.are.equal(pane.place, facade.place)
    assert.are.equal(pane.apply, facade.apply)
    assert.are.equal(pane.collapse, facade.collapse)
  end)
end)
