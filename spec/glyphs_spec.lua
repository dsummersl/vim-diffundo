local config = require("diffundo.config")
local fakevim = require("spec.fakevim")
local glyphs = require("diffundo.glyphs")

describe("glyphs.get", function()
  before_each(function()
    fakevim.new(fakevim.history({ {} })):install()
    config.setup(nil)
  end)

  it("defaults to narrow glyphs with a plain w for writes", function()
    assert.are.same({ buffer = "@", write = "w", gap = "┆", ellipsis = "…" }, glyphs.get())
  end)

  it("merges setup glyphs over the defaults", function()
    config.setup({ glyphs = { write = "ⓦ" } })

    local found = glyphs.get()

    assert.are.equal("ⓦ", found.write)
    assert.are.equal("@", found.buffer)
  end)
end)
