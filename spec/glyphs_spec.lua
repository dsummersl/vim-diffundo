local fakevim = require("spec.fakevim")
local glyphs = require("diffundo.glyphs")

describe("glyphs.get", function()
  before_each(function()
    fakevim.new(fakevim.history({ {} })):install()
  end)

  it("defaults to narrow glyphs with a plain w for writes", function()
    assert.are.same({ buffer = "@", write = "w", gap = "┆", ellipsis = "…" }, glyphs.get())
  end)

  it("merges g:diffundo_glyphs over the defaults", function()
    vim.g.diffundo_glyphs = { write = "ⓦ" }

    local found = glyphs.get()

    assert.are.equal("ⓦ", found.write)
    assert.are.equal("@", found.buffer)
  end)
end)
