local subcommand = require("diffundo.subcommand")

describe("subcommand.parse", function()
  it("parses a bare subcommand", function()
    assert.are.same({ name = "earlier", bang = false, rest = "" }, subcommand.parse("earlier"))
  end)

  it("passes the rest verbatim, spaces included", function()
    assert.are.same(
      { name = "search", bang = false, rest = "foo  bar" },
      subcommand.parse("search foo  bar")
    )
  end)

  it("accepts a bang on search", function()
    assert.are.same({ name = "search", bang = true, rest = "x" }, subcommand.parse("search! x"))
  end)

  it("rejects a bang on earlier and focus", function()
    assert.is_nil(subcommand.parse("earlier! 2"))
    assert.is_nil(subcommand.parse("focus!"))
  end)

  it("rejects the removed history subcommand and -no-history flag", function()
    assert.is_nil(subcommand.parse("history"))
    assert.is_nil(subcommand.parse("-no-history earlier"))
  end)

  it("rejects unknown and missing subcommands", function()
    assert.is_nil(subcommand.parse("nonesuch"))
    assert.is_nil(subcommand.parse(""))
    assert.is_nil(subcommand.parse("   "))
  end)

  it("ignores leading whitespace", function()
    assert.are.same({ name = "later", bang = false, rest = "2f" }, subcommand.parse("  later 2f"))
  end)

  it("parses the focus subcommand", function()
    assert.are.same({ name = "focus", bang = false, rest = "" }, subcommand.parse("focus"))
  end)
end)

describe("subcommand.complete", function()
  it("offers every name for an empty first argument", function()
    assert.are.same(
      { "earlier", "later", "search", "search!", "focus" },
      subcommand.complete("", "Diffundo ")
    )
  end)

  it("filters by prefix", function()
    assert.are.same({ "search", "search!" }, subcommand.complete("se", "Diffundo se"))
  end)

  it("offers nothing past the first argument", function()
    assert.are.same({}, subcommand.complete("", "Diffundo search "))
  end)
end)
