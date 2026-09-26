local cache = require("diffundo.cache")

describe("cache", function()
  before_each(function()
    cache.reset(1)
  end)

  it("remembers a state's lines per buffer", function()
    cache.remember(1, 3, { "a" })

    assert.are.same({ "a" }, cache.lines(1, 3))
    assert.is_nil(cache.lines(1, 2))
  end)

  it("computes a state's counts once per changedtick", function()
    local calls = 0
    local function compute()
      calls = calls + 1
      return 2, 1
    end

    assert.are.same({ 2, 1 }, { cache.counts(1, 3, 10, compute) })
    assert.are.same({ 2, 1 }, { cache.counts(1, 3, 10, compute) })
    assert.are.equal(1, calls)

    cache.counts(1, 3, 11, compute)
    assert.are.equal(2, calls)
  end)

  it("stores the rows under a key", function()
    local rows = { { seq = 0 } }

    cache.store_rows(1, "3:0", rows)

    local found, key = cache.rows(1)
    assert.are.equal(rows, found)
    assert.are.equal("3:0", key)
  end)

  it("forgets everything on reset", function()
    cache.remember(1, 3, { "a" })

    cache.reset(1)

    assert.is_nil(cache.lines(1, 3))
    assert.is_nil(cache.rows(1))
  end)
end)
