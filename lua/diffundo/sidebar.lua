local history = require("diffundo.history")
local pattern = require("diffundo.pattern")
local restore = require("diffundo.restore")
local split = require("diffundo.split")
local window = require("diffundo.window")

local M = {}

---@return integer|nil
local function win()
  return vim.t.diffundo_history_win
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

---@return string[]
local function rendered_lines()
  local width = vim.g.diffundo_history_width or 40
  local lines = {}
  for index, row in ipairs(view()) do
    lines[index] = history.render(row, width)
  end
  return lines
end

---@param float integer|nil
---@return diffundo.Row|nil
local function row_at(float)
  local index = float and vim.api.nvim_win_get_cursor(float)[1] or 1
  local row = view()[index]
  if row == nil or row.seq == 0 then
    return nil
  end
  return row
end

---@param seq integer|nil
local function select_row(seq)
  local index = index_of_seq(seq)
  local float = win()
  if index and float then
    vim.api.nvim_win_set_cursor(float, { index, 0 })
  end
end

---@return boolean
function M.open()
  local current = win()
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
  local float = window.open({
    lines = rendered_lines(),
    title = "diffundo history",
    width = vim.g.diffundo_history_width or 40,
  })
  vim.t.diffundo_history_win = float
  window.map(float, "J", function()
    M.move_save(1)
  end)
  window.map(float, "K", function()
    M.move_save(-1)
  end)
  window.map(float, "<cr>", function()
    M.place()
  end)
  window.map(float, "/", function()
    M.filter()
  end)
  window.map(float, "q", function()
    M.close()
  end)
  window.map(float, "<esc>", function()
    M.close()
  end)
  select_row(vim.t.diffundo_diff_undonr)
  return true
end

---@param seq integer
function M.reveal(seq)
  if not M.open() then
    return
  end
  local float = win()
  if float and index_of_seq(seq) == nil then
    vim.t.diffundo_history_filter = nil
    vim.t.diffundo_history_view = rows()
    window.render(float, rendered_lines())
  end
  select_row(seq)
end

function M.place()
  local float = win()
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
  if float and window.is_open(float) then
    vim.api.nvim_set_current_win(float)
  end
end

---@param dir integer
function M.move_save(dir)
  local float = win()
  if float == nil or not window.is_open(float) then
    return
  end
  local index = vim.api.nvim_win_get_cursor(float)[1]
  local moved = history.next(view(), index, { dir = dir, written = true })
  if moved ~= index then
    vim.api.nvim_win_set_cursor(float, { moved, 0 })
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
  local float = win()
  if float and window.is_open(float) then
    window.render(float, rendered_lines())
  end
end

function M.close()
  local float = win()
  if float == nil then
    return
  end
  local fallback = vim.t.diffundo_history_source_win or vim.api.nvim_get_current_win()
  if window.is_open(float) then
    window.close(float)
  end
  vim.t.diffundo_history_win = nil
  vim.t.diffundo_history_source_win = nil
  vim.t.diffundo_history_rows = nil
  vim.t.diffundo_history_view = nil
  vim.t.diffundo_history_filter = nil
  if window.is_open(fallback) then
    vim.api.nvim_set_current_win(fallback)
  end
end

function M.toggle()
  if window.is_open(win()) then
    M.close()
  else
    M.open()
  end
end

return M
