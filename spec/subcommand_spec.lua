local subcommand = require("diffundo.subcommand")

describe("subcommand.parse", function()
  it("parses a bare subcommand", function()
    assert.are.same(
      { name = "earlier", bang = false, rest = "", no_history = false },
      subcommand.parse("earlier")
    )
  end)

  it("passes the rest verbatim, spaces included", function()
    assert.are.same(
      { name = "search", bang = false, rest = "foo  bar", no_history = false },
      subcommand.parse("search foo  bar")
    )
  end)

  it("accepts a bang on search", function()
    assert.are.same(
      { name = "search", bang = true, rest = "x", no_history = false },
      subcommand.parse("search! x")
    )
  end)

  it("rejects a bang on earlier and history", function()
    assert.is_nil(subcommand.parse("earlier! 2"))
    assert.is_nil(subcommand.parse("history!"))
  end)

  it("accepts a leading -no-history flag", function()
    assert.are.same(
      { name = "earlier", bang = false, rest = "2", no_history = true },
      subcommand.parse("-no-history earlier 2")
    )
    assert.are.same(
      { name = "search", bang = false, rest = "x", no_history = true },
      subcommand.parse("-no-history   search x")
    )
  end)

  it("rejects a flag with no subcommand", function()
    assert.is_nil(subcommand.parse("-no-history"))
  end)

  it("rejects unknown and missing subcommands", function()
    assert.is_nil(subcommand.parse("nonesuch"))
    assert.is_nil(subcommand.parse(""))
    assert.is_nil(subcommand.parse("   "))
  end)

  it("ignores leading whitespace", function()
    assert.are.same(
      { name = "later", bang = false, rest = "2f", no_history = false },
      subcommand.parse("  later 2f")
    )
  end)

  it("parses the history subcommand", function()
    assert.are.same(
      { name = "history", bang = false, rest = "", no_history = false },
      subcommand.parse("history")
    )
  end)
end)

describe("subcommand.complete", function()
  it("offers every name for an empty first argument", function()
    assert.are.same(
      { "earlier", "later", "search", "search!", "history" },
      subcommand.complete("", "Diffundo ")
    )
  end)

  it("offers the flag for a dash prefix", function()
    assert.are.same({ "-no-history" }, subcommand.complete("-", "Diffundo -"))
  end)

  it("filters by prefix", function()
    assert.are.same({ "search", "search!" }, subcommand.complete("se", "Diffundo se"))
  end)

  it("offers nothing past the first argument", function()
    assert.are.same({}, subcommand.complete("", "Diffundo search "))
  end)
end)
