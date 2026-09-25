local lines = require("diffundo.lines")

describe("lines.added_lines", function()
  it("returns lines only present after", function()
    assert.are.same({ "b" }, lines.added_lines({ "a" }, { "a", "b" }))
  end)

  it("counts repeated lines", function()
    assert.are.same({ "x" }, lines.added_lines({ "x" }, { "x", "x" }))
  end)

  it("ignores removed lines", function()
    assert.are.same({}, lines.added_lines({ "a", "b" }, { "a" }))
  end)

  it("keeps the order of the after side", function()
    assert.are.same({ "c", "b" }, lines.added_lines({ "a" }, { "c", "a", "b" }))
  end)
end)

describe("lines.removed_lines", function()
  it("returns lines only present before", function()
    assert.are.same({ "b" }, lines.removed_lines({ "a", "b" }, { "a" }))
  end)

  it("counts repeated lines", function()
    assert.are.same({ "x" }, lines.removed_lines({ "x", "x" }, { "x" }))
  end)

  it("ignores added lines", function()
    assert.are.same({}, lines.removed_lines({ "a" }, { "a", "b" }))
  end)
end)

describe("lines.index_of", function()
  it("finds the first equal line", function()
    assert.are.equal(2, lines.index_of({ "a", "b", "b" }, "b"))
  end)

  it("returns nil when absent", function()
    assert.is_nil(lines.index_of({ "a" }, "b"))
  end)

  it("compares whole lines, not substrings", function()
    assert.is_nil(lines.index_of({ "abc" }, "b"))
  end)
end)

local function sub_regex(needle)
  return {
    match_str = function(_, line)
      local start = line:find(needle, 1, true)
      if start then
        return start - 1, start
      end
      return nil
    end,
  }
end

describe("lines.first_match", function()
  it("returns the first matching candidate and its column", function()
    assert.are.same({ "ax", 1 }, { lines.first_match(sub_regex("x"), { "no", "ax", "x" }) })
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(lines.first_match(sub_regex("z"), { "a", "b" }))
  end)
end)
