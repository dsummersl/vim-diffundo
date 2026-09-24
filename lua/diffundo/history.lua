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
---@field captions table<integer, string>
---@field footer_start integer

---@class diffundo.DisplayBuf
---@field lines string[]
---@field spans diffundo.Span[]
---@field folds diffundo.Fold[]
---@field row_to_line integer[]
---@field captions table<integer, string>
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
      longest = math.max(longest, #(label.short(row.time) .. " - " .. row.seq))
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

---@param view diffundo.Row[]
---@param seq_index table<integer, integer>
---@return table<integer, boolean>
local function trunk_of(view, seq_index)
  local trunk = {}
  local i = 1
  while i do
    local r = view[i]
    if not r then
      break
    end
    trunk[r.seq] = true
    if r.parent == 0 then
      break
    end
    i = seq_index[r.parent]
  end
  return trunk
end

---@param seq_index table<integer, integer>
---@param children integer[][]
---@param view diffundo.Row[]
---@param lane integer[]
---@param i integer
---@return integer|nil
local function branch_lane(seq_index, children, view, lane, i)
  local parent = seq_index[view[i].parent]
  if not parent or not lane[parent] then
    return nil
  end
  local kids = children[parent]
  if #kids == 1 then
    return lane[parent]
  end
  return lane[parent] + 1
end

---@param view diffundo.Row[]
---@param seq_index table<integer, integer>
---@param children integer[][]
---@param trunk table<integer, boolean>
---@return integer[]
local function lane_for(view, seq_index, children, trunk)
  local lane = {}
  for i = #view, 1, -1 do
    if view[i].parent == 0 or trunk[view[i].seq] then
      lane[i] = 1
    else
      lane[i] = branch_lane(seq_index, children, view, lane, i)
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

---@param view diffundo.Row[]
---@param children integer[][]
---@return integer[]
local function subtree_starts(view, children)
  local first = {}
  for i = 1, #view do
    local stop = i
    local kids = children[i]
    if kids then
      for _, child in ipairs(kids) do
        if first[child] < stop then
          stop = first[child]
        end
      end
    end
    first[i] = stop
  end
  return first
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
---@param trunk table<integer, boolean>
---@return table<integer, table<integer, boolean>>
local function open_columns(view, children, lane, first, last, trunk)
  local open = {}
  for i = 1, #view do
    local kids = children[i]
    if kids then
      for _, arm in ipairs(kids) do
        if trunk[view[arm].seq] == nil then
          mark_open(open, lane[arm], first[arm], last[arm])
        end
      end
    end
  end
  return open
end

---@param view diffundo.Row[]
---@param seq_index table<integer, integer>
---@return table<integer, boolean>
local function heads_for(view, seq_index)
  local heads = {}
  for i = 1, #view do
    heads[i] = true
  end
  for i, r in ipairs(view) do
    local parent = seq_index[r.parent]
    if parent and i < parent then
      heads[parent] = false
    end
  end
  return heads
end

---@param view diffundo.Row[]
---@return integer[], table<integer, table<integer, boolean>>, table<integer, boolean>
local function topology_for(view)
  local seq_index = seq_index_for(view)
  local children = children_for(view, seq_index)
  local trunk = trunk_of(view, seq_index)
  local lane = fill_lanes(view, lane_for(view, seq_index, children, trunk))
  local open = open_columns(
    view,
    children,
    lane,
    subtree_starts(view, children),
    subtree_ends(view, children),
    trunk
  )
  return lane, open, heads_for(view, seq_index)
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

---@param i integer
---@param lane integer[]
---@param other integer
---@return boolean
local function lane_gap(i, lane, other)
  return (lane[other] or 0) ~= lane[i]
end

---@param i integer
---@param lane integer[]
---@return boolean
local function junction_for(i, lane)
  local own = lane[i]
  if own == nil or own < 2 then
    return false
  end
  return lane_gap(i, lane, i - 1) or lane_gap(i, lane, i + 1)
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
---@param lane integer[]
---@param open_i table<integer, boolean>|nil
---@param is_current boolean
---@param save boolean
---@return string
local function gutter_for(i, lane, open_i, is_current, save)
  local cells = pass_columns(lane[i], open_i)
  if junction_for(i, lane) then
    for c = 1, lane[i] - 2 do
      cells[c] = "┊"
    end
    cells[lane[i] - 1] = "├"
    cells[lane[i]] = "┘"
  else
    cells[lane[i]] = node_glyph(is_current, save)
  end
  return table.concat(cells, "")
end

---@param b integer
---@return boolean
local function char_start(b)
  return b < 0x80 or b >= 0xC0
end

---@param s string
---@return integer
local function cell_width(s)
  local width = 0
  for i = 1, #s do
    if char_start(s:byte(i)) then
      width = width + 1
    end
  end
  return width
end

---@param s string
---@param budget integer
---@return string
local function truncate_cells(s, budget)
  if cell_width(s) <= budget then
    return s
  end
  local out = {}
  local width = 0
  for i = 1, #s do
    local b = s:byte(i)
    if char_start(b) then
      width = width + 1
      if width > budget - 1 then
        break
      end
    end
    out[#out + 1] = s:sub(i, i)
  end
  return table.concat(out, "") .. "…"
end

---@param view diffundo.Row[]
---@param i integer
---@param gutters string[]
---@param tree_w integer
---@param time_w integer
---@param width integer
---@return string, diffundo.Span[]
local function row_line(view, i, gutters, tree_w, time_w, width)
  local r = view[i]
  local gutter = gutters[i]
  local tree = gutter .. string.rep(" ", tree_w - cell_width(gutter) + 1)
  local preview, marks = preview_parts(r)
  local time = label.short(r.time) .. " - " .. r.seq
  local body_w = width - tree_w - 1 - time_w
  if cell_width(preview) > body_w then
    preview = truncate_cells(preview, math.max(0, body_w))
    marks = {}
  end
  local line = tree
    .. preview
    .. string.rep(" ", math.max(0, body_w - cell_width(preview)))
    .. string.rep(" ", math.max(0, time_w - cell_width(time)))
    .. time
  local spans = {}
  local base = #tree
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
---@return string
local function caption_text(view, first, count)
  local added, removed = 0, 0
  for offset = 0, count - 1 do
    added = added + #view[first + offset].added
    removed = removed + #view[first + offset].removed
  end
  return string.format("+%d states: +%d -%d lines %d undos", count, added, removed, count)
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
  if cell_width(text) > width then
    return truncate_cells(text, math.max(0, width))
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
---@param lane integer[]
---@return integer
local function run_end_for(view, i, lane)
  local run_end = i
  while
    run_end < #view
    and view[run_end].parent == view[run_end + 1].seq
    and lane[run_end + 1] == lane[i]
    and not junction_for(run_end + 1, lane)
  do
    run_end = run_end + 1
  end
  return run_end
end

---@param i integer
---@param lane integer[]
---@param heads table<integer, boolean>
---@return boolean
local function standalone(i, lane, heads)
  return heads[i] or lane[i] == 1 or junction_for(i, lane)
end

---@param view diffundo.Row[]
---@param index integer
---@param gutters string[]
---@param tree_w integer
---@param time_w integer
---@param width integer
---@param state diffundo.DisplayBuf
local function emit_row(view, index, gutters, tree_w, time_w, width, state)
  local text, row_spans = row_line(view, index, gutters, tree_w, time_w, width)
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
---@param gutters string[]
---@param tree_w integer
---@param time_w integer
---@param width integer
---@param state diffundo.DisplayBuf
---@return integer
local function emit_run(view, i, run_end, fold_min, gutters, tree_w, time_w, width, state)
  local run_len = run_end - i + 1
  if run_len > fold_min then
    local start = state.buf
    for index = i, run_end do
      emit_row(view, index, gutters, tree_w, time_w, width, state)
    end
    state.folds[#state.folds + 1] = { start = start, stop = start + run_len - 1 }
    state.captions[start] = caption_text(view, i, run_len)
    return run_end + 1
  end
  emit_row(view, i, gutters, tree_w, time_w, width, state)
  return i + 1
end

---@param view diffundo.Row[]
---@param lane integer[]
---@param open table<integer, table<integer, boolean>>
---@param current integer|nil
---@return string[], integer
local function gutters_for(view, lane, open, current)
  local gutters = {}
  local tree_w = 1
  for i = 1, #view do
    if view[i].seq ~= 0 then
      local gutter = gutter_for(i, lane, open[i], view[i].seq == current, view[i].save ~= nil)
      gutters[i] = gutter
      tree_w = math.max(tree_w, cell_width(gutter))
    end
  end
  return gutters, tree_w
end

---@param buf_lines string[]
---@param footer string[]
---@param height integer|nil
---@return integer
local function append_footer(buf_lines, footer, height)
  local padding = 0
  if height then
    padding = math.max(0, height - (#buf_lines + #footer))
  end
  local footer_start = #buf_lines + padding + 1
  for _ = 1, padding do
    buf_lines[#buf_lines + 1] = ""
  end
  for _, line in ipairs(footer) do
    buf_lines[#buf_lines + 1] = line
  end
  return footer_start
end

---@param view diffundo.Row[]
---@param opts { current?: integer, width: integer, selected?: integer, total?: integer, fold_min?: integer, height?: integer }
---@return diffundo.Display
function M.display(view, opts)
  local width = opts.width
  local lane, open, heads = topology_for(view)
  local gutters, tree_w = gutters_for(view, lane, open, opts.current)
  local time_w = M.time_width(view)
  local fold_min = opts.fold_min or 3
  local state = {
    lines = {},
    spans = {},
    folds = {},
    row_to_line = {},
    captions = {},
    buf = 1,
  }
  local i = 1
  while i <= #view do
    if view[i].seq == 0 then
      i = i + 1
    elseif standalone(i, lane, heads) then
      emit_row(view, i, gutters, tree_w, time_w, width, state)
      i = i + 1
    else
      local run_end = run_end_for(view, i, lane)
      i = emit_run(view, i, run_end, fold_min, gutters, tree_w, time_w, width, state)
    end
  end
  local footer_start = append_footer(state.lines, footer_lines(view, opts, width), opts.height)
  return {
    lines = state.lines,
    spans = state.spans,
    folds = state.folds,
    row_to_line = state.row_to_line,
    captions = state.captions,
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
