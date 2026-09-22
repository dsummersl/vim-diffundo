local tree = require("diffundo.tree")

---@param seq integer
---@param alt table|nil
---@return diffundo.UndoEntry
local function entry(seq, alt)
  return { seq = seq, time = 1000 + seq, alt = alt }
end

describe("tree.states", function()
  it("returns nothing for an empty history", function()
    assert.are.same({}, tree.states({ seq_last = 0, seq_cur = 0, entries = {} }))
  end)

  it("chains a linear history from the original text", function()
    local states = tree.states({
      seq_last = 3,
      seq_cur = 3,
      entries = { entry(1), entry(2), entry(3) },
    })

    assert.are.same({
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("gives an alt branch the parent of the entry it hangs off", function()
    local states = tree.states({
      seq_last = 3,
      seq_cur = 3,
      entries = { entry(1), entry(3, { entry(2) }) },
    })

    assert.are.same({
      { seq = 3, parent = 1, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("follows an alt chain and nested alts", function()
    local states = tree.states({
      seq_last = 5,
      seq_cur = 5,
      entries = {
        entry(1),
        entry(4, { entry(3, { entry(2), entry(5) }) }),
      },
    })

    assert.are.same({
      { seq = 5, parent = 2, time = 1005 },
      { seq = 4, parent = 1, time = 1004 },
      { seq = 3, parent = 1, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("keeps the save number", function()
    local states = tree.states({
      seq_last = 1,
      seq_cur = 1,
      entries = { { seq = 1, time = 1001, save = 1 } },
    })

    assert.are.same({ { seq = 1, parent = 0, time = 1001, save = 1 } }, states)
  end)

  it("gives an alt hanging off the first root entry the original text as parent", function()
    local states = tree.states({
      seq_last = 2,
      seq_cur = 2,
      entries = { entry(2, { entry(1) }) },
    })

    assert.are.same({
      { seq = 2, parent = 0, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)
end)
