local count = require("diffundo.count")

describe("count.normalize", function()
  it("treats an empty count as one", function()
    assert.are.equal("1", count.normalize(""))
    assert.are.equal("1", count.normalize(nil))
  end)

  it("keeps a plain number", function()
    assert.are.equal("2", count.normalize("2"))
  end)

  it("keeps a unit suffix", function()
    assert.are.equal("2f", count.normalize(" 2f "))
  end)

  it("rejects an unknown unit", function()
    assert.has_error(function()
      count.normalize("1w")
    end, "invalid count: 1w (expected a number, optionally followed by s, m, h, d or f)")
  end)

  it("rejects a negative number", function()
    assert.has_error(function()
      count.normalize("-3")
    end)
  end)
end)
