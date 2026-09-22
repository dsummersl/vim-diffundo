local count = require("diffundo.count")
local lines = require("diffundo.lines")
local split = require("diffundo.split")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.SearchOpts
---@field removed boolean|nil

---@generic T
---@param fn fun(): T
---@return T
local function cursor_neutral(fn)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok, result = pcall(fn)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

---@param fn fun()
local function within_source(fn)
  split.focus(true)
  local undonr = vim.fn.changenr()

  local ok, err = pcall(fn)

  split.focus(true)
  vim.cmd("silent undo " .. undonr)
  vim.cmd("diffupdate")
  if not ok then
    error(err, 0)
  end
end

---@return string[]
local function current_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@param command string
---@param amount string
local function early_late(command, amount)
  within_source(function()
    vim.cmd("silent undo " .. vim.t.diffundo_diff_undonr)
    vim.cmd("silent " .. command .. " " .. amount)
    split.place(current_lines(), vim.fn.changenr())
  end)
end

---@param step diffundo.Step
---@param line string
---@param col integer
---@param removed boolean
---@return diffundo.Hit
local function hit_for(step, line, col, removed)
  local had = removed and step.parent_lines or step.lines
  return {
    seq = step.seq,
    time = step.time,
    save = step.save,
    line = line,
    col = col,
    lnum = lines.index_of(had, line) or 1,
  }
end

---@param regex vim.regex
---@param step diffundo.Step
---@param removed boolean
---@return diffundo.Hit|nil
local function match_in(regex, step, removed)
  local candidates = removed and step.removed or step.added
  for _, line in ipairs(candidates) do
    local col = regex:match_str(line)
    if col then
      return hit_for(step, line, col, removed)
    end
  end
  return nil
end

---@param regex vim.regex
---@param from_seq integer
---@param removed boolean
---@return diffundo.Hit|nil
local function find(regex, from_seq, removed)
  for step in walker.steps(from_seq) do
    local hit = match_in(regex, step, removed)
    if hit then
      split.place(step.lines, step.seq)
      return hit
    end
  end
  return nil
end

---@param amount string|nil
function M.earlier(amount)
  cursor_neutral(function()
    local normalized = count.normalize(amount)
    if split.open() then
      early_late("earlier", normalized)
    end
    return nil
  end)
end

---@param amount string|nil
function M.later(amount)
  cursor_neutral(function()
    local normalized = count.normalize(amount)
    if split.open() then
      early_late("later", normalized)
    end
    return nil
  end)
end

---@param pattern string
---@param opts diffundo.SearchOpts|nil
---@return diffundo.Hit|nil
function M.search(pattern, opts)
  return cursor_neutral(function()
    local regex = vim.regex(pattern)
    local was_open = split.is_open()
    if not split.open() then
      return nil
    end
    local from_seq = was_open and vim.t.diffundo_diff_undonr or vim.fn.changenr() + 1
    ---@type diffundo.Hit|nil
    local hit
    within_source(function()
      hit = find(regex, from_seq, opts ~= nil and opts.removed == true)
    end)
    if hit == nil then
      split.place(current_lines(), vim.fn.changenr())
    end
    return hit
  end)
end

---@param args string
function M.command(args)
  vim.notify("diffundo: " .. args)
end

function M.repeat_last() end

return M
