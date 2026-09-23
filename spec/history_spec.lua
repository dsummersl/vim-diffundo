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
    local base =
      { seq = 4, time = 1004, save = nil, added = {}, removed = {}, parent = 3, label = "" }
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

describe("history.display", function()
  local function row(over)
    local base =
      { seq = 4, time = os.time() - 120, save = nil, added = {}, removed = {}, parent = 3 }
    for key, value in pairs(over or {}) do
      base[key] = value
    end
    return base
  end

  it("renders a linear chain with flat gutters and right-aligned time", function()
    local rows = {
      row({ seq = 3, parent = 2, time = os.time() - 120, added = { "foo()" } }),
      row({ seq = 2, parent = 1, time = os.time() - 240 }),
      row({ seq = 1, parent = 0, time = os.time() - 300 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│%+ foo%(%)", display.lines[1])
    assert.matches("2m$", display.lines[1])
    assert.matches("^│", display.lines[2])
    assert.matches("^└", display.lines[3])
    assert.are.same({ 1, 2, 3 }, display.row_to_line)
  end)

  it("marks the diff's state with the current glyph", function()
    local rows = {
      row({ seq = 2, parent = 1, save = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { current = 2, width = 30 })

    assert.matches("^◉", display.lines[1])
    assert.matches("^└", display.lines[2])
  end)

  it("nests a lane on a branch switch and draws the fork junction", function()
    local rows = {
      row({ seq = 4, parent = 2 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│", display.lines[1])
    assert.matches("^┊│", display.lines[2])
    assert.matches("^├┐", display.lines[3])
    assert.matches("^└", display.lines[4])
  end)

  it("keeps the trunk lane when branches alternate", function()
    local rows = {
      row({ seq = 6, parent = 4 }),
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30, fold_min = 6 })

    assert.matches("^│", display.lines[1])
    assert.matches("^┊│", display.lines[2])
    assert.matches("^├┐", display.lines[3])
    assert.matches("^│", display.lines[4])
    assert.matches("^│", display.lines[5])
    assert.matches("^└", display.lines[6])
  end)

  it("keeps nested pass-through columns over the branch subtree", function()
    local rows = {
      row({ seq = 8, parent = 7 }),
      row({ seq = 7, parent = 5 }),
      row({ seq = 6, parent = 4 }),
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^┊│", display.lines[1])
    assert.matches("^┊│", display.lines[2])
    assert.matches("^│", display.lines[3])
    assert.matches("^┊│", display.lines[4])
    assert.matches("^├┐", display.lines[5])
  end)

  it("renders a saved alternate with the ● glyph", function()
    local rows = {
      row({ seq = 4, parent = 2 }),
      row({ seq = 3, parent = 1, save = 1, added = { "x" } }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^┊│", display.lines[1])
    assert.matches("^●", display.lines[2])
  end)

  it("folds a long same-branch run into a caption and a vim fold", function()
    local rows = {
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30, fold_min = 3 })

    assert.matches("%+5 states: %+0 %-0 lines 5 undos", display.lines[1])
    assert.are.same({ { start = 1, stop = 5 } }, display.folds)
    assert.are.same({ 2, 3, 4, 5, 6 }, display.row_to_line)
  end)

  it("appends the footer under a divider", function()
    local rows = { row({ seq = 2, parent = 1 }), row({ seq = 1, parent = 0 }) }
    local display = history.display(rows, { width = 30, selected = 1, total = 4 })

    assert.are.equal(3, display.footer_start)
    assert.matches("^%-%-%-", display.lines[3])
    assert.matches("^#2", display.lines[4])
    assert.matches("2/4", display.lines[5])
    assert.matches("help: g%?$", display.lines[5])
  end)

  it("renders an empty view with a no-matches footer", function()
    local display = history.display({}, { width = 30, total = 4 })

    assert.are.equal(1, display.footer_start)
    assert.matches("^%-%-%-", display.lines[1])
    assert.matches("no matches", display.lines[2])
    assert.matches("0/4", display.lines[3])
    assert.matches("help: g%?$", display.lines[3])
  end)

  it("never maps the sentinel row to a buffer line", function()
    local rows = {
      row({ seq = 2, parent = 1, added = { "x" } }),
      row({ seq = 1, parent = 0 }),
      { seq = 0, time = 0, save = nil, added = {}, removed = {}, parent = 0, label = "" },
    }
    local display = history.display(rows, { width = 30, total = 3 })

    assert.are.same({ 1, 2 }, display.row_to_line)
    assert.matches("2/3", display.lines[5])
    assert.are.equal(5, #display.lines)
  end)

  it("folds a same-branch chain without counting the older sentinel", function()
    local rows = {
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
      { seq = 0, time = 0, save = nil, added = {}, removed = {}, parent = 0, label = "" },
    }
    local display = history.display(rows, { width = 30, fold_min = 3, total = 6 })

    assert.matches("%+5 states: %+0 %-0 lines 5 undos", display.lines[1])
    assert.are.same({ { start = 1, stop = 5 } }, display.folds)
    assert.are.same({ 2, 3, 4, 5, 6 }, display.row_to_line)
    assert.matches("5/6", display.lines[#display.lines])
  end)

  it("shows the current saved state and change totals in the footer", function()
    local rows = {
      row({ seq = 3, parent = 2, added = { "x" }, save = 1 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 60, current = 3, selected = 1 })

    assert.matches("^#3", display.lines[#display.lines - 1])
    assert.matches("◉ saved", display.lines[#display.lines - 1])
    assert.matches("%+1 %-0$", display.lines[#display.lines - 1])
  end)

  it("shows ○ for the plain current state in the footer", function()
    local rows = { row({ seq = 2, parent = 1 }), row({ seq = 1, parent = 0 }) }
    local display = history.display(rows, { width = 60, current = 2, selected = 1 })

    assert.matches("^#2 ○ ", display.lines[#display.lines - 1])
    assert.not_matches("saved", display.lines[#display.lines - 1])
  end)
end)
