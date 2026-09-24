local history = require("diffundo.history")
local pattern = require("diffundo.pattern")
local restore = require("diffundo.restore")
local split = require("diffundo.split")
local window = require("diffundo.window")

local M = {}

---@return integer|nil
local function tree_win()
  return vim.t.diffundo_history_win
end

---@return integer|nil
local function footer_win()
  return vim.t.diffundo_history_footer_win
end

---@return integer
local function panel_height()
  return math.max(4, vim.o.lines - 4)
end

---@return integer
local function tree_height()
  return panel_height() - 2
end

---@param lines string[]
---@param first integer
---@param last integer
---@return string[]
local function slice(lines, first, last)
  local result = {}
  for line = first, last do
    result[#result + 1] = lines[line]
  end
  return result
end

---@return diffundo.Row[]
local function rows()
  return vim.t.diffundo_history_rows or {}
end

---@return diffundo.Row[]
local function view()
  return vim.t.diffundo_history_view or rows()
end

---@param seq integer|nil
---@return integer|nil
local function index_of_seq(seq)
  for index, row in ipairs(view()) do
    if row.seq == seq then
      return index
    end
  end
  return nil
end

---@return integer
local function pick_source()
  if split.is_open() then
    local found = split.window_of_buffer(vim.t.diffundo_source_bn)
    if found then
      return found
    end
  end
  local candidate = vim.t.diffundo_history_source_win or vim.api.nvim_get_current_win()
  if not window.is_open(candidate) then
    error("The diffundo source window is no longer open in this tab.", 0)
  end
  return candidate
end

---@return integer|nil
local function current_seq()
  return vim.t.diffundo_diff_undonr or vim.fn.undotree().seq_cur
end

---@return integer|nil
local function current_index()
  return index_of_seq(current_seq())
end

---@param line integer
---@return integer
local function index_at_line(line)
  local display = vim.t.diffundo_history_display
  if display == nil then
    return line
  end
  for index, target in ipairs(display.row_to_line) do
    if target == line then
      return index
    end
  end
  return line
end

---@return integer
local function width()
  return vim.g.diffundo_history_width or 40
end

---@return integer
local function fold_min()
  return vim.g.diffundo_fold_min or 3
end

---@return integer|nil, integer|nil
local function floats()
  local tree = tree_win()
  if not window.is_open(tree) then
    return nil
  end
  local footer = footer_win()
  if not window.is_open(footer) then
    return nil
  end
  return tree, footer
end

local history_ns

local function render_float()
  local tree, footer = floats()
  if tree == nil or footer == nil then
    return
  end
  local display = history.display(vim.t.diffundo_history_view, {
    current = current_seq(),
    width = width(),
    selected = current_index(),
    total = #rows(),
    fold_min = fold_min(),
  })
  vim.t.diffundo_history_display = display
  local tree_buf = vim.api.nvim_win_get_buf(tree)
  window.render(tree, slice(display.lines, 1, display.footer_start - 1), { height = tree_height() })
  window.render(footer, slice(display.lines, display.footer_start, #display.lines), { height = 2 })
  if history_ns == nil then
    history_ns = vim.api.nvim_create_namespace("diffundo_history")
  end
  vim.api.nvim_buf_clear_namespace(tree_buf, history_ns, 0, -1)
  for _, span in ipairs(display.spans) do
    vim.api.nvim_buf_add_highlight(
      tree_buf,
      history_ns,
      span.hl,
      span.line,
      span.col_start,
      span.col_end
    )
  end
  vim.api.nvim_buf_call(tree_buf, function()
    vim.wo.foldmethod = "manual"
    vim.cmd("normal! zE")
    for _, fold in ipairs(display.folds) do
      vim.cmd(fold.start .. "," .. fold.stop .. "fold")
    end
    vim.wo.foldlevel = 0
    vim.wo.foldtext =
      "get(t:, 'diffundo_history_display', {}).captions[v:foldstart] ?? getline(v:foldstart)"
  end)
end

---@param float integer|nil
---@return diffundo.Row|nil
local function row_at(float)
  if float == nil then
    return nil
  end
  local index = index_at_line(vim.api.nvim_win_get_cursor(float)[1])
  local row = view()[index]
  if row == nil or row.seq == 0 then
    return nil
  end
  return row
end

---@param index integer
---@return integer
local function to_line(index)
  local display = vim.t.diffundo_history_display
  return display and display.row_to_line[index] or index
end

---@param float integer
---@param line integer
local function reveal_line(float, line)
  vim.api.nvim_win_set_cursor(float, { line, 0 })
  vim.api.nvim_win_call(float, function()
    vim.cmd("silent! normal! zv")
  end)
end

---@param seq integer|nil
local function select_row(seq)
  local index = index_of_seq(seq)
  local float = tree_win()
  if index and float then
    reveal_line(float, to_line(index))
  end
end

---@return boolean
function M.open()
  local current = tree_win()
  if current and window.is_open(current) then
    vim.api.nvim_set_current_win(current)
    return true
  end
  if vim.fn.undotree().seq_last == 0 then
    vim.notify("No changes to view!")
    return false
  end
  local source = vim.api.nvim_get_current_win()
  local collected = history.rows({})
  vim.t.diffundo_history_source_win = source
  vim.t.diffundo_history_rows = collected
  vim.t.diffundo_history_view = collected
  vim.t.diffundo_history_filter = nil
  local tree = window.open({
    lines = {},
    width = width(),
    height = tree_height(),
    row = 0,
    enter = true,
  })
  vim.t.diffundo_history_win = tree
  local footer = window.open({
    lines = { "", "" },
    width = width(),
    height = 2,
    row = panel_height() - 2,
    enter = false,
  })
  vim.t.diffundo_history_footer_win = footer
  window.map(tree, "J", function()
    M.move_save(1)
  end)
  window.map(tree, "K", function()
    M.move_save(-1)
  end)
  window.map(tree, "<cr>", function()
    M.place()
  end)
  window.map(tree, "/", function()
    M.filter()
  end)
  window.map(tree, "q", function()
    M.close()
  end)
  window.map(tree, "<esc>", function()
    M.close()
  end)
  window.map(tree, "g?", function()
    vim.notify("J/K saved jumps · <cr> place · / filter · g? help · q close")
  end)
  render_float()
  select_row(current_seq())
  return true
end

---@param seq integer
function M.reveal(seq)
  if not M.open() then
    return
  end
  local float = tree_win()
  if float and index_of_seq(seq) == nil then
    vim.t.diffundo_history_filter = nil
    vim.t.diffundo_history_view = rows()
    render_float()
  end
  select_row(seq)
end

function M.place()
  local float = tree_win()
  local row = row_at(float)
  if row == nil then
    return
  end
  local source = pick_source()
  vim.api.nvim_set_current_win(source)
  if not split.open() then
    return
  end
  restore.within_source(function()
    vim.cmd("silent undo " .. row.seq)
    split.place(vim.api.nvim_buf_get_lines(0, 0, -1, false), row.seq)
  end)
  render_float()
  if float and window.is_open(float) then
    vim.api.nvim_set_current_win(float)
  end
end

---@param dir integer
function M.move_save(dir)
  local float = tree_win()
  if float == nil or not window.is_open(float) then
    return
  end
  local index = index_at_line(vim.api.nvim_win_get_cursor(float)[1])
  local moved = history.next(view(), index, { dir = dir, written = true })
  if moved ~= index then
    reveal_line(float, to_line(moved))
  end
end

function M.filter()
  local asked = vim.fn.input("filter: ")
  if asked == "" then
    vim.t.diffundo_history_filter = nil
    vim.t.diffundo_history_view = rows()
  else
    vim.t.diffundo_history_filter = pattern.compile(asked)
    vim.t.diffundo_history_view = history.filtered(rows(), vim.t.diffundo_history_filter)
  end
  local float = tree_win()
  if float and window.is_open(float) then
    render_float()
  end
end

---@return integer
local function fallback_win()
  return vim.t.diffundo_history_source_win or vim.api.nvim_get_current_win()
end

---@param win integer|nil
local function close_float(win)
  if win == nil then
    return
  end
  if window.is_open(win) then
    window.close(win)
  end
end

function M.close()
  local float = tree_win()
  if float == nil then
    return
  end
  local fallback = fallback_win()
  close_float(float)
  close_float(footer_win())
  vim.t.diffundo_history_win = nil
  vim.t.diffundo_history_footer_win = nil
  vim.t.diffundo_history_source_win = nil
  vim.t.diffundo_history_rows = nil
  vim.t.diffundo_history_view = nil
  vim.t.diffundo_history_filter = nil
  vim.t.diffundo_history_display = nil
  if window.is_open(fallback) then
    vim.api.nvim_set_current_win(fallback)
  end
end

function M.toggle()
  if window.is_open(tree_win()) then
    M.close()
  else
    M.open()
  end
end

return M
