local label = require("diffundo.label")
local lines = require("diffundo.lines")
local restore = require("diffundo.restore")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]
---@field removed string[]
---@field parent integer
---@field label string

---@class diffundo.Span
---@field line integer
---@field hl string
---@field col_start integer
---@field col_end integer

---@class diffundo.Fold
---@field start integer
---@field stop integer

---@class diffundo.Display
---@field lines string[]
---@field spans diffundo.Span[]
---@field folds diffundo.Fold[]
---@field row_to_line integer[]
---@field footer_start integer

local older = {
  seq = 0,
  time = 0,
  save = nil,
  added = {},
  removed = {},
  parent = 0,
  label = "",
}

---@param row diffundo.Row
---@return string, { hl: string, from: integer, to: integer }[]
local function preview_parts(row)
  local a, r = #row.added, #row.removed
  if a == 1 and r == 0 then
    local text = "+ " .. row.added[1]
    return text, { { hl = "DiffAdd", from = 0, to = #text } }
  end
  if a == 0 and r == 1 then
    local text = "- " .. row.removed[1]
    return text, { { hl = "DiffDelete", from = 0, to = #text } }
  end
  local names = {}
  if a > 0 then
    names[#names + 1] = "+" .. a
  end
  if r > 0 then
    names[#names + 1] = "-" .. r
  end
  if #names == 0 then
    names[#names + 1] = "+0"
  end
  names[#names + 1] = "lines"
  local text = table.concat(names, " ")
  local spans = {}
  local col = 0
  for _, name in ipairs(names) do
    local hl = name:sub(1, 1) == "+" and "DiffAdd" or (name:sub(1, 1) == "-" and "DiffDelete")
    if hl then
      spans[#spans + 1] = { hl = hl, from = col, to = col + #name }
    end
    col = col + #name + 1
  end
  return text, spans
end

---@param view diffundo.Row[]
---@return integer
function M.time_width(view)
  local longest = 1
  for _, row in ipairs(view) do
    longest = math.max(longest, #label.short(row.time))
  end
  return longest + 1
end

---@param row diffundo.Row
---@return string, { hl: string, from: integer, to: integer }[]
function M.preview_parts(row)
  return preview_parts(row)
end

---@param view diffundo.Row[]
---@return integer[], integer[][]
local function topology_for(view)
  local seq_index = {}
  for i, r in ipairs(view) do
    seq_index[r.seq] = i
  end
  local children = {}
  for i, r in ipairs(view) do
    local parent = seq_index[r.parent]
    if parent then
      children[parent] = children[parent] or {}
      table.insert(children[parent], i)
    end
  end
  local depth = { 1 }
  for i = 2, #view do
    if view[i - 1].parent == view[i].seq then
      depth[i] = depth[i - 1]
    else
      depth[i] = depth[i - 1] + 1
    end
  end
  return depth, children
end

---@param i integer
---@param depth integer
---@param children integer[][]
---@param last integer
---@param is_current boolean
---@param save boolean
---@return string
local function gutter_for(i, depth, children, last, is_current, save)
  local kids = children[i] or {}
  local cells = {}
  for c = 1, depth - 1 do
    cells[c] = "┊"
  end
  if #kids >= 2 then
    cells[depth] = "├"
    for k = 1, #kids - 1 do
      cells[depth + k] = k < #kids - 1 and "┬" or "┐"
    end
  elseif i == last then
    cells[depth] = "└"
  else
    local glyph = is_current and (save and "◉" or "○") or (save and "●" or "│")
    cells[depth] = glyph
  end
  return table.concat(cells, "")
end

---@param view diffundo.Row[]
---@param i integer
---@param depth integer[]
---@param children integer[][]
---@param time_w integer
---@param width integer
---@param current integer|nil
---@return string, diffundo.Span[]
local function row_line(view, i, depth, children, time_w, width, current)
  local r = view[i]
  local gutter = gutter_for(i, depth[i], children, #view, r.seq == current, r.save ~= nil)
  local preview, marks = preview_parts(r)
  local time = label.short(r.time)
  local body_w = width - #gutter - time_w
  if #preview > body_w then
    preview = preview:sub(1, body_w - 1) .. "…"
    marks = {}
  end
  local line = gutter
    .. preview
    .. string.rep(" ", body_w - #preview)
    .. string.rep(" ", time_w - #time)
    .. time
  local spans = {}
  local base = #gutter
  for _, mark in ipairs(marks) do
    spans[#spans + 1] = {
      line = 0,
      hl = mark.hl,
      col_start = base + mark.from,
      col_end = base + mark.to,
    }
  end
  return line, spans
end

---@param view diffundo.Row[]
---@param first integer
---@param count integer
---@param depth integer[]
---@param time_w integer
---@param width integer
---@return string
local function caption_for(view, first, count, depth, time_w, width)
  local added, removed = 0, 0
  for offset = 0, count - 1 do
    added = added + #view[first + offset].added
    removed = removed + #view[first + offset].removed
  end
  local text = string.format("+%d states: +%d -%d lines %d undos", count, added, removed, count)
  local gutter = gutter_for(first, depth[first], {}, #view, false, false)
  local time = label.short(view[first].time)
  local body_w = width - #gutter - time_w
  return gutter
    .. text
    .. string.rep(" ", math.max(0, body_w - #text))
    .. string.rep(" ", math.max(0, time_w - #time))
    .. time
end

---@param view diffundo.Row[]
---@param opts { selected?: integer, total?: integer }
---@param width integer
---@return string[]
local function footer_lines(view, opts, width)
  local index = opts.selected and math.max(1, math.min(opts.selected, #view)) or 1
  local r = view[index]
  local meaning = r.save and "● saved" or ""
  local absolute = os.date("%Y-%m-%d %I:%M:%S %p", r.time)
  local preview, _ = preview_parts(r)
  local shown = #view
  local total = opts.total or shown
  local line1 = ("#%d %s %s %s"):format(r.seq, meaning, absolute, preview)
  if #line1 > width then
    line1 = line1:sub(1, width)
  end
  local hint = "help: g?"
  local line2 = ("%d/%d"):format(shown, total)
  line2 = line2 .. string.rep(" ", math.max(0, width - #line2 - #hint)) .. hint
  return { line1, line2 }
end

---@param view diffundo.Row[]
---@param opts { current?: integer, width: integer, selected?: integer, total?: integer, fold_min?: integer }
---@return diffundo.Display
function M.display(view, opts)
  local width = opts.width
  local depth, children = topology_for(view)
  local time_w = M.time_width(view)
  local fold_min = opts.fold_min or 3
  local buf_lines = {}
  local spans = {}
  local folds = {}
  local row_to_line = {}

  local buf = 1
  local i = 1
  while i <= #view do
    local run_end = i
    while run_end < #view and view[run_end].parent == view[run_end + 1].seq do
      run_end = run_end + 1
    end
    local run_len = run_end - i + 1
    if run_len > fold_min then
      local caption = caption_for(view, i, run_len, depth, time_w, width)
      buf_lines[buf] = caption
      local fold_start = buf
      buf = buf + 1
      for index = i, run_end do
        row_to_line[index] = buf
        local text, row_spans = row_line(view, index, depth, children, time_w, width, opts.current)
        buf_lines[buf] = text
        for _, span in ipairs(row_spans) do
          span.line = buf - 1
          spans[#spans + 1] = span
        end
        buf = buf + 1
      end
      folds[#folds + 1] = { start = fold_start, stop = fold_start + run_len - 1 }
      i = run_end + 1
    else
      row_to_line[i] = buf
      local text, row_spans = row_line(view, i, depth, children, time_w, width, opts.current)
      buf_lines[buf] = text
      for _, span in ipairs(row_spans) do
        span.line = buf - 1
        spans[#spans + 1] = span
      end
      buf = buf + 1
      i = i + 1
    end
  end

  buf_lines[buf] = string.rep("-", width)
  local footer_start = buf
  buf = buf + 1
  for _, line in ipairs(footer_lines(view, opts, width)) do
    buf_lines[buf] = line
    buf = buf + 1
  end

  return {
    lines = buf_lines,
    spans = spans,
    folds = folds,
    row_to_line = row_to_line,
    footer_start = footer_start,
  }
end

---@param step diffundo.Step
---@return diffundo.Row
function M.row_for(step)
  return {
    seq = step.seq,
    time = step.time,
    save = step.save,
    added = step.added,
    removed = step.removed,
    parent = step.parent,
    label = label.relative(step.time) .. " - " .. step.seq,
  }
end

---@param opts { limit?: integer }
---@return diffundo.Row[]
function M.rows(opts)
  local limit = opts.limit or 500
  local collected = {}
  restore.within_source(function()
    local count = 0
    for step in walker.steps(vim.fn.undotree().seq_last + 1) do
      if count == limit then
        table.insert(collected, older)
        break
      end
      table.insert(collected, M.row_for(step))
      count = count + 1
    end
  end)
  return collected
end

---@param options { written?: boolean }
---@param row diffundo.Row
---@return boolean
local function should_skip(options, row)
  return options.written == true and row.save == nil
end

---@param candidate integer
---@param last integer
---@return boolean
local function inside_bounds(candidate, last)
  return candidate >= 1 and candidate <= last
end

---@param rows diffundo.Row[]
---@param index integer
---@param opts { dir: integer, written?: boolean }
---@return integer
function M.next(rows, index, opts)
  local dir = opts.dir
  if dir == 0 then
    return index
  end
  local candidate = index + dir
  local last = #rows
  while inside_bounds(candidate, last) do
    if should_skip(opts, rows[candidate]) then
      candidate = candidate + dir
    else
      return candidate
    end
  end
  return index
end

---@param row diffundo.Row
---@param removed boolean
---@return string[]
local function pool_for(row, removed)
  if removed then
    return row.removed
  end
  return row.added
end

---@param rows diffundo.Row[]
---@param regex vim.regex
---@param opts { removed?: boolean }|nil
---@return diffundo.Row[]
function M.filtered(rows, regex, opts)
  local removed = opts ~= nil and opts.removed == true
  local result = {}
  for _, row in ipairs(rows) do
    if lines.first_match(regex, pool_for(row, removed)) then
      table.insert(result, row)
    end
  end
  return result
end

return M
