local cache = require("diffundo.cache")
local glyphs = require("diffundo.glyphs")
local history = require("diffundo.history")
local label = require("diffundo.label")
local lines = require("diffundo.lines")
local pattern = require("diffundo.pattern")
local restore = require("diffundo.restore")
local split = require("diffundo.split")
local window = require("diffundo.window")

local M = {}

local help = "j/k move · J/K written · <cr> show in diff · / filter · zo/zc folds · q back"

---@type integer|nil
local namespace

local pending = false

---@return integer|nil
local function pane_win()
  return vim.t.diffundo_pane_win
end

---@return boolean
local function expanded()
  return vim.t.diffundo_pane_expanded == true
end

---@return integer
local function source_bn()
  return vim.t.diffundo_source_bn
end

---@return integer|nil
local function diff_win()
  return split.window_of_buffer(vim.t.diffundo_diff_bn)
end

---@return boolean
local function disabled()
  return vim.g.diffundo_history == false
end

---@param fn fun(): any
---@return any
local function keep_window(fn)
  local win = vim.api.nvim_get_current_win()
  local ok, result = pcall(fn)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

---@param fn fun(): any
---@return any
local function in_source(fn)
  local result
  vim.api.nvim_buf_call(source_bn(), function()
    result = fn()
  end)
  return result
end

---@return string
local function rows_key()
  local tree = in_source(vim.fn.undotree)
  return tree.seq_last .. ":" .. (tree.save_last or 0)
end

---@return diffundo.Row[]
local function all_rows()
  local bufnr = source_bn()
  local known, key = cache.rows(bufnr)
  local wanted = rows_key()
  if known and key == wanted then
    return known
  end
  local fresh = keep_window(function()
    return history.rows({
      known = known,
      on_lines = function(seq, state)
        cache.remember(bufnr, seq, state)
      end,
    })
  end)
  cache.store_rows(bufnr, wanted, fresh)
  return fresh
end

---@param all diffundo.Row[]
---@return diffundo.Row[]
local function view_of(all)
  local asked = vim.t.diffundo_pane_filter
  if asked == nil or not expanded() then
    return all
  end
  return history.filtered(all, pattern.compile(asked))
end

---@param all diffundo.Row[]
---@param seq integer
---@return diffundo.Row|nil
local function row_of(all, seq)
  for _, row in ipairs(all) do
    if row.seq == seq then
      return row
    end
  end
  return nil
end

---@param seq integer
---@return string[]
local function state_lines(seq)
  local bufnr = source_bn()
  local found = cache.lines(bufnr, seq)
  if found then
    return found
  end
  local got = {}
  keep_window(function()
    restore.within_source(function()
      vim.cmd("silent undo " .. seq)
      got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    end)
  end)
  cache.remember(bufnr, seq, got)
  return got
end

---@param seq integer
---@return string
local function footer_for(seq)
  local bufnr = source_bn()
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local added, removed = cache.counts(bufnr, seq, tick, function()
    local state = state_lines(seq)
    return #lines.added_lines(state, current), #lines.removed_lines(state, current)
  end)
  return ("+%d -%d lines"):format(added, removed)
end

---@param all diffundo.Row[]
---@param seq integer
---@return string
local function title_for(all, seq)
  local row = row_of(all, seq)
  if row == nil then
    return "#" .. seq
  end
  return label.title(row.seq, row.time)
end

---@param dwin integer
---@return integer
local function width_for(dwin)
  local wanted = vim.g.diffundo_history_width or 40
  return math.max(10, math.min(wanted, vim.api.nvim_win_get_width(dwin) - 2))
end

---@param dwin integer
---@param count integer
---@return integer
local function height_for(dwin, count)
  return math.max(1, math.min(count, vim.api.nvim_win_get_height(dwin) - 2))
end

---@param dwin integer
---@param height integer
---@return string, integer
local function anchor_for(dwin, height)
  local bottom = vim.api.nvim_win_get_height(dwin)
  if expanded() then
    return "SE", bottom
  end
  local line = vim.api.nvim_win_call(dwin, vim.fn.winline)
  if line > bottom - height - 2 then
    return "NE", 0
  end
  return "SE", bottom
end

---@param dwin integer
---@param height integer
---@param title string
---@param footer string
---@return table
local function config_for(dwin, height, title, footer)
  local anchor, row = anchor_for(dwin, height)
  return {
    relative = "win",
    win = dwin,
    anchor = anchor,
    row = row,
    col = vim.api.nvim_win_get_width(dwin),
    width = width_for(dwin),
    height = height,
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
    footer = " " .. footer .. " ",
    footer_pos = "right",
    focusable = expanded(),
    zindex = 50,
  }
end

---@param buffer integer
---@param current integer
---@return table<integer, boolean>|nil
local function keep_for(buffer, current)
  if expanded() then
    return nil
  end
  return { [buffer] = true, [current] = true }
end

---@param shown diffundo.Row[]
---@param display diffundo.Display
---@return integer[]
local function seqs_for(shown, display)
  local seqs = {}
  for line = 1, #display.lines do
    seqs[line] = -1
  end
  for index, line in pairs(display.row_to_line) do
    seqs[line] = shown[index].seq
  end
  return seqs
end

---@param win integer
---@param display diffundo.Display
local function paint(win, display)
  if namespace == nil then
    namespace = vim.api.nvim_create_namespace("diffundo_pane")
  end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, span in ipairs(display.spans) do
    vim.api.nvim_buf_add_highlight(buf, namespace, span.hl, span.line, span.col_start, span.col_end)
  end
end

---@param display diffundo.Display
---@return table<string, string>
local function captions_of(display)
  local captions = {}
  for line, text in pairs(display.captions) do
    captions[tostring(line)] = text
  end
  return captions
end

---@param win integer
---@param display diffundo.Display
local function fold(win, display)
  vim.t.diffundo_pane_captions = captions_of(display)
  vim.api.nvim_win_call(win, function()
    vim.wo.foldmethod = "manual"
    vim.cmd("normal! zE")
    for _, span in ipairs(display.folds) do
      vim.cmd(span.start .. "," .. span.stop .. "fold")
    end
    vim.wo.foldlevel = 0
    vim.wo.foldtext =
      "get(get(t:, 'diffundo_pane_captions', {}), v:foldstart, getline(v:foldstart))"
  end)
end

local function define_highlights()
  vim.api.nvim_set_hl(0, "DiffundoGap", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "DiffundoDiff", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "DiffundoBuffer", { bold = true, default = true })
end

local function schedule_render()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    M.render()
  end)
end

local function schedule_collapse()
  vim.schedule(function()
    if expanded() and vim.api.nvim_get_current_win() ~= pane_win() then
      M.collapse(false)
    end
  end)
end

local function schedule_close()
  vim.schedule(function()
    if not split.is_open() then
      M.close()
    end
  end)
end

---@param win integer
local function watch(win)
  local group = vim.api.nvim_create_augroup("diffundo_pane_" .. win, { clear = true })
  vim.t.diffundo_pane_group = group
  local function on(events, opts)
    opts.group = group
    vim.api.nvim_create_autocmd(events, opts)
  end
  local pane_buf = vim.api.nvim_win_get_buf(win)
  on({ "TextChanged", "InsertLeave", "BufWritePost" }, {
    buffer = source_bn(),
    callback = schedule_render,
  })
  on("CursorMoved", { buffer = source_bn(), callback = M.reposition })
  on("CursorMoved", { buffer = vim.t.diffundo_diff_bn, callback = M.reposition })
  on("CursorMoved", { buffer = pane_buf, callback = M.update_labels })
  on("WinLeave", { buffer = pane_buf, callback = schedule_collapse })
  on("WinClosed", { pattern = tostring(diff_win()), callback = schedule_close })
  on({ "WinResized", "VimResized" }, { callback = schedule_render })
end

---@param win integer
local function map_keys(win)
  window.map(win, "J", function()
    M.move_save(1)
  end)
  window.map(win, "K", function()
    M.move_save(-1)
  end)
  window.map(win, "<cr>", M.place)
  window.map(win, "/", M.filter)
  window.map(win, "g?", function()
    vim.notify(help)
  end)
  window.map(win, "q", function()
    M.collapse(true)
  end)
  window.map(win, "<esc>", function()
    M.collapse(true)
  end)
end

---@param config table
---@return integer
local function ensure_float(config)
  local win = pane_win()
  if window.is_open(win) then
    ---@cast win integer
    vim.api.nvim_win_set_config(win, config)
    return win
  end
  define_highlights()
  local opened = window.open(config, false)
  vim.t.diffundo_pane_win = opened
  map_keys(opened)
  watch(opened)
  return opened
end

function M.render()
  local dwin = diff_win()
  if disabled() or dwin == nil or not split.is_open() then
    M.close()
    return
  end
  local all = all_rows()
  local shown = view_of(all)
  local buffer = in_source(vim.fn.changenr)
  local current = vim.t.diffundo_diff_undonr
  cache.remember(
    source_bn(),
    current,
    vim.api.nvim_buf_get_lines(vim.t.diffundo_diff_bn, 0, -1, false)
  )
  local display = history.display(shown, {
    width = width_for(dwin),
    buffer = buffer,
    current = current,
    keep = keep_for(buffer, current),
    fold_min = vim.g.diffundo_fold_min or 3,
    glyphs = glyphs.get(),
  })
  local height = height_for(dwin, #display.lines)
  local win = ensure_float(config_for(dwin, height, title_for(all, current), footer_for(current)))
  window.render(win, display.lines)
  paint(win, display)
  fold(win, display)
  vim.t.diffundo_pane_seqs = seqs_for(shown, display)
end

---@return integer|nil
local function seq_at_cursor()
  local win = pane_win()
  if not window.is_open(win) then
    return nil
  end
  ---@cast win integer
  local seq = (vim.t.diffundo_pane_seqs or {})[vim.api.nvim_win_get_cursor(win)[1]]
  if seq == nil or seq < 0 then
    return nil
  end
  return seq
end

---@return integer
local function labelled_seq()
  local focused = expanded() and vim.api.nvim_get_current_win() == pane_win()
  local seq = focused and seq_at_cursor()
  if seq then
    return seq
  end
  return vim.t.diffundo_diff_undonr
end

function M.update_labels()
  local win = pane_win()
  if not window.is_open(win) or not split.is_open() then
    return
  end
  ---@cast win integer
  local seq = labelled_seq()
  vim.api.nvim_win_set_config(win, {
    title = " " .. title_for(all_rows(), seq) .. " ",
    title_pos = "left",
    footer = " " .. footer_for(seq) .. " ",
    footer_pos = "right",
  })
end

function M.reposition()
  local win = pane_win()
  local dwin = diff_win()
  if expanded() or dwin == nil or not window.is_open(win) then
    return
  end
  ---@cast win integer
  local anchor, row = anchor_for(dwin, vim.api.nvim_win_get_config(win).height)
  vim.api.nvim_win_set_config(win, {
    relative = "win",
    win = dwin,
    anchor = anchor,
    row = row,
    col = vim.api.nvim_win_get_width(dwin),
  })
end

---@param win integer
---@param line integer
local function reveal_line(win, line)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zv")
  end)
end

---@param seq integer
local function select_seq(seq)
  local win = pane_win()
  if not window.is_open(win) then
    return
  end
  ---@cast win integer
  for line, candidate in ipairs(vim.t.diffundo_pane_seqs or {}) do
    if candidate == seq then
      reveal_line(win, line)
      return
    end
  end
end

function M.focus()
  if disabled() or not split.is_open() then
    return
  end
  vim.t.diffundo_pane_expanded = true
  M.render()
  local win = pane_win()
  if not window.is_open(win) then
    return
  end
  ---@cast win integer
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_call(win, function()
    vim.wo.cursorline = true
  end)
  select_seq(vim.t.diffundo_diff_undonr)
  M.update_labels()
end

local function back_to_source()
  local dwin = diff_win()
  if dwin then
    vim.api.nvim_set_current_win(dwin)
  end
  local source = split.window_of_buffer(source_bn())
  if source then
    vim.api.nvim_set_current_win(source)
  end
end

---@param back boolean
function M.collapse(back)
  vim.t.diffundo_pane_expanded = false
  vim.t.diffundo_pane_filter = nil
  if back then
    back_to_source()
  end
  M.render()
end

function M.place()
  local seq = seq_at_cursor()
  if seq == nil then
    return
  end
  keep_window(function()
    restore.within_source(function()
      vim.cmd("silent undo " .. seq)
      split.place(vim.api.nvim_buf_get_lines(0, 0, -1, false), seq)
    end)
  end)
  M.render()
  M.update_labels()
end

---@return table<integer, boolean>
local function written()
  local saved = {}
  for _, row in ipairs(all_rows()) do
    if row.save then
      saved[row.seq] = true
    end
  end
  return saved
end

---@param dir integer
function M.move_save(dir)
  local win = pane_win()
  if not window.is_open(win) then
    return
  end
  ---@cast win integer
  local seqs = vim.t.diffundo_pane_seqs or {}
  local saved = written()
  local line = vim.api.nvim_win_get_cursor(win)[1] + dir
  while seqs[line] ~= nil do
    if saved[seqs[line]] then
      reveal_line(win, line)
      return
    end
    line = line + dir
  end
end

function M.filter()
  local asked = vim.fn.input("filter: ")
  if asked == "" then
    vim.t.diffundo_pane_filter = nil
  else
    pattern.compile(asked)
    vim.t.diffundo_pane_filter = asked
  end
  M.render()
end

function M.close()
  local win = pane_win()
  if window.is_open(win) then
    ---@cast win integer
    window.close(win)
  end
  if vim.t.diffundo_pane_group then
    pcall(vim.api.nvim_del_augroup_by_id, vim.t.diffundo_pane_group)
  end
  vim.t.diffundo_pane_win = nil
  vim.t.diffundo_pane_group = nil
  vim.t.diffundo_pane_expanded = nil
  vim.t.diffundo_pane_filter = nil
  vim.t.diffundo_pane_seqs = nil
  vim.t.diffundo_pane_captions = nil
end

return M
