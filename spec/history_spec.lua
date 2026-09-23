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

  it("labels a row with its relative time and sequence", function()
    local row = history.row_for(step({ seq = 2 }))

    assert.matches("%d+y ago %- 2$", row.label)
  end)
end)

describe("history.preview_parts", function()
  local function row(over)
    local base = { seq = 4, time = 1004, save = nil, added = {}, removed = {}, parent = 3 }
    for key, value in pairs(over or {}) do
      base[key] = value
    end
    return base
  end

  it("shows a single added line colored DiffAdd", function()
    local text, spans = history.preview_parts(row({ added = { "foo()" } }))

    assert.are.equal("+ foo()", text)
    assert.are.equal("DiffAdd", spans[1].hl)
    assert.are.equal("+ foo()", text:sub(spans[1].from + 1, spans[1].to))
  end)

  it("shows a single removed line colored DiffDelete", function()
    local text, spans = history.preview_parts(row({ removed = { "bar()" } }))

    assert.are.equal("- bar()", text)
    assert.are.equal("DiffDelete", spans[1].hl)
  end)

  it("shows counts with the lines unit for mixed changes", function()
    local text, spans = history.preview_parts(row({ added = { "a", "b" }, removed = { "c" } }))

    assert.are.equal("+2 -1 lines", text)
    assert.are.equal("DiffAdd", spans[1].hl)
    assert.are.equal("DiffDelete", spans[2].hl)
  end)

  it("omits zero sides and pluralises", function()
    assert.are.equal("-3 lines", history.preview_parts(row({ removed = { "a", "b", "c" } })))
    assert.are.equal("+2 lines", history.preview_parts(row({ added = { "a", "b" } })))
  end)
end)

describe("history.time_width", function()
  it("sizes the time column to the longest row", function()
    local view = {
      { seq = 3, time = os.time() - 2 * 86400 },
      { seq = 2, time = os.time() - 120 },
    }

    assert.are.equal(3, history.time_width(view))
  end)
end)

describe("history.rows", function()
  it("walks the whole history newest first and restores the live state", function()
    local rows = history.rows({})

    assert.are.same({ 3, 2, 1 }, { rows[1].seq, rows[2].seq, rows[3].seq })
    assert.are.same({ "c" }, rows[1].added)
    assert.are.equal(3, vim.history.seq)
  end)

  it("caps at the limit, appends the sentinel, and stops the walk", function()
    local rows = history.rows({ limit = 1 })

    assert.are.same({ 3, 0 }, { rows[1].seq, rows[2].seq })
    local undos = 0
    for _, command in ipairs(vim.commands) do
      if command:match("^silent undo ") then
        undos = undos + 1
      end
    end
    assert.are.equal(5, undos)
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

  it("moves down with dir 1 and up with dir -1", function()
    assert.are.equal(2, history.next(rows(), 1, { dir = 1 }))
    assert.are.equal(2, history.next(rows(), 3, { dir = -1 }))
  end)

  it("skips non-save rows when written", function()
    assert.are.equal(2, history.next(rows(), 1, { dir = 1, written = true }))
    assert.are.equal(2, history.next(rows(), 3, { dir = -1, written = true }))
    local candidates = {
      { seq = 3, time = 0, added = {}, removed = {}, label = "", save = nil },
      { seq = 2, time = 0, added = {}, removed = {}, label = "", save = nil },
      { seq = 1, time = 0, added = {}, removed = {}, label = "", save = 1 },
    }
    assert.are.equal(3, history.next(candidates, 1, { dir = 1, written = true }))
  end)

  it("clamps at the edges", function()
    assert.are.equal(3, history.next(rows(), 3, { dir = 1 }))
    assert.are.equal(1, history.next(rows(), 1, { dir = -1 }))
  end)

  it("returns the index unchanged for dir 0", function()
    assert.are.equal(1, history.next(rows(), 1, { dir = 0 }))
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
