local fakevim = require("spec.fakevim")
local walker = require("diffundo.walker")

---@param iterator fun(): diffundo.Step|nil
---@return diffundo.Step[]
local function collect(iterator)
  local steps = {}
  for step in iterator do
    table.insert(steps, step)
  end
  return steps
end

describe("walker.steps", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } }))
    vim:install()
  end)

  it("yields what each edit added, newest first", function()
    local steps = collect(walker.steps(4))

    assert.are.same({ 3, 2, 1 }, { steps[1].seq, steps[2].seq, steps[3].seq })
    assert.are.same({ "c" }, steps[1].added)
    assert.are.same({ "b" }, steps[2].added)
    assert.are.same({ "a" }, steps[3].added)
    assert.are.same({}, steps[1].removed)
  end)

  it("carries the text of the state and its parent", function()
    local step = assert(walker.steps(4)())

    assert.are.same({ "a", "b", "c" }, step.lines)
    assert.are.same({ "a", "b" }, step.parent_lines)
    assert.are.equal(2, step.parent)
    assert.are.equal(vim.history.entries[3].time, step.time)
  end)

  it("starts strictly behind from_seq", function()
    local steps = collect(walker.steps(3))

    assert.are.same({ 2, 1 }, { steps[1].seq, steps[2].seq })
  end)

  it("never yields the original text", function()
    assert.are.same({}, collect(walker.steps(1)))
  end)

  it("yields removals", function()
    vim.history:branch(3, { "a", "c" })

    local step = assert(walker.steps(5)())

    assert.are.equal(4, step.seq)
    assert.are.same({}, step.added)
    assert.are.same({ "b" }, step.removed)
  end)

  it("diffs against the parent, not the chronological neighbour", function()
    vim.history:branch(1, { "a", "x" })

    local steps = collect(walker.steps(5))

    assert.are.equal(4, steps[1].seq)
    assert.are.equal(1, steps[1].parent)
    assert.are.same({ "x" }, steps[1].added)
    assert.are.same({}, steps[1].removed)
    assert.are.same({ "c" }, steps[2].added)
  end)

  it("is lazy", function()
    local iterator = walker.steps(4)

    iterator()

    assert.are.same({ "silent undo 2", "silent undo 3" }, vim.commands)
  end)

  it("passes save through", function()
    vim.history:branch(3, { "a", "b", "c", "d" }, { save = 2 })

    assert.are.equal(2, walker.steps(5)().save)
  end)
end)
