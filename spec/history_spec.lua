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
  it("sizes the time column to the longest row label", function()
    local view = {
      { seq = 3, time = os.time() - 2 * 86400 },
      { seq = 20, time = os.time() - 120 },
    }

    assert.are.equal(8, history.time_width(view))
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

  local function cell_width(s)
    local width = 0
    for i = 1, #s do
      local b = s:byte(i)
      if b < 0x80 or b >= 0xC0 then
        width = width + 1
      end
    end
    return width
  end

  it("renders a linear chain with flat gutters and right-aligned time", function()
    local rows = {
      row({ seq = 3, parent = 2, time = os.time() - 120, added = { "foo()" } }),
      row({ seq = 2, parent = 1, time = os.time() - 240 }),
      row({ seq = 1, parent = 0, time = os.time() - 300 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│ %+ foo%(%)", display.lines[1])
    assert.matches("2m %- 3$", display.lines[1])
    assert.matches("^│", display.lines[2])
    assert.matches("^│", display.lines[3])
    assert.are.same({ 1, 2, 3 }, display.row_to_line)
  end)

  it("marks the diff's state with the current glyph", function()
    local rows = {
      row({ seq = 2, parent = 1, save = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { current = 2, width = 30 })

    assert.matches("^◉", display.lines[1])
    assert.matches("^│", display.lines[2])
  end)

  it("caps a branch lane with junctions and leaves the parent plain", function()
    local rows = {
      row({ seq = 4, parent = 2 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│", display.lines[1])
    assert.matches("^├┘", display.lines[2])
    assert.matches("^│", display.lines[3])
    assert.matches("^│", display.lines[4])
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
    assert.matches("^├┘", display.lines[2])
    assert.matches("^│", display.lines[3])
    assert.matches("^│", display.lines[4])
    assert.matches("^│", display.lines[5])
    assert.matches("^│", display.lines[6])
  end)

  it("keeps a long branch chain on one lane like the builtin undotree", function()
    local rows = {
      row({ seq = 8, parent = 4 }),
      row({ seq = 7, parent = 6 }),
      row({ seq = 6, parent = 5 }),
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30, fold_min = 9 })

    assert.matches("^│", display.lines[1])
    assert.matches("^├┘", display.lines[2])
    assert.matches("^┊│", display.lines[3])
    assert.matches("^├┘", display.lines[4])
    assert.matches("^│", display.lines[5])
    assert.matches("^│", display.lines[6])
    assert.matches("^│", display.lines[7])
    assert.matches("^│", display.lines[8])
  end)

  it("nests an alternate of an alternate to a third lane with pass-through", function()
    local rows = {
      row({ seq = 7, parent = 4 }),
      row({ seq = 8, parent = 5 }),
      row({ seq = 6, parent = 5 }),
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30, fold_min = 9 })

    assert.matches("^│", display.lines[1])
    assert.matches("^┊├┘", display.lines[2])
    assert.matches("^┊├┘", display.lines[3])
    assert.matches("^├┘", display.lines[4])
    assert.matches("^│", display.lines[5])
  end)

  it("keeps the newest chain on lane 1 when the trunk child is not first", function()
    local rows = {
      row({ seq = 8, parent = 6 }),
      row({ seq = 6, parent = 4 }),
      row({ seq = 5, parent = 3 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 0 }),
    }
    local display = history.display(rows, { width = 30 })

    assert.matches("^│", display.lines[1])
    assert.matches("^│", display.lines[2])
    assert.matches("^├┘", display.lines[3])
    assert.matches("^│", display.lines[4])
    assert.matches("^│", display.lines[5])
  end)

  it("renders a saved alternate with the ● glyph", function()
    local rows = {
      row({ seq = 9, parent = 5 }),
      row({ seq = 8, parent = 7 }),
      row({ seq = 7, parent = 6, save = 1 }),
      row({ seq = 6, parent = 5 }),
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 30, fold_min = 9 })

    assert.matches("^├┘", display.lines[2])
    assert.matches("^┊●", display.lines[3])
    assert.matches("^├┘", display.lines[4])
  end)

  it("folds a long same-branch run into a caption and a vim fold", function()
    local rows = {
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 40, fold_min = 3 })

    assert.matches("^│", display.lines[1])
    assert.matches("%+4 states: %+0 %-0 lines 4 undos", display.lines[2])
    assert.are.same({ { start = 2, stop = 5 } }, display.folds)
    assert.are.same({ 1, 2, 3, 4, 5 }, display.row_to_line)
  end)

  it("appends the footer below the rows", function()
    local rows = { row({ seq = 2, parent = 1 }), row({ seq = 1, parent = 0 }) }
    local display = history.display(rows, { width = 30, selected = 1, total = 4 })

    assert.are.equal(3, display.footer_start)
    assert.matches("^#2", display.lines[3])
    assert.matches("2/4", display.lines[4])
    assert.matches("help: g%?$", display.lines[4])
    assert.are.equal(4, #display.lines)
  end)

  it("pads rows so the footer is the last two lines of opts.height", function()
    local rows = { row({ seq = 2, parent = 1 }), row({ seq = 1, parent = 0 }) }
    local display = history.display(rows, { width = 30, height = 8, selected = 1, total = 4 })

    assert.are.equal(8, #display.lines)
    assert.are.equal(7, display.footer_start)
    assert.matches("^#2", display.lines[7])
    assert.matches("2/4", display.lines[8])
    assert.matches("help: g%?$", display.lines[8])
  end)

  it("renders an empty view with a no-matches footer", function()
    local display = history.display({}, { width = 30, total = 4 })

    assert.are.equal(1, display.footer_start)
    assert.matches("no matches", display.lines[1])
    assert.matches("0/4", display.lines[2])
    assert.matches("help: g%?$", display.lines[2])
    assert.are.equal(2, #display.lines)
  end)

  it("never maps the sentinel row to a buffer line", function()
    local rows = {
      row({ seq = 2, parent = 1, added = { "x" } }),
      row({ seq = 1, parent = 0 }),
      { seq = 0, time = 0, save = nil, added = {}, removed = {}, parent = 0, label = "" },
    }
    local display = history.display(rows, { width = 30, total = 3 })

    assert.are.same({ 1, 2 }, display.row_to_line)
    assert.matches("2/3", display.lines[4])
    assert.are.equal(4, #display.lines)
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
    local display = history.display(rows, { width = 40, fold_min = 3, total = 6 })

    assert.matches("^│", display.lines[1])
    assert.matches("%+4 states: %+0 %-0 lines 4 undos", display.lines[2])
    assert.are.same({ { start = 2, stop = 5 } }, display.folds)
    assert.are.same({ 1, 2, 3, 4, 5 }, display.row_to_line)
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

  it("truncates an overflowing preview by cells and keeps the time on the line", function()
    local rows = {
      row({ seq = 4, parent = 2, added = { "a very long added line that just keeps going" } }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 14 })

    assert.matches("… 2m %- 4$", display.lines[1])
    for _, line in ipairs(display.lines) do
      assert.is_true(cell_width(line) <= 14, ("line out of width: %q"):format(line))
    end
    for _, span in ipairs(display.spans) do
      assert.is_true(span.line ~= 0, "truncated row must not keep its marks")
    end
    assert.matches("^├┘", display.lines[2])
  end)

  it("truncates a long status line in the footer by cells", function()
    local rows = { row({ seq = 2, parent = 1, added = { "one" }, removed = { "two", "three" } }) }
    local display = history.display(rows, { width = 18, selected = 1, current = 2 })

    assert.matches("^#2 ", display.lines[#display.lines - 1])
    assert.matches("…$", display.lines[#display.lines - 1])
    assert.matches("help: g%?$", display.lines[#display.lines])
  end)
end)

describe("history.display with the us.txt tree", function()
  local day = 86400
  local width = 50
  local time_w = 8
  local tree_w = 2
  local t2, t3

  before_each(function()
    t2 = os.time() - 2 * day
    t3 = os.time() - 3 * day
  end)

  local L1 = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
  local L2 = { "one", "two", "three", "four", "five", "6", "7", "8", "9", "10" }
  local L3 =
    { "one", "two", "three", "six", "seven", "eight", "nine", "ten", "6", "7", "8", "9", "10" }
  local L4 = { "one", "two", "three", "six", "seven", "eight", "6", "7", "8", "9", "10" }
  local L5 = { "one", "two", "three", "six", "seven", "eight", "6", "7", "8", "9" }
  local L6 = { "one", "two", "three", "six", "seven", "eight", "6", "7", "8" }
  local L7 = { "one", "two", "three", "six", "seven", "eight", "6", "7" }
  local L8 = { "one", "two", "three", "six", "seven", "eight", "6" }
  local L9 = { "one", "two", "three", "six", "seven", "6" }
  local L10 = { "one", "two", "three", "six", "6" }
  local L11 = { "one", "two", "three", "6" }
  local L12 = { "one", "two", "6" }
  local L13 = { "one", "6" }
  local L14 = { "6" }
  local L15 = { "15" }
  local L16 = { "final" }
  local L17 = { "one", "two", "three", "SIX", "seven", "eight", "6", "7", "8", "9", "10" }
  local L20 = { "one", "two", "three", "06", "seven", "eight", "6", "7", "8", "9", "10" }

  ---@return table
  local function build_fake()
    local h = fakevim.history({ {}, L1, L2, L3 }, { t3, t3, t3, t3 })
    h:branch(3, L4, { time = t3, save = 1 })
    h:branch(4, L5, { time = t3 })
    h:branch(5, L6, { time = t3, save = 1 })
    h:branch(6, L7, { time = t3 })
    h:branch(7, L8, { time = t3 })
    h:branch(8, L9, { time = t3 })
    h:branch(9, L10, { time = t3 })
    h:branch(10, L11, { time = t3 })
    h:branch(11, L12, { time = t3 })
    h:branch(12, L13, { time = t3 })
    h:branch(13, L14, { time = t3 })
    h:branch(14, L15, { time = t3 })
    h:branch(15, L16, { time = t3 })
    h:branch(4, L17, { time = t2 })
    h:branch(17, L17, { time = t2 })
    h:branch(18, L17, { time = t2 })
    h:branch(18, L20, { time = t2 })
    return fakevim.new(h)
  end

  ---@param s string
  ---@return integer
  local function cells(s)
    local total = 0
    for i = 1, #s do
      local b = s:byte(i)
      if b < 0x80 or b >= 0xC0 then
        total = total + 1
      end
    end
    return total
  end

  ---@param gutter string
  ---@param preview string
  ---@param label string
  ---@return string
  local function rendered(gutter, preview, label)
    local body = width - tree_w - 1 - time_w
    return gutter
      .. string.rep(" ", tree_w - cells(gutter) + 1)
      .. preview
      .. string.rep(" ", math.max(0, body - cells(preview)))
      .. string.rep(" ", math.max(0, time_w - #label))
      .. label
  end

  it("walks all 20 states newest first with the us.txt parents", function()
    build_fake():install()
    local rows = history.rows({})

    local seqs = {}
    local parents = {}
    for i, r in ipairs(rows) do
      seqs[i] = r.seq
      parents[i] = r.parent
    end

    assert.are.same({ 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }, seqs)
    assert.are.same(
      { 18, 18, 17, 4, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
      parents
    )
    assert.are.equal(1, rows[15].save)
    assert.are.equal(1, rows[17].save)
    assert.are.same({ "06" }, rows[1].added)
    assert.are.same({ "SIX" }, rows[1].removed)
    assert.are.same({ "10" }, rows[16].removed)
    local text = history.preview_parts(rows[20])
    assert.are.equal("+10 lines", text)
  end)

  it("renders every row like the us.txt sketch", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 20 })

    local expected = {
      rendered("○", "+1 -1 lines", "2d - 20"),
      rendered("├┘", "+0 lines", "2d - 19"),
      rendered("│", "+0 lines", "2d - 18"),
      rendered("│", "+1 -1 lines", "2d - 17"),
      rendered("├┘", "+1 -1 lines", "3d - 16"),
      rendered("┊│", "+15 states: +21 -20 lines 15 undos", "3d - 15"),
      rendered("┊│", "- one", "3d - 14"),
      rendered("┊│", "- two", "3d - 13"),
      rendered("┊│", "- three", "3d - 12"),
      rendered("┊│", "- six", "3d - 11"),
      rendered("┊│", "- seven", "3d - 10"),
      rendered("┊│", "- eight", "3d - 9"),
      rendered("┊│", "- 7", "3d - 8"),
      rendered("┊│", "- 8", "3d - 7"),
      rendered("┊●", "- 9", "3d - 6"),
      rendered("├┘", "- 10", "3d - 5"),
      rendered("●", "-2 lines", "3d - 4"),
      rendered("│", "+5 -2 lines", "3d - 3"),
      rendered("│", "+5 -5 lines", "3d - 2"),
      rendered("│", "+10 lines", "3d - 1"),
    }

    for i, line in ipairs(expected) do
      assert.are.equal(line, display.lines[i])
      assert.are.equal(width, cells(display.lines[i]))
    end
    assert.are.equal(22, #display.lines)
  end)

  it("folds the branch run under one caption above rows 14 through 1", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 20 })

    assert.are.same({ { start = 6, stop = 20 } }, display.folds)
    assert.are.same(
      { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 },
      display.row_to_line
    )
    assert.are.equal(21, display.footer_start)
    assert.matches("^#20", display.lines[21])
    assert.matches("20/20", display.lines[22])
    assert.matches("help: g%?$", display.lines[22])
  end)
end)

describe("history.display with sibling branches", function()
  local day = 86400
  local width = 40
  local time_w = 8
  local tree_w = 2
  local t2, t3

  before_each(function()
    t2 = os.time() - 2 * day
    t3 = os.time() - 3 * day
  end)

  local S0 = { "15 things that are" }
  local S1 = { "1" }
  local S2 = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11" }
  local S3 = { "1", "7", "8", "9", "10", "11", "A", "B", "C", "1 15 things that are", "Z0" }
  local S4 = {
    "1",
    "7",
    "8",
    "9",
    "10",
    "11",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "E",
    "F",
    "G",
  }
  local S5 = {
    "1",
    "7",
    "8",
    "9",
    "10",
    "11",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "G",
  }
  local S6 = {
    "1",
    "7",
    "8",
    "9",
    "10",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "G",
  }
  local S7 = {
    "1",
    "7",
    "8",
    "9",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "G",
  }
  local S8 = { "1", "7", "8", "9", "A", "B", "2 15 things that are", "2 15 things that are", "G" }
  local S9 = { "1", "7", "8", "A", "B", "2 15 things that are", "2 15 things that are", "G" }
  local S10 = { "1", "7", "A", "B", "2 15 things that are", "2 15 things that are", "G" }
  local S11 = { "1", "A", "B", "2 15 things that are", "2 15 things that are", "G" }
  local S12 = { "1", "A", "B", "2 15 things that are", "2 15 things that are" }
  local S13 = { "1", "A", "B", "2 15 things that are" }
  local S14 = { "1", "A", "2 15 things that are" }
  local S15 = { "1", "A" }
  local S16 = {
    "1",
    "7",
    "8",
    "9",
    "10",
    "11",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "E",
    "F",
    "Z",
  }
  local S17 = {
    "1",
    "7",
    "8",
    "9",
    "10",
    "11",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "E",
    "W",
    "G",
  }
  local S20 = {
    "1",
    "7",
    "8",
    "9",
    "10",
    "11",
    "A",
    "B",
    "1 15 things that are",
    "2 15 things that are",
    "2 15 things that are",
    "E",
    "Q",
    "G",
  }

  ---@return table
  local function build_fake()
    local h = fakevim.history({ S0, S1, S2, S3 }, { t3, t3, t3, t3 })
    h.entries[1].save = 1
    h.entries[2].save = 1
    h:branch(3, S4, { time = t3, save = 1 })
    h:branch(4, S5, { time = t3 })
    h:branch(5, S6, { time = t3 })
    h:branch(6, S7, { time = t3, save = 1 })
    h:branch(7, S8, { time = t3 })
    h:branch(8, S9, { time = t3 })
    h:branch(9, S10, { time = t3 })
    h:branch(10, S11, { time = t3 })
    h:branch(11, S12, { time = t3 })
    h:branch(12, S13, { time = t3 })
    h:branch(13, S14, { time = t3 })
    h:branch(14, S15, { time = t3 })
    h:branch(4, S16, { time = t3 })
    h:branch(4, S17, { time = t2 })
    h:branch(17, S17, { time = t2, save = 1 })
    h:branch(18, S17, { time = t2 })
    h:branch(18, S20, { time = t2 })
    return fakevim.new(h)
  end

  ---@param s string
  ---@return integer
  local function cells(s)
    local total = 0
    for i = 1, #s do
      local b = s:byte(i)
      if b < 0x80 or b >= 0xC0 then
        total = total + 1
      end
    end
    return total
  end

  ---@param gutter string
  ---@param preview string
  ---@param label string
  ---@return string
  local function rendered(gutter, preview, label)
    local body = width - tree_w - 1 - time_w
    return gutter
      .. string.rep(" ", tree_w - cells(gutter) + 1)
      .. preview
      .. string.rep(" ", math.max(0, body - cells(preview)))
      .. string.rep(" ", math.max(0, time_w - #label))
      .. label
  end

  it("renders the sidebar session with shared lanes and the current marker", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 18 })

    local expected = {
      rendered("│", "+1 -1 lines", "2d - 20"),
      rendered("├┘", "+0 lines", "2d - 19"),
      rendered("◉", "+0 lines", "2d - 18"),
      rendered("│", "+1 -1 lines", "2d - 17"),
      rendered("├┘", "+1 -1 lines", "3d - 16"),
      rendered("┊│", "- 2 15 things that are", "3d - 15"),
      rendered("┊│", "+14 states: +21 -19 lines 14…", "3d - 14"),
      rendered("┊│", "- 2 15 things that are", "3d - 13"),
      rendered("┊│", "- G", "3d - 12"),
      rendered("┊│", "- 7", "3d - 11"),
      rendered("┊│", "- 8", "3d - 10"),
      rendered("┊│", "- 9", "3d - 9"),
      rendered("┊│", "- 1 15 things that are", "3d - 8"),
      rendered("┊●", "- 10", "3d - 7"),
      rendered("┊│", "- 11", "3d - 6"),
      rendered("├┘", "-2 lines", "3d - 5"),
      rendered("●", "+5 -2 lines", "3d - 4"),
      rendered("│", "+5 -5 lines", "3d - 3"),
      rendered("●", "+10 lines", "3d - 2"),
      rendered("●", "+1 -1 lines", "3d - 1"),
    }

    for i, line in ipairs(expected) do
      assert.are.equal(line, display.lines[i])
      assert.are.equal(width, cells(display.lines[i]))
    end
    assert.are.equal(22, #display.lines)
  end)

  it("folds rows 14 through 1 and keeps 15 and 16 outside", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 18 })

    assert.are.same({ { start = 7, stop = 20 } }, display.folds)
    assert.are.same(
      { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 },
      display.row_to_line
    )
    assert.are.equal(21, display.footer_start)
  end)
end)
