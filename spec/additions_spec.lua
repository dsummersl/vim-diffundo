local additions = require("diffundo.additions")

describe("additions.first_match", function()
  it("finds a needle in an added line", function()
    assert.are.equal(" a needle", additions.first_match("needle", {}, { " a needle" }))
  end)

  it("ignores removed lines", function()
    assert.is_nil(additions.first_match("needle", { " a needle" }, {}))
  end)

  it("ignores unchanged lines", function()
    assert.is_nil(additions.first_match("needle", { " a needle" }, { " a needle" }))
  end)

  it("returns the first addition only", function()
    local before = { "keep" }
    local after = { "keep", "a needle here", "another needle" }
    assert.are.equal("a needle here", additions.first_match("needle", before, after))
  end)

  it("matches the needle literally", function()
    assert.are.equal("a.b", additions.first_match("a.b", { "axb" }, { "axb", "a.b" }))
  end)
end)

describe("additions.added_lines", function()
  it("counts repeated lines", function()
    assert.are.same({ "x" }, additions.added_lines({ "x" }, { "x", "x" }))
  end)
end)
