local fakevim = require("spec.fakevim")
local label = require("diffundo.label")

local entries = {
  { seq = 1, time = 1627784719 },
  { seq = 2, time = 1627784779, alt = { { seq = 3, time = 1627784839 } } },
}

describe("label.find_entry", function()
  it("finds a top level entry", function()
    assert.are.same({ seq = 1, time = 1627784719 }, label.find_entry(entries, 1))
  end)

  it("finds an entry on an alternate branch", function()
    assert.are.same({ seq = 3, time = 1627784839 }, label.find_entry(entries, 3))
  end)

  it("returns nil for an unknown sequence", function()
    assert.is_nil(label.find_entry(entries, 9))
  end)
end)

describe("label.name", function()
  it("names the diff buffer after the source buffer and the undo number", function()
    local vim = fakevim.new(fakevim.history({ {}, { "first" } }))
    vim:install()
    vim.t.diffundo_source_bn = 7

    assert.are.equal("diffundo://7/#3", label.name(3))
  end)
end)

describe("label.date and label.title", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "first" } }))
    vim:install()
  end)

  it("formats with the default date format", function()
    assert.are.equal(os.date("%Y-%m-%d %H:%M:%S", 1627784719), label.date(1627784719))
  end)

  it("uses g:diffundo_date_format when it is a strftime string", function()
    vim.g.diffundo_date_format = "%H:%M"

    assert.are.equal(os.date("%H:%M", 1627784719), label.date(1627784719))
  end)

  it("calls g:diffundo_date_format when it is a function", function()
    vim.g.diffundo_date_format = function(time)
      return "at " .. time
    end

    assert.are.equal("at 5", label.date(5))
  end)

  it("titles a state with its number and date, and #0 with its number alone", function()
    vim.g.diffundo_date_format = "%Y"

    assert.are.equal("#4  " .. os.date("%Y", 1627784719), label.title(4, 1627784719))
    assert.are.equal("#0", label.title(0, 0))
  end)
end)

describe("label.apply", function()
  it("names the current buffer and leaves the statusline and winbar alone", function()
    local vim = fakevim.new(fakevim.history({ {}, { "first" } }))
    vim:install()

    label.apply("diffundo://1/#1")

    assert.are.equal("diffundo://1/#1", vim:current_buffer().name)
    assert.is_nil(vim.windows[vim.current_win].options.statusline)
    assert.is_nil(vim.windows[vim.current_win].options.winbar)
  end)
end)
