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

---@class diffundo.DisplayBuf
---@field lines string[]
---@field spans diffundo.Span[]
---@field folds diffundo.Fold[]
---@field row_to_line integer[]
---@field buf integer

local older = {
  seq = 0,
  time = 0,
  save = nil,
  added = {},
  removed = {},
  parent = 0,
  label = "",
}

---@param a integer
---@param r integer
---@return boolean
local function lone_added(a, r)
  return a == 1 and r == 0
end

---@param a integer
---@param r integer
---@return boolean
local function lone_removed(a, r)
  return a == 0 and r == 1
end

---@param row diffundo.Row
---@return string, { hl: string, from: integer, to: integer }[], boolean
local function single_edit(row)
  local a, r = #row.added, #row.removed
  if lone_added(a, r) then
    local text = "+ " .. row.added[1]
    return text, { { hl = "DiffAdd", from = 0, to = #text } }, true
  end
  if lone_removed(a, r) then
    local text = "- " .. row.removed[1]
    return text, { { hl = "DiffDelete", from = 0, to = #text } }, true
  end
  return "", {}, false
end

---@param name string
---@return string|nil
local function name_hl(name)
  local first = name:sub(1, 1)
  if first == "+" then
    return "DiffAdd"
  end
  if first == "-" then
    return "DiffDelete"
  end
  return nil
end

---@param row diffundo.Row
---@return string[]
local function summary_names(row)
  local a, r = #row.added, #row.removed
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
  return names
end

---@param names string[]
---@return { hl: string, from: integer, to: integer }[]
local function spans_for_names(names)
  local spans = {}
  local col = 0
  for _, name in ipairs(names) do
    local hl = name_hl(name)
    if hl then
      spans[#spans + 1] = { hl = hl, from = col, to = col + #name }
    end
    col = col + #name + 1
  end
  return spans
end

---@param row diffundo.Row
---@return string, { hl: string, from: integer, to: integer }[]
local function preview_parts(row)
  local text, spans, matched = single_edit(row)
  if matched then
    return text, spans
  end
  local names = summary_names(row)
  return table.concat(names, " "), spans_for_names(names)
end

---@param view diffundo.Row[]
---@return integer
function M.time_width(view)
  local longest = 1
  for _, row in ipairs(view) do
    if row.seq ~= 0 then
      longest = math.max(longest, #label.short(row.time))
    end
  end
  return longest + 1
end

---@param row diffundo.Row
---@return string, { hl: string, from: integer, to: integer }[]
function M.preview_parts(row)
  return preview_parts(row)
end

---@param view diffundo.Row[]
---@return table<integer, integer>
local function seq_index_for(view)
  local index = {}
  for i, r in ipairs(view) do
    if r.seq ~= 0 then
      index[r.seq] = i
    end
  end
  return index
end

---@param view diffundo.Row[]
---@param seq_index table<integer, integer>
---@return integer[][]
local function children_for(view, seq_index)
  local children = {}
  for i, r in ipairs(view) do
    local parent = seq_index[r.parent]
    if parent then
      children[parent] = children[parent] or {}
      children[parent][#children[parent] + 1] = i
    end
  end
  return children
end

---@param kids integer[]
---@param target integer
---@return integer
local function rank_of(kids, target)
  for k, child in ipairs(kids) do
    if child == target then
      return k
    end
  end
  return 1
end

---@param view diffundo.Row[]
---@param seq_index table<integer, integer>
---@param children integer[][]
---@return integer[]
local function lane_for(view, seq_index, children)
  local lane = {}
  for i = #view, 1, -1 do
    local r = view[i]
    if r.parent == 0 then
      lane[i] = 1
    else
      local parent = seq_index[r.parent]
      if parent and lane[parent] then
        lane[i] = lane[parent] + rank_of(children[parent], i) - 1
      end
    end
  end
  return lane
end

---@param view diffundo.Row[]
---@param lane integer[]
---@return integer[]
local function fill_lanes(view, lane)
  local prev = 0
  for i = 1, #view do
    if lane[i] then
      prev = lane[i]
    else
      lane[i] = prev + 1
    end
  end
  return lane
end

---@param view diffundo.Row[]
---@param children integer[][]
---@return integer[]
local function subtree_ends(view, children)
  local last = {}
  for i = 1, #view do
    local stop = i
    local kids = children[i]
    if kids then
      for _, child in ipairs(kids) do
        if last[child] > stop then
          stop = last[child]
        end
      end
    end
    last[i] = stop
  end
  return last
end

---@param open table<integer, table<integer, boolean>>
---@param col integer
---@param start_i integer
---@param stop_i integer
local function mark_open(open, col, start_i, stop_i)
  for i = start_i, stop_i do
    local row = open[i] or {}
    row[col] = true
    open[i] = row
  end
end

---@param view diffundo.Row[]
---@param children integer[][]
---@param lane integer[]
---@param last integer[]
---@return table<integer, table<integer, boolean>>
local function open_columns(view, children, lane, last)
  local open = {}
  for i = 1, #view do
    local kids = children[i]
    if kids then
      for k = 2, #kids do
        local arm = kids[k]
        mark_open(open, lane[arm], arm, last[arm])
      end
    end
  end
  return open
end

---@param view diffundo.Row[]
---@return integer[], integer[][], table<integer, table<integer, boolean>>
local function topology_for(view)
  local seq_index = seq_index_for(view)
  local children = children_for(view, seq_index)
  local lane = fill_lanes(view, lane_for(view, seq_index, children))
  local open = open_columns(view, children, lane, subtree_ends(view, children))
  return lane, children, open
end

---@param is_current boolean
---@param save boolean
---@return string
local function node_glyph(is_current, save)
  if is_current then
    if save then
      return "◉"
    end
    return "○"
  end
  if save then
    return "●"
  end
  return "│"
end

---@param k integer
---@param tails integer
---@return string
local function arm_glyph(k, tails)
  if k < tails then
    return "┬"
  end
  return "┐"
end

---@param kids integer[]
---@param i integer
---@param last integer
---@param is_current boolean
---@param save boolean
---@return string[]
local function lane_cells(kids, i, last, is_current, save)
  if #kids >= 2 then
    local tails = #kids - 1
    local cells = { "├" }
    for k = 1, tails do
      cells[#cells + 1] = arm_glyph(k, tails)
    end
    return cells
  end
  if i == last then
    return { "└" }
  end
  return { node_glyph(is_current, save) }
end

---@param lane integer
---@param open_i table<integer, boolean>|nil
---@return string[]
local function pass_columns(lane, open_i)
  local cells = {}
  for c = 1, lane - 1 do
    if c == 1 then
      cells[c] = "┊"
    elseif open_i then
      if open_i[c] then
        cells[c] = "┊"
      else
        cells[c] = " "
      end
    else
      cells[c] = " "
    end
  end
  return cells
end

---@param i integer
---@param lane integer
---@param children integer[][]
---@param open_i table<integer, boolean>|nil
---@param last_row integer
---@param is_current boolean
---@param save boolean
---@return string
local function gutter_for(i, lane, children, open_i, last_row, is_current, save)
  local cells = pass_columns(lane, open_i)
  for _, cell in ipairs(lane_cells(children[i] or {}, i, last_row, is_current, save)) do
    cells[#cells + 1] = cell
  end
  return table.concat(cells, "")
end

---@param view diffundo.Row[]
---@param i integer
---@param lane integer[]
---@param open table<integer, table<integer, boolean>>
---@param children integer[][]
---@param time_w integer
---@param width integer
---@param current integer|nil
---@return string, diffundo.Span[]
local function row_line(view, i, lane, open, children, time_w, width, current)
  local r = view[i]
  local gutter = gutter_for(i, lane[i], children, open[i], #view, r.seq == current, r.save ~= nil)
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
---@param lane integer[]
---@param open table<integer, table<integer, boolean>>
---@param time_w integer
---@param width integer
---@return string
local function caption_for(view, first, count, lane, open, time_w, width)
  local added, removed = 0, 0
  for offset = 0, count - 1 do
    added = added + #view[first + offset].added
    removed = removed + #view[first + offset].removed
  end
  local text = string.format("+%d states: +%d -%d lines %d undos", count, added, removed, count)
  local gutter = gutter_for(first, lane[first], {}, open[first], #view, false, false)
  local time = label.short(view[first].time)
  local body_w = width - #gutter - time_w
  return gutter
    .. text
    .. string.rep(" ", math.max(0, body_w - #text))
    .. string.rep(" ", math.max(0, time_w - #time))
    .. time
end

---@param index integer
---@param size integer
---@return integer
local function clamp_index(index, size)
  if index < 1 then
    return 1
  end
  if index > size then
    return size
  end
  return index
end

---@param r diffundo.Row
---@param current integer|nil
---@return string
local function meaning_for(r, current)
  if current == r.seq then
    if r.save then
      return "◉ saved"
    end
    return "○"
  end
  if r.save then
    return "● saved"
  end
  return ""
end

---@param r diffundo.Row
---@param current integer|nil
---@param width integer
---@return string
local function status_line(r, current, width)
  local absolute = os.date("%Y-%m-%d %I:%M:%S %p", r.time)
  local text = ("#%d %s %s +%d -%d"):format(
    r.seq,
    meaning_for(r, current),
    absolute,
    #r.added,
    #r.removed
  )
  if #text > width then
    return text:sub(1, width)
  end
  return text
end

---@param shown integer
---@param total integer
---@param width integer
---@return string
local function pager_line(shown, total, width)
  local hint = "help: g?"
  local text = ("%d/%d"):format(shown, total)
  return text .. string.rep(" ", math.max(0, width - #text - #hint)) .. hint
end

---@param view diffundo.Row[]
---@return integer
local function visible_count(view)
  local shown = 0
  for _, r in ipairs(view) do
    if r.seq ~= 0 then
      shown = shown + 1
    end
  end
  return shown
end

---@param view diffundo.Row[]
---@param opts { selected?: integer, total?: integer, current?: integer }
---@param width integer
---@return string[]
local function footer_lines(view, opts, width)
  local shown = visible_count(view)
  local total = opts.total or shown
  if #view == 0 then
    return { "no matches", pager_line(0, total, width) }
  end
  local index = clamp_index(opts.selected or 1, #view)
  local r = view[index]
  return { status_line(r, opts.current, width), pager_line(shown, total, width) }
end

---@param view diffundo.Row[]
---@param i integer
---@return integer
local function run_end_for(view, i)
  local run_end = i
  while
    run_end < #view
    and view[run_end].parent == view[run_end + 1].seq
    and view[run_end + 1].seq ~= 0
  do
    run_end = run_end + 1
  end
  return run_end
end

---@param view diffundo.Row[]
---@param index integer
---@param lane integer[]
---@param open table<integer, table<integer, boolean>>
---@param children integer[][]
---@param time_w integer
---@param width integer
---@param current integer|nil
---@param state diffundo.DisplayBuf
local function emit_row(view, index, lane, open, children, time_w, width, current, state)
  local text, row_spans = row_line(view, index, lane, open, children, time_w, width, current)
  state.row_to_line[index] = state.buf
  state.lines[state.buf] = text
  for _, span in ipairs(row_spans) do
    span.line = state.buf - 1
    state.spans[#state.spans + 1] = span
  end
  state.buf = state.buf + 1
end

---@param view diffundo.Row[]
---@param i integer
---@param run_end integer
---@param fold_min integer
---@param lane integer[]
---@param open table<integer, table<integer, boolean>>
---@param children integer[][]
---@param time_w integer
---@param width integer
---@param current integer|nil
---@param state diffundo.DisplayBuf
---@return integer
local function emit_run(
  view,
  i,
  run_end,
  fold_min,
  lane,
  open,
  children,
  time_w,
  width,
  current,
  state
)
  local run_len = run_end - i + 1
  if run_len > fold_min then
    local start = state.buf
    state.lines[start] = caption_for(view, i, run_len, lane, open, time_w, width)
    state.buf = start + 1
    for index = i, run_end do
      emit_row(view, index, lane, open, children, time_w, width, current, state)
    end
    state.folds[#state.folds + 1] = { start = start, stop = start + run_len - 1 }
    return run_end + 1
  end
  emit_row(view, i, lane, open, children, time_w, width, current, state)
  return i + 1
end

---@param view diffundo.Row[]
---@param opts { current?: integer, width: integer, selected?: integer, total?: integer, fold_min?: integer }
---@return diffundo.Display
function M.display(view, opts)
  local width = opts.width
  local lane, children, open = topology_for(view)
  local time_w = M.time_width(view)
  local fold_min = opts.fold_min or 3
  local state = {
    lines = {},
    spans = {},
    folds = {},
    row_to_line = {},
    buf = 1,
  }
  local i = 1
  while i <= #view do
    if view[i].seq == 0 then
      i = i + 1
    else
      local run_end = run_end_for(view, i)
      i = emit_run(
        view,
        i,
        run_end,
        fold_min,
        lane,
        open,
        children,
        time_w,
        width,
        opts.current,
        state
      )
    end
  end
  local buf_lines = state.lines
  buf_lines[state.buf] = string.rep("-", width)
  local footer_start = state.buf
  state.buf = state.buf + 1
  for _, line in ipairs(footer_lines(view, opts, width)) do
    buf_lines[state.buf] = line
    state.buf = state.buf + 1
  end
  return {
    lines = buf_lines,
    spans = state.spans,
    folds = state.folds,
    row_to_line = state.row_to_line,
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
