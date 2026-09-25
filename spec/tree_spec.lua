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

describe("tree.states with real neovim undo trees", function()
  it("parses a real branch off the middle", function()
    local states = tree.states({
      seq_last = 4,
      seq_cur = 4,
      entries = { entry(1), entry(4, { entry(2), entry(3) }) },
    })

    assert.are.same({
      { seq = 4, parent = 1, time = 1004 },
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("parses real sibling branches nested in alts", function()
    local states = tree.states({
      seq_last = 5,
      seq_cur = 5,
      entries = { entry(1), entry(5, { entry(4, { entry(2), entry(3) }) }) },
    })

    assert.are.same({
      { seq = 5, parent = 1, time = 1005 },
      { seq = 4, parent = 1, time = 1004 },
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("parses a real branch off the original text", function()
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

  it("parses a real nested branch after an alt head", function()
    local states = tree.states({
      seq_last = 5,
      seq_cur = 5,
      entries = { entry(1), entry(4, { entry(2), entry(3) }), entry(5) },
    })

    assert.are.same({
      { seq = 5, parent = 4, time = 1005 },
      { seq = 4, parent = 1, time = 1004 },
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("keeps the save numbers across a real branch", function()
    local states = tree.states({
      seq_last = 4,
      seq_cur = 4,
      entries = {
        { seq = 1, time = 1001, save = 1 },
        entry(4, { { seq = 2, time = 1002, save = 2 }, { seq = 3, time = 1003, save = 3 } }),
      },
    })

    assert.are.same({
      { seq = 4, parent = 1, time = 1004, save = nil },
      { seq = 3, parent = 2, time = 1003, save = 3 },
      { seq = 2, parent = 1, time = 1002, save = 2 },
      { seq = 1, parent = 0, time = 1001, save = 1 },
    }, states)
  end)

  it("parses a real long alternate chain off an early trunk entry", function()
    local states = tree.states({
      seq_last = 9,
      seq_cur = 9,
      entries = {
        entry(1),
        entry(2),
        entry(9, { entry(3), entry(4), entry(5), entry(6), entry(7), entry(8) }),
      },
    })

    assert.are.same({
      { seq = 9, parent = 2, time = 1009 },
      { seq = 8, parent = 7, time = 1008 },
      { seq = 7, parent = 6, time = 1007 },
      { seq = 6, parent = 5, time = 1006 },
      { seq = 5, parent = 4, time = 1005 },
      { seq = 4, parent = 3, time = 1004 },
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)

  it("handles the curhead/newhead markers a real tree carries", function()
    local states = tree.states({
      seq_last = 4,
      seq_cur = 2,
      entries = {
        entry(1),
        { seq = 2, time = 1002, alt = { { seq = 4, time = 1004, newhead = 1 } } },
        { seq = 3, time = 1003, curhead = 1 },
      },
    })

    assert.are.same({
      { seq = 4, parent = 1, time = 1004 },
      { seq = 3, parent = 2, time = 1003 },
      { seq = 2, parent = 1, time = 1002 },
      { seq = 1, parent = 0, time = 1001 },
    }, states)
  end)
end)
