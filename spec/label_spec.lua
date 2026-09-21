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

describe("label.for_undonr", function()
  before_each(function()
    local history = fakevim.history({ {}, { "first" }, { "first", "second" } })
    history.undotree = function()
      return { entries = entries }
    end
    fakevim.new(history):install()
  end)

  it("labels the original state", function()
    assert.are.equal("{original} - 0", label.for_undonr(0))
  end)

  it("labels an undo entry with its time and sequence", function()
    assert.are.equal(os.date("%Y-%m-%d %I:%M:%S %p", 1627784719) .. " - 1", label.for_undonr(1))
  end)

  it("labels a sequence missing from the undo tree", function()
    assert.are.equal("{unknown} - 9", label.for_undonr(9))
  end)
end)
