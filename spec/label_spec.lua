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

describe("label.relative", function()
  it("says just now for the present and the near past", function()
    assert.are.equal("just now", label.relative(os.time()))
    assert.are.equal("just now", label.relative(os.time() - 30))
    assert.are.equal("just now", label.relative(os.time() + 60))
  end)

  it("uses the largest unit that fits", function()
    assert.are.equal("2m ago", label.relative(os.time() - 120))
    assert.are.equal("1h ago", label.relative(os.time() - 3600))
    assert.are.equal("3d ago", label.relative(os.time() - 3 * 86400))
    assert.are.equal("2w ago", label.relative(os.time() - 14 * 86400))
    assert.are.equal("4mo ago", label.relative(os.time() - 120 * 86400))
    assert.are.equal("2y ago", label.relative(os.time() - 2 * 365 * 86400))
  end)
end)

describe("label.short", function()
  it("compacts the time to a bare unit", function()
    assert.are.equal("now", label.short(os.time()))
    assert.are.equal("2m", label.short(os.time() - 120))
    assert.are.equal("1h", label.short(os.time() - 3600))
    assert.are.equal("3d", label.short(os.time() - 3 * 86400))
    assert.are.equal("2w", label.short(os.time() - 14 * 86400))
    assert.are.equal("4mo", label.short(os.time() - 120 * 86400))
    assert.are.equal("2y", label.short(os.time() - 2 * 365 * 86400))
  end)
end)
