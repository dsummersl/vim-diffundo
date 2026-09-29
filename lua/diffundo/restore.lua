local split = require("diffundo.split")

local M = {}

---@param undonr integer
---@param stay boolean
local function settle(undonr, stay)
  if not stay then
    vim.cmd("silent undo " .. undonr)
  end
end

---@param fn fun()
---@param stay boolean
local function in_source(fn, stay)
  local has_split = split.is_open()
  if has_split then
    split.focus(true)
  end
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  local undonr = vim.fn.changenr()

  local ok, err = pcall(fn)

  if has_split then
    split.focus(true)
  end
  settle(undonr, stay)
  vim.cmd("diffupdate")
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, pos)
  end
  if not ok then
    error(err, 0)
  end
end

---@param fn fun()
function M.within_source(fn)
  in_source(fn, false)
end

---@param seq integer
function M.apply(seq)
  in_source(function()
    vim.cmd("silent undo " .. seq)
  end, true)
end

return M
