local glyphs = require("diffundo.glyphs")
local lines = require("diffundo.lines")
local restore = require("diffundo.restore")
local tree = require("diffundo.tree")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]
---@field removed string[]
---@field parent integer

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
---@field row_to_line table<integer, integer>
---@field captions table<integer, string>

---@class diffundo.DisplayBuf
---@field lines string[]
---@field spans diffundo.Span[]
---@field folds diffundo.Fold[]
---@field row_to_line table<integer, integer>
---@field captions table<integer, string>
---@field buf integer

---@class diffundo.DisplayOpts
---@field width integer
---@field buffer integer|nil
---@field current integer|nil
---@field keep table<integer, boolean>|nil
---@field fold_min integer|nil
---@field glyphs diffundo.Glyphs|nil

---@class diffundo.Context
---@field view diffundo.Row[]
---@field lane integer[]
---@field heads table<integer, boolean>
---@field gutters table<integer, string>
---@field tree_w integer
---@field seq_w integer
---@field width integer
---@field opts diffundo.DisplayOpts
---@field glyphs diffundo.Glyphs

---@type diffundo.Row
M.original = {
  seq = 0,
  time = 0,
  save = nil,
  added = {},
  removed = {},
  parent = 0,
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

---@param added integer
---@param removed integer
---@return string[]
local function summary_names(added, removed)
  local names = {}
  if added > 0 then
    names[#names + 1] = "+" .. added
  end
  if removed > 0 then
    names[#names + 1] = "-" .. removed
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
  if row.seq == 0 then
    return "", {}
  end
  local text, spans, matched = single_edit(row)
  if matched then
    return text, spans
  end
  local names = summary_names(#row.added, #row.removed)
  return table.concat(names, " "), spans_for_names(names)
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

---@param r diffundo.Row
---@param opts diffundo.DisplayOpts
---@param g diffundo.Glyphs
---@return string
local function pip_for(r, opts, g)
  if r.seq == opts.buffer then
    return g.buffer
  end
  if r.save then
    return g.write
  end
  if r.seq == opts.current then
    return g.diff
  end
  return "│"
end

---@param pip string
---@return string
local function cap_for(pip)
  if pip == "│" then
    return "┘"
  end
  return pip
end

---@param lane integer
---@param open_i table<integer, boolean>|nil
---@return string[]
local function pass_columns(lane, open_i)
  local cells = {}
  for c = 1, lane - 1 do
    if c == 1 or (open_i and open_i[c]) then
      cells[c] = "┊"
    else
      cells[c] = " "
    end
  end
  return cells
end

---@param i integer
---@param lane integer[]
---@param open_i table<integer, boolean>|nil
---@param pip string
---@return string
local function gutter_for(i, lane, open_i, pip)
  local cells = pass_columns(lane[i], open_i)
  if junction_for(i, lane) then
    for c = 1, lane[i] - 2 do
      cells[c] = "┊"
    end
    cells[lane[i] - 1] = "├"
    cells[lane[i]] = cap_for(pip)
  else
    cells[lane[i]] = pip
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
---@param ellipsis string
---@return string
local function truncate_cells(s, budget, ellipsis)
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
  return table.concat(out, "") .. ellipsis
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
---@param lane integer[]
---@param open table<integer, table<integer, boolean>>
---@param opts diffundo.DisplayOpts
---@param g diffundo.Glyphs
---@return table<integer, string>
local function gutters_for(view, lane, open, opts, g)
  local gutters = {}
  for i, r in ipairs(view) do
    gutters[i] = gutter_for(i, lane, open[i], pip_for(r, opts, g))
  end
  return gutters
end

---@param view diffundo.Row[]
---@param gutters table<integer, string>
---@param keep table<integer, boolean>|nil
---@return integer
local function tree_width(view, gutters, keep)
  local width = 1
  for i, r in ipairs(view) do
    if keep == nil or keep[r.seq] then
      width = math.max(width, cell_width(gutters[i]))
    end
  end
  return width
end

---@param view diffundo.Row[]
---@return integer
local function seq_width(view)
  local width = 2
  for _, r in ipairs(view) do
    width = math.max(width, #("#" .. r.seq))
  end
  return width
end

---@param r diffundo.Row
---@param opts diffundo.DisplayOpts
---@return string|nil
local function row_hl(r, opts)
  if r.seq == opts.buffer then
    return "DiffundoBuffer"
  end
  if r.seq == opts.current then
    return "DiffundoDiff"
  end
  return nil
end

---@param state diffundo.DisplayBuf
---@param text string
---@param spans diffundo.Span[]
local function emit_line(state, text, spans)
  state.lines[state.buf] = text
  for _, span in ipairs(spans) do
    span.line = state.buf - 1
    state.spans[#state.spans + 1] = span
  end
  state.buf = state.buf + 1
end

---@param ctx diffundo.Context
---@param i integer
---@return string, diffundo.Span[]
local function row_line(ctx, i)
  local r = ctx.view[i]
  local gutter = ctx.gutters[i]
  local prefix = gutter .. string.rep(" ", ctx.tree_w - cell_width(gutter) + 1)
  local preview, marks = preview_parts(r)
  local seq = "#" .. r.seq
  local body_w = math.max(0, ctx.width - ctx.tree_w - 1 - ctx.seq_w - 1)
  if cell_width(preview) > body_w then
    preview = truncate_cells(preview, body_w, ctx.glyphs.ellipsis)
    marks = {}
  end
  local pad = body_w - cell_width(preview) + 1 + ctx.seq_w - #seq
  local line = prefix .. preview .. string.rep(" ", pad) .. seq
  local spans = {}
  local hl = row_hl(r, ctx.opts)
  if hl then
    spans[1] = { line = 0, hl = hl, col_start = 0, col_end = #line }
  end
  for _, mark in ipairs(marks) do
    spans[#spans + 1] =
      { line = 0, hl = mark.hl, col_start = #prefix + mark.from, col_end = #prefix + mark.to }
  end
  return line, spans
end

---@param ctx diffundo.Context
---@param count integer
---@param writes integer
---@return string
local function caption_text(ctx, count, writes)
  local text = ctx.glyphs.gap .. string.rep(" ", ctx.tree_w + 2) .. count .. " undo"
  if count ~= 1 then
    text = text .. "s"
  end
  if writes > 0 then
    text = text .. " " .. writes .. ctx.glyphs.write
  end
  return text
end

---@param view diffundo.Row[]
---@param first integer
---@param last integer
---@return integer
local function writes_in(view, first, last)
  local writes = 0
  for index = first, last do
    if view[index].save then
      writes = writes + 1
    end
  end
  return writes
end

---@param ctx diffundo.Context
---@param index integer
---@param state diffundo.DisplayBuf
local function emit_row(ctx, index, state)
  local text, spans = row_line(ctx, index)
  state.row_to_line[index] = state.buf
  emit_line(state, text, spans)
end

---@param ctx diffundo.Context
---@param i integer
---@param run_end integer
---@param state diffundo.DisplayBuf
---@return integer
local function emit_run(ctx, i, run_end, state)
  local run_len = run_end - i + 1
  if run_len <= (ctx.opts.fold_min or 3) then
    emit_row(ctx, i, state)
    return i + 1
  end
  local start = state.buf
  for index = i, run_end do
    emit_row(ctx, index, state)
  end
  state.folds[#state.folds + 1] = { start = start, stop = start + run_len - 1 }
  state.captions[start] = caption_text(ctx, run_len, writes_in(ctx.view, i, run_end))
  return run_end + 1
end

---@param ctx diffundo.Context
---@param state diffundo.DisplayBuf
local function expanded(ctx, state)
  local i = 1
  while i <= #ctx.view do
    if standalone(i, ctx.lane, ctx.heads) then
      emit_row(ctx, i, state)
      i = i + 1
    else
      i = emit_run(ctx, i, run_end_for(ctx.view, i, ctx.lane), state)
    end
  end
end

---@param acc { n: integer, w: integer }
---@param r diffundo.Row
local function tally(acc, r)
  if r.seq == 0 then
    return
  end
  acc.n = acc.n + 1
  if r.save then
    acc.w = acc.w + 1
  end
end

---@param ctx diffundo.Context
---@param state diffundo.DisplayBuf
---@param acc { n: integer, w: integer }
local function flush(ctx, state, acc)
  if acc.n > 0 then
    local text = caption_text(ctx, acc.n, acc.w)
    emit_line(state, text, { { line = 0, hl = "DiffundoGap", col_start = 0, col_end = #text } })
  end
  acc.n, acc.w = 0, 0
end

---@param ctx diffundo.Context
---@param state diffundo.DisplayBuf
---@param keep table<integer, boolean>
local function collapsed(ctx, state, keep)
  local acc = { n = 0, w = 0 }
  for i, r in ipairs(ctx.view) do
    if keep[r.seq] then
      flush(ctx, state, acc)
      emit_row(ctx, i, state)
    else
      tally(acc, r)
    end
  end
  flush(ctx, state, acc)
end

---@param view diffundo.Row[]
---@param opts diffundo.DisplayOpts
---@return diffundo.Display
function M.display(view, opts)
  local g = opts.glyphs or glyphs.defaults
  local lane, open, heads = topology_for(view)
  local gutters = gutters_for(view, lane, open, opts, g)
  ---@type diffundo.Context
  local ctx = {
    view = view,
    lane = lane,
    heads = heads,
    gutters = gutters,
    tree_w = tree_width(view, gutters, opts.keep),
    seq_w = seq_width(view),
    width = opts.width,
    opts = opts,
    glyphs = g,
  }
  ---@type diffundo.DisplayBuf
  local state = { lines = {}, spans = {}, folds = {}, row_to_line = {}, captions = {}, buf = 1 }
  if opts.keep then
    collapsed(ctx, state, opts.keep)
  else
    expanded(ctx, state)
  end
  return {
    lines = state.lines,
    spans = state.spans,
    folds = state.folds,
    row_to_line = state.row_to_line,
    captions = state.captions,
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
  }
end

---@param rows diffundo.Row[]
local function refresh_saves(rows)
  local saves = {}
  for _, state in ipairs(tree.states(vim.fn.undotree())) do
    saves[state.seq] = state.save
  end
  for _, row in ipairs(rows) do
    row.save = saves[row.seq]
  end
end

---@param opts { on_lines?: fun(seq: integer, lines: string[]) }
---@param step diffundo.Step
local function remember(opts, step)
  if opts.on_lines then
    opts.on_lines(step.seq, step.lines)
    opts.on_lines(step.parent, step.parent_lines)
  end
end

---@param known diffundo.Row[]
---@return integer
local function newest_known(known)
  local first = known[1]
  if first == nil or first.seq > vim.fn.undotree().seq_last then
    return -1
  end
  return first.seq
end

---@param fresh diffundo.Row[]
---@param known diffundo.Row[]
---@param newest integer
---@return diffundo.Row[]
local function merged(fresh, known, newest)
  if newest < 0 then
    fresh[#fresh + 1] = M.original
    return fresh
  end
  for _, row in ipairs(known) do
    fresh[#fresh + 1] = row
  end
  return fresh
end

---@param opts { limit?: integer, known?: diffundo.Row[], on_lines?: fun(seq: integer, lines: string[]) }
---@return diffundo.Row[]
function M.rows(opts)
  local limit = opts.limit or 500
  local fresh = {}
  local collected = {}
  restore.within_source(function()
    local newest = newest_known(opts.known or {})
    for step in walker.steps(vim.fn.undotree().seq_last + 1, newest) do
      if #fresh == limit then
        break
      end
      remember(opts, step)
      fresh[#fresh + 1] = M.row_for(step)
    end
    collected = merged(fresh, opts.known or {}, newest)
    refresh_saves(collected)
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
