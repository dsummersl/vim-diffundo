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

---@param s string
---@return integer
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
    assert.are.equal("+0 lines", history.preview_parts(row({})))
  end)

  it("shows nothing for the original text", function()
    assert.are.equal("", history.preview_parts(row({ seq = 0 })))
  end)
end)

describe("history.rows", function()
  local function undos()
    local count = 0
    for _, command in ipairs(vim.commands) do
      if command:match("^silent undo ") then
        count = count + 1
      end
    end
    return count
  end

  it("walks the whole history newest first, ends at #0 and restores the live state", function()
    local rows = history.rows({})

    assert.are.same({ 3, 2, 1, 0 }, { rows[1].seq, rows[2].seq, rows[3].seq, rows[4].seq })
    assert.are.same({ "c" }, rows[1].added)
    assert.are.equal(3, vim.history.seq)
  end)

  it("caps at the limit and stops the walk", function()
    local rows = history.rows({ limit = 1 })

    assert.are.same({ 3, 0 }, { rows[1].seq, rows[2].seq })
    assert.are.equal(5, undos())
  end)

  it("returns just #0 for an empty history", function()
    local empty = fakevim.new(fakevim.history({ {} }))
    empty:install()

    local rows = history.rows({})

    assert.are.equal(1, #rows)
    assert.are.equal(0, rows[1].seq)
  end)

  it("hands every state's lines, #0 included, to on_lines", function()
    local seen = {}

    history.rows({
      on_lines = function(seq, lines)
        seen[seq] = lines
      end,
    })

    assert.are.same({ "a", "b", "c" }, seen[3])
    assert.are.same({ "a" }, seen[1])
    assert.are.same({}, seen[0])
  end)

  it("walks only the states newer than the known rows", function()
    local known = history.rows({})
    vim.history:branch(3, { "a", "b", "c", "d" }, { save = 1 })
    vim.commands = {}

    local rows = history.rows({ known = known })

    assert.are.same({ 4, 3, 2, 1, 0 }, {
      rows[1].seq,
      rows[2].seq,
      rows[3].seq,
      rows[4].seq,
      rows[5].seq,
    })
    assert.are.equal(known[1], rows[2])
    assert.are.equal(1, rows[1].save)
    assert.are.equal(3, undos())
  end)

  it("refreshes the saves of the known rows", function()
    local known = history.rows({})
    vim.history.entries[2].save = 1

    local rows = history.rows({ known = known })

    assert.are.equal(1, rows[2].save)
  end)

  it("starts over when the known rows are newer than the history", function()
    local known = history.rows({})
    local shorter = fakevim.new(fakevim.history({ {}, { "z" } }))
    shorter:install()

    local rows = history.rows({ known = known })

    assert.are.same({ 1, 0 }, { rows[1].seq, rows[2].seq })
    assert.are.same({ "z" }, rows[1].added)
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
      { seq = 3, time = 0, added = {}, removed = {}, save = nil },
      { seq = 2, time = 0, added = {}, removed = {}, save = nil },
      { seq = 1, time = 0, added = {}, removed = {}, save = 1 },
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

---@param over table|nil
---@return diffundo.Row
local function row(over)
  local base = { seq = 4, time = 1004, save = nil, added = {}, removed = {}, parent = 3 }
  for key, value in pairs(over or {}) do
    base[key] = value
  end
  return base
end

---@return diffundo.Row
local function original()
  return row({ seq = 0, parent = 0 })
end

describe("history.display rows", function()
  it("renders a linear chain with the undo number right-aligned", function()
    local rows = {
      row({ seq = 3, parent = 2, added = { "foo()" } }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
      original(),
    }
    local display = history.display(rows, { width = 30 })

    assert.are.same({
      "│ + foo()                   #3",
      "│ +0 lines                  #2",
      "│ +0 lines                  #1",
      "│                           #0",
    }, display.lines)
    assert.are.same({ 1, 2, 3, 4 }, display.row_to_line)
  end)

  it("pips the buffer's state over a write over the diff's state", function()
    local rows = {
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2, save = 1 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0, save = 1 }),
      original(),
    }
    local display = history.display(rows, { width = 30, buffer = 4, current = 3 })

    assert.matches("^@ ", display.lines[1])
    assert.matches("^w ", display.lines[2])
    assert.matches("^│ ", display.lines[3])
    assert.matches("^w ", display.lines[4])

    local on_diff = history.display(rows, { width = 30, buffer = 4, current = 2 })
    assert.matches("^○ ", on_diff.lines[3])

    local same = history.display(rows, { width = 30, buffer = 3, current = 3 })
    assert.matches("^@ ", same.lines[2])
  end)

  it("draws the configured glyphs", function()
    local rows = {
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1, save = 1 }),
      row({ seq = 1, parent = 0 }),
      original(),
    }
    local glyphs = { buffer = "B", diff = "D", write = "ⓦ", gap = ":", ellipsis = "~" }
    local display = history.display(rows, { width = 30, buffer = 3, current = 1, glyphs = glyphs })

    assert.matches("^B ", display.lines[1])
    assert.matches("^ⓦ ", display.lines[2])
    assert.matches("^D ", display.lines[3])
  end)

  it("highlights the buffer's and the diff's rows", function()
    local rows = { row({ seq = 2, parent = 1 }), row({ seq = 1, parent = 0 }), original() }
    local display = history.display(rows, { width = 30, buffer = 2, current = 1 })

    local lines_hl = {}
    for _, span in ipairs(display.spans) do
      if span.col_start == 0 then
        lines_hl[span.line] = span.hl
      end
    end
    assert.are.equal("DiffundoBuffer", lines_hl[0])
    assert.are.equal("DiffundoDiff", lines_hl[1])
  end)

  it("caps a branch lane with junctions and puts a pip in the cap", function()
    local rows = {
      row({ seq = 4, parent = 2 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
      original(),
    }

    local plain = history.display(rows, { width = 30 })
    assert.matches("^│ ", plain.lines[1])
    assert.matches("^├┘", plain.lines[2])
    assert.matches("^│ ", plain.lines[3])

    local current = history.display(rows, { width = 30, current = 3 })
    assert.matches("^├○", current.lines[2])
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

  it("renders a written alternate with the write pip", function()
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
    assert.matches("^┊w", display.lines[3])
    assert.matches("^├┘", display.lines[4])
  end)

  it("folds a long branch stretch with a gap caption counting its writes", function()
    local rows = {
      row({ seq = 9, parent = 2 }),
      row({ seq = 8, parent = 7 }),
      row({ seq = 7, parent = 6 }),
      row({ seq = 6, parent = 5, save = 1 }),
      row({ seq = 5, parent = 4 }),
      row({ seq = 4, parent = 3 }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
      original(),
    }
    local display = history.display(rows, { width = 40, fold_min = 3 })

    assert.matches("^│", display.lines[1])
    assert.matches("^├┘", display.lines[2])
    assert.matches("^┊│ %+0 lines", display.lines[3])
    assert.matches("^├┘", display.lines[7])
    assert.are.same({ { start = 3, stop = 6 } }, display.folds)
    assert.are.same({ [3] = "┆    4 undos 1w" }, display.captions)
    assert.are.same({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, display.row_to_line)
  end)

  it("renders an empty view as no lines", function()
    local display = history.display({}, { width = 30 })

    assert.are.same({}, display.lines)
  end)

  it("truncates an overflowing preview with the ellipsis and keeps the number", function()
    local rows = {
      row({ seq = 4, parent = 2, added = { "a very long added line that just keeps going" } }),
      row({ seq = 3, parent = 2 }),
      row({ seq = 2, parent = 1 }),
      row({ seq = 1, parent = 0 }),
    }
    local display = history.display(rows, { width = 14 })

    assert.are.equal("│  + a ver… #4", display.lines[1])
    for _, line in ipairs(display.lines) do
      assert.are.equal(14, cell_width(line))
    end
    for _, span in ipairs(display.spans) do
      assert.is_true(span.line ~= 0, "truncated row must not keep its marks")
    end
  end)
end)

describe("history.display collapsed", function()
  ---@return diffundo.Row[]
  local function linear()
    local rows = {}
    for seq = 12, 1, -1 do
      rows[#rows + 1] = row({ seq = seq, parent = seq - 1, added = { "line " .. seq } })
    end
    rows[#rows + 1] = original()
    return rows
  end

  it("shows only the kept rows with gap rows between them", function()
    local rows = linear()
    rows[5].save = 1
    local display = history.display(rows, {
      width = 34,
      buffer = 12,
      current = 4,
      keep = { [12] = true, [4] = true },
    })

    assert.are.same({
      "@ + line 12                    #12",
      "┆   7 undos 1w",
      "○ + line 4                      #4",
      "┆   3 undos",
    }, display.lines)
    assert.are.same({ [1] = 1, [9] = 3 }, display.row_to_line)
    assert.are.same({}, display.folds)
  end)

  it("counts the states above the top row when the buffer is mid-undo", function()
    local display = history.display(linear(), {
      width = 34,
      buffer = 10,
      current = 9,
      keep = { [10] = true, [9] = true },
    })

    assert.are.same({
      "┆   2 undos",
      "@ + line 10                    #10",
      "○ + line 9                      #9",
      "┆   8 undos",
    }, display.lines)
  end)

  it("shows #0 without a gap below it", function()
    local display = history.display(linear(), {
      width = 34,
      buffer = 12,
      current = 0,
      keep = { [12] = true, [0] = true },
    })

    assert.are.same({
      "@ + line 12                    #12",
      "┆   11 undos",
      "○                               #0",
    }, display.lines)
  end)

  it("shows one row when the diff equals the buffer", function()
    local display = history.display(linear(), {
      width = 34,
      buffer = 12,
      current = 12,
      keep = { [12] = true },
    })

    assert.are.same({ "@ + line 12                    #12", "┆   11 undos" }, display.lines)
  end)

  it("keeps the kept rows' lanes and pads the gaps to the widest kept gutter", function()
    local rows = {
      row({ seq = 4, parent = 1, added = { "x" } }),
      row({ seq = 3, parent = 2, added = { "c" } }),
      row({ seq = 2, parent = 1, added = { "b" } }),
      row({ seq = 1, parent = 0, added = { "a" } }),
      original(),
    }
    local display = history.display(rows, {
      width = 30,
      buffer = 4,
      current = 3,
      keep = { [4] = true, [3] = true },
    })

    assert.are.same({
      "@  + x                      #4",
      "├○ + c                      #3",
      "┆    2 undos",
    }, display.lines)
  end)

  it("greys out the gap rows", function()
    local display = history.display(linear(), {
      width = 34,
      buffer = 12,
      current = 4,
      keep = { [12] = true, [4] = true },
    })

    local gap
    for _, span in ipairs(display.spans) do
      if span.line == 1 then
        gap = span
      end
    end
    assert.are.equal("DiffundoGap", gap.hl)
    assert.are.equal(#display.lines[2], gap.col_end)
  end)
end)

describe("history.display with the us.txt tree", function()
  local day = 86400
  local width = 50
  local seq_w = 3
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
  ---@param seq integer
  ---@return string
  local function rendered(gutter, preview, seq)
    local number = "#" .. seq
    local body = width - tree_w - 1 - seq_w - 1
    return gutter
      .. string.rep(" ", tree_w - cells(gutter) + 1)
      .. preview
      .. string.rep(" ", body - cells(preview) + 1 + seq_w - #number)
      .. number
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

    assert.are.same(
      { 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
      seqs
    )
    assert.are.same(
      { 18, 18, 17, 4, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0 },
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
      rendered("○", "+1 -1 lines", 20),
      rendered("├┘", "+0 lines", 19),
      rendered("│", "+0 lines", 18),
      rendered("│", "+1 -1 lines", 17),
      rendered("├┘", "+1 -1 lines", 16),
      rendered("┊│", "+1 -1 lines", 15),
      rendered("┊│", "- one", 14),
      rendered("┊│", "- two", 13),
      rendered("┊│", "- three", 12),
      rendered("┊│", "- six", 11),
      rendered("┊│", "- seven", 10),
      rendered("┊│", "- eight", 9),
      rendered("┊│", "- 7", 8),
      rendered("┊│", "- 8", 7),
      rendered("┊w", "- 9", 6),
      rendered("├┘", "- 10", 5),
      rendered("w", "-2 lines", 4),
      rendered("│", "+5 -2 lines", 3),
      rendered("│", "+5 -5 lines", 2),
      rendered("│", "+10 lines", 1),
    }

    for i, line in ipairs(expected) do
      assert.are.equal(line, display.lines[i])
      assert.are.equal(width, cells(display.lines[i]))
    end
    assert.are.equal(21, #display.lines)
    assert.matches("^│ +#0$", display.lines[21])
  end)

  it("folds rows 15 through 6 with the caption served as foldtext", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 20 })

    assert.are.same({ { start = 6, stop = 15 } }, display.folds)
    assert.are.same({ [6] = "┆    10 undos 1w" }, display.captions)
    assert.are.same(
      { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 },
      display.row_to_line
    )
  end)
end)

describe("history.display with sibling branches", function()
  local day = 86400
  local width = 40
  local seq_w = 3
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
  ---@param seq integer
  ---@return string
  local function rendered(gutter, preview, seq)
    local number = "#" .. seq
    local body = width - tree_w - 1 - seq_w - 1
    return gutter
      .. string.rep(" ", tree_w - cells(gutter) + 1)
      .. preview
      .. string.rep(" ", body - cells(preview) + 1 + seq_w - #number)
      .. number
  end

  it("renders the sidebar session with shared lanes and the current marker", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 18 })

    local expected = {
      rendered("│", "+1 -1 lines", 20),
      rendered("├┘", "+0 lines", 19),
      rendered("w", "+0 lines", 18),
      rendered("│", "+1 -1 lines", 17),
      rendered("├┘", "+1 -1 lines", 16),
      rendered("┊│", "- 2 15 things that are", 15),
      rendered("┊│", "- B", 14),
      rendered("┊│", "- 2 15 things that are", 13),
      rendered("┊│", "- G", 12),
      rendered("┊│", "- 7", 11),
      rendered("┊│", "- 8", 10),
      rendered("┊│", "- 9", 9),
      rendered("┊│", "- 1 15 things that are", 8),
      rendered("┊w", "- 10", 7),
      rendered("┊│", "- 11", 6),
      rendered("├┘", "-2 lines", 5),
      rendered("w", "+5 -2 lines", 4),
      rendered("│", "+5 -5 lines", 3),
      rendered("w", "+10 lines", 2),
      rendered("w", "+1 -1 lines", 1),
    }

    for i, line in ipairs(expected) do
      assert.are.equal(line, display.lines[i])
      assert.are.equal(width, cells(display.lines[i]))
    end
    assert.are.equal(21, #display.lines)
    assert.matches("^│ +#0$", display.lines[21])
  end)

  it("folds rows 14 through 6 and keeps the caps outside", function()
    build_fake():install()
    local rows = history.rows({})
    local display = history.display(rows, { width = width, current = 18 })

    assert.are.same({ { start = 7, stop = 15 } }, display.folds)
    assert.are.same({ [7] = "┆    9 undos 1w" }, display.captions)
    assert.are.same(
      { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 },
      display.row_to_line
    )
  end)
end)

describe("history.rows mirrors real neovim undo trees", function()
  it("walks a real branch off the middle newest first", function()
    local h = fakevim.history({ { "" }, { "a" }, { "a", "b" }, { "a", "b", "c" } })
    h:branch(1, { "a", "x" })
    fakevim.new(h):install()

    local rows = history.rows({})
    local seqs, parents = {}, {}
    for i, r in ipairs(rows) do
      seqs[i] = r.seq
      parents[i] = r.parent
    end
    assert.are.same({ 4, 3, 2, 1, 0 }, seqs)
    assert.are.same({ 1, 2, 1, 0, 0 }, parents)
    assert.are.same({ "x" }, rows[1].added)
    assert.are.same({ "a" }, rows[4].added)
    assert.are.same({ "" }, rows[4].removed)
  end)

  it("walks real sibling branches off one parent", function()
    local h = fakevim.history({ { "" }, { "a" }, { "a", "b" }, { "a", "b", "c" } })
    h:branch(1, { "a", "x" })
    h:branch(1, { "a", "y" })
    fakevim.new(h):install()

    local rows = history.rows({})
    local seqs, parents = {}, {}
    for i, r in ipairs(rows) do
      seqs[i] = r.seq
      parents[i] = r.parent
    end
    assert.are.same({ 5, 4, 3, 2, 1, 0 }, seqs)
    assert.are.same({ 1, 1, 2, 1, 0, 0 }, parents)
    assert.are.same({ "y" }, rows[1].added)
    assert.are.same({ "x" }, rows[2].added)
  end)

  it("walks a real long alternate chain off an early trunk state", function()
    local h = fakevim.history({
      { "" },
      { "a" },
      { "a", "b" },
      { "a", "b", "c" },
      { "a", "b", "c", "d" },
      { "a", "b", "c", "d", "e" },
      { "a", "b", "c", "d", "e", "f" },
      { "a", "b", "c", "d", "e", "f", "g" },
    })
    h:branch(1, { "a", "u" })
    h:branch(8, { "a", "u", "v" })
    h:branch(9, { "a", "u", "v", "w" })
    h:branch(10, { "a", "u", "v", "w", "q" })
    h:branch(11, { "a", "u", "v", "w", "q", "r" })
    h:branch(12, { "a", "u", "v", "w", "q", "r", "s" })
    h:branch(13, { "a", "u", "v", "w", "q", "r", "s", "t" })
    fakevim.new(h):install()

    local rows = history.rows({})
    local seqs, parents = {}, {}
    for i, r in ipairs(rows) do
      seqs[i] = r.seq
      parents[i] = r.parent
    end
    assert.are.same({ 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, seqs)
    assert.are.same({ 13, 12, 11, 10, 9, 8, 1, 6, 5, 4, 3, 2, 1, 0, 0 }, parents)
  end)
end)

describe("history.display with real neovim undo shapes", function()
  ---@param display diffundo.Display
  ---@param expected string[]
  local function assert_tree_lines(display, expected)
    for i, line in ipairs(expected) do
      assert.are.equal(line, display.lines[i])
    end
    assert.are.equal(#expected, #display.lines)
  end

  it("renders a real branch off the middle with junctions", function()
    local rows = {
      row({ seq = 4, parent = 1, added = { "x" } }),
      row({ seq = 3, parent = 2, added = { "c" } }),
      row({ seq = 2, parent = 1, added = { "b" } }),
      row({ seq = 1, parent = 0, added = { "a" }, removed = { "" } }),
    }
    local display = history.display(rows, { width = 40, current = 4 })

    assert_tree_lines(display, {
      "○  + x                                #4",
      "├┘ + c                                #3",
      "├┘ + b                                #2",
      "│  +1 -1 lines                        #1",
    })
  end)

  it("renders real sibling branches on shared lanes", function()
    local rows = {
      row({ seq = 5, parent = 1, added = { "y" } }),
      row({ seq = 4, parent = 1, added = { "x" } }),
      row({ seq = 3, parent = 2, added = { "c" } }),
      row({ seq = 2, parent = 1, added = { "b" } }),
      row({ seq = 1, parent = 0, added = { "a" }, removed = { "" } }),
    }
    local display = history.display(rows, { width = 40, current = 5 })

    assert_tree_lines(display, {
      "○  + y                                #5",
      "├┘ + x                                #4",
      "┊│ + c                                #3",
      "├┘ + b                                #2",
      "│  +1 -1 lines                        #1",
    })
  end)

  it("renders a real branch off the original text", function()
    local rows = {
      row({ seq = 2, parent = 0, added = { "z" }, removed = { "" } }),
      row({ seq = 1, parent = 0, added = { "a" }, removed = { "" } }),
    }
    local display = history.display(rows, { width = 40, current = 2 })

    assert_tree_lines(display, {
      "○ +1 -1 lines                         #2",
      "│ +1 -1 lines                         #1",
    })
  end)

  it("puts the write pip in the junction caps of a real saved branch", function()
    local rows = {
      row({ seq = 4, parent = 1, added = { "x" } }),
      row({ seq = 3, parent = 2, added = { "c" }, save = 3 }),
      row({ seq = 2, parent = 1, added = { "b" }, save = 2 }),
      row({ seq = 1, parent = 0, added = { "a" }, removed = { "" }, save = 1 }),
    }
    local display = history.display(rows, { width = 40, current = 4 })

    assert_tree_lines(display, {
      "○  + x                                #4",
      "├w + c                                #3",
      "├w + b                                #2",
      "w  +1 -1 lines                        #1",
    })
  end)

  it("folds the real long alternate chain off an early trunk", function()
    local rows = {
      row({ seq = 14, parent = 13, added = { "t" } }),
      row({ seq = 13, parent = 12, added = { "s" } }),
      row({ seq = 12, parent = 11, added = { "r" } }),
      row({ seq = 11, parent = 10, added = { "q" } }),
      row({ seq = 10, parent = 9, added = { "w" } }),
      row({ seq = 9, parent = 8, added = { "v" } }),
      row({ seq = 8, parent = 1, added = { "u" } }),
      row({ seq = 7, parent = 6, added = { "g" } }),
      row({ seq = 6, parent = 5, added = { "f" } }),
      row({ seq = 5, parent = 4, added = { "e" } }),
      row({ seq = 4, parent = 3, added = { "d" } }),
      row({ seq = 3, parent = 2, added = { "c" } }),
      row({ seq = 2, parent = 1, added = { "b" } }),
      row({ seq = 1, parent = 0, added = { "a" }, removed = { "" } }),
    }
    local display = history.display(rows, { width = 40, current = 14 })

    assert.are.same({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }, display.row_to_line)
    assert.are.same({ { start = 9, stop = 12 } }, display.folds)
    assert.are.same({ [9] = "┆    4 undos" }, display.captions)
  end)
end)
