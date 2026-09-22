local cursor = require("diffundo.cursor")

---@param line string
---@param col integer
---@param lnum integer
---@return diffundo.Hit
local function hit(line, col, lnum)
  return { seq = 7, time = 1000, line = line, col = col, lnum = lnum }
end

describe("cursor.locate", function()
  it("lands on the matched line and column when the line is still there", function()
    local lnum, col = cursor.locate({ "x", "a needle" }, hit("a needle", 2, 9))

    assert.are.same({ 2, 2 }, { lnum, col })
  end)

  it("falls back to the line number when the line is gone", function()
    local lnum, col = cursor.locate({ "x", "y", "z" }, hit("gone", 3, 2))

    assert.are.same({ 2, 0 }, { lnum, col })
  end)

  it("clamps the fallback to the buffer length", function()
    local lnum, col = cursor.locate({ "x" }, hit("gone", 0, 9))

    assert.are.same({ 1, 0 }, { lnum, col })
  end)

  it("uses line one for an empty buffer", function()
    local lnum, col = cursor.locate({}, hit("gone", 0, 3))

    assert.are.same({ 1, 0 }, { lnum, col })
  end)
end)
