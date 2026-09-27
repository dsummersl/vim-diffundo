local label = require("diffundo.label")

local M = {}

---@param bufnr integer|nil
---@return integer|nil
function M.window_of_buffer(bufnr)
  if bufnr == nil then
    return nil
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---@param source boolean
function M.focus(source)
  local bufnr = source and vim.t.diffundo_source_bn or vim.t.diffundo_diff_bn
  local win = M.window_of_buffer(bufnr)
  if win == nil then
    error("The diffundo split is no longer open in this tab.", 0)
  end

  vim.api.nvim_set_current_win(win)
end

---@return boolean
function M.is_open()
  local diff_bn = vim.t.diffundo_diff_bn
  if diff_bn == nil or not vim.api.nvim_buf_is_valid(diff_bn) then
    return false
  end

  if vim.t.diffundo_diff_undonr == nil then
    return false
  end

  return M.window_of_buffer(vim.t.diffundo_source_bn) ~= nil and M.window_of_buffer(diff_bn) ~= nil
end

---@param lines string[]
---@param undonr integer
function M.place(lines, undonr)
  M.focus(false)
  vim.bo.readonly = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.readonly = true
  vim.t.diffundo_diff_undonr = undonr
  label.apply(label.name(undonr))
end

local function diff_window()
  vim.cmd("diffthis")
  vim.wo.foldlevel = 0
end

local function new_buffer()
  local filetype = vim.bo.filetype
  local undonr = vim.fn.changenr()
  vim.t.diffundo_diff_undonr = undonr

  vim.cmd("enew")
  vim.t.diffundo_diff_bn = vim.api.nvim_get_current_buf()
  vim.t.diffundo_diff_win = vim.api.nvim_get_current_win()
  vim.bo.filetype = filetype
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  diff_window()
  vim.bo.readonly = true
  label.apply(label.name(undonr))

  M.focus(true)
  diff_window()
end

local function leave_stale_diff_window()
  local diff_bn = vim.t.diffundo_diff_bn
  if diff_bn == nil or vim.api.nvim_get_current_buf() ~= diff_bn then
    return
  end

  local source_win = M.window_of_buffer(vim.t.diffundo_source_bn)
  if source_win == nil then
    error("The diffundo source window is no longer open in this tab.", 0)
  end

  vim.api.nvim_set_current_win(source_win)
end

---@return boolean
local function targets_current()
  local buf = vim.api.nvim_get_current_buf()
  return buf == vim.t.diffundo_source_bn
    or buf == vim.t.diffundo_diff_bn
    or vim.api.nvim_get_current_win() == vim.t.diffundo_pane_win
end

---@param win integer
local function diff_off(win)
  vim.api.nvim_win_call(win, function()
    vim.cmd("diffoff")
  end)
end

local function release_diff_window()
  local diff_win = vim.t.diffundo_diff_win
  if diff_win == nil or not vim.api.nvim_win_is_valid(diff_win) then
    return
  end

  if vim.api.nvim_win_get_buf(diff_win) == vim.t.diffundo_diff_bn then
    vim.api.nvim_win_close(diff_win, true)
  else
    diff_off(diff_win)
  end
end

function M.close()
  release_diff_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == vim.t.diffundo_source_bn then
      diff_off(win)
    end
  end
end

---@return boolean
function M.open()
  if M.is_open() and targets_current() then
    return false
  end

  leave_stale_diff_window()
  M.close()

  vim.t.diffundo_source_bn = vim.api.nvim_get_current_buf()
  vim.cmd("vert diffsplit")

  new_buffer()
  return true
end

return M
