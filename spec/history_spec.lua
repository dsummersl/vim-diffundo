local fakevim = require("spec.fakevim")
local history = require("diffundo.history")

---@param over table|nil
---@return diffundo.Step
local function step(over)
  local base =
    { seq = 4, parent = 3, time = 1004, added = {}, removed = {}, lines = {}, parent_lines = {} }
  for key, value in pairs(over or {}) do
    base[key] = value
  end
  return base
end

local vim

before_each(function()
  vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a", "b", "c" } }))
  vim:install()
end)

describe("history.row_for", function()
  it("copies the step's diff fields", function()
    local row = history.row_for(step({ added = { "x" }, removed = { "y" }, save = 2 }))

    assert.are.equal(4, row.seq)
    assert.are.equal(2, row.save)
    assert.are.same({ "x" }, row.added)
    assert.are.same({ "y" }, row.removed)
  end)

  it("labels from the undotree entry", function()
    local row = history.row_for(step({ seq = 2 }))

    assert.matches("%- 2$", row.label)
  end)
end)

describe("history.render", function()
  it("previews a single addition", function()
    local row = history.row_for(step({ added = { "foo()" } }))

    assert.matches("+ foo%(%)", history.render(row, 40))
  end)

  it("previews a single removal", function()
    local row = history.row_for(step({ removed = { "bar" } }))

    assert.matches("%- bar", history.render(row, 40))
  end)

  it("summarises mixed changes", function()
    local row = history.row_for(step({ added = { "a", "b" }, removed = { "c" } }))

    assert.matches("~ 2 added, 1 removed", history.render(row, 40))
  end)

  it("marks saved rows and truncates to the width", function()
    local row = history.row_for(step({ save = 1 }))

    assert.matches("%[saved%]", history.render(row, 40))
    assert.is_true(#history.render(row, 40) <= 40)
  end)

  it("renders the sentinel as an ellipsis", function()
    local sentinel = { seq = 0, time = 0, added = {}, removed = {}, label = "" }

    assert.are.equal("…older…", history.render(sentinel, 40))
  end)
end)

describe("history.rows", function()
  it("walks the whole history newest first and restores the live state", function()
    local rows = history.rows({})

    assert.are.same({ 3, 2, 1 }, { rows[1].seq, rows[2].seq, rows[3].seq })
    assert.are.same({ "c" }, rows[1].added)
    assert.are.equal(3, vim.history.seq)
  end)

  it("caps at the limit and appends the sentinel", function()
    local rows = history.rows({ limit = 1 })

    assert.are.same({ 3, 0 }, { rows[1].seq, rows[2].seq })
  end)

  it("does not append the sentinel when the limit is not reached", function()
    local rows = history.rows({ limit = 10 })

    assert.are.equal(3, #rows)
  end)

  it("returns nothing for an empty history", function()
    local empty = fakevim.new(fakevim.history({ {} }))
    empty:install()

    assert.are.same({}, history.rows({}))
  end)
end)

describe("history.next", function()
  local function rows()
    return {
      { seq = 3, save = nil },
      { seq = 2, save = 2 },
      { seq = 1, save = nil },
    }
  end

  it("moves down by default and up with dir -1", function()
    assert.are.equal(2, history.next(rows(), 1))
    assert.are.equal(2, history.next(rows(), 3, { dir = -1 }))
  end)

  it("skips non-save rows when written", function()
    assert.are.equal(2, history.next(rows(), 1, { written = true }))
    assert.are.equal(2, history.next(rows(), 3, { dir = -1, written = true }))
    local candidates = {
      { seq = 3, time = 0, added = {}, removed = {}, label = "", save = nil },
      { seq = 2, time = 0, added = {}, removed = {}, label = "", save = nil },
      { seq = 1, time = 0, added = {}, removed = {}, label = "", save = 1 },
    }
    assert.are.equal(3, history.next(candidates, 1, { written = true }))
  end)

  it("clamps at the edges", function()
    assert.are.equal(3, history.next(rows(), 3))
    assert.are.equal(1, history.next(rows(), 1, { dir = -1 }))
  end)
end)

describe("history.filtered", function()
  it("keeps rows with a matching added line", function()
    local regex = vim.regex("x")
    local rows = { { seq = 3, added = { "ax" } }, { seq = 2, added = { "nope" } } }

    local filtered = history.filtered(rows, regex)

    assert.are.equal(1, #filtered)
    assert.are.equal(3, filtered[1].seq)
  end)

  it("matches removed lines with opts.removed", function()
    local regex = vim.regex("x")
    local rows = { { seq = 3, added = {}, removed = { "ax" } } }

    assert.are.equal(3, history.filtered(rows, regex, { removed = true })[1].seq)
  end)
end)
