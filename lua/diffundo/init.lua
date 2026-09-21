local additions = require("diffundo.additions")
local count = require("diffundo.count")
local split = require("diffundo.split")

local M = {}

---@param fn fun()
local function reporting_errors(fn)
  local ok, err = pcall(fn)
  if not ok then
    vim.notify("diffundo: " .. tostring(err))
  end
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

---@param needle string
local function search_earlier(needle)
  within_source(function()
    local next_undonr = vim.t.diffundo_diff_undonr
    vim.cmd("silent undo " .. next_undonr)
    local next_lines = current_lines()

    while next_undonr > 0 do
      vim.cmd("silent earlier")
      local before_lines = current_lines()
      local before_undonr = vim.fn.changenr()
      local found = additions.first_match(needle, before_lines, next_lines)

      if found then
        split.place(next_lines, next_undonr)
        vim.t.diffundo_diff_undonr = before_undonr
        vim.fn.search("\\V" .. vim.fn.escape(found, "\\"))
        return
      end

      next_lines = before_lines
      next_undonr = before_undonr
    end

    vim.notify("No match found")
  end)
end

---@param amount string|nil
function M.earlier(amount)
  reporting_errors(function()
    local normalized = count.normalize(amount)
    if split.open() then
      early_late("earlier", normalized)
    end
  end)
end

---@param amount string|nil
function M.later(amount)
  reporting_errors(function()
    local normalized = count.normalize(amount)
    if split.open() then
      early_late("later", normalized)
    end
  end)
end

---@param needle string
function M.search_earlier(needle)
  reporting_errors(function()
    if split.open() then
      search_earlier(needle)
    end
  end)
end

---@type { command: fun(arg: string), arg: string }|nil
local last

---@param command fun(arg: string)
---@param arg string
local function remember(command, arg)
  last = { command = command, arg = arg }
  pcall(vim.fn["repeat#set"], vim.keycode("<Plug>(DiffundoRepeat)"))
end

function M.repeat_last()
  if last then
    last.command(last.arg)
  end
end

---@param arg string
function M.command_earlier(arg)
  M.earlier(arg)
  remember(M.command_earlier, arg)
end

---@param arg string
function M.command_later(arg)
  M.later(arg)
  remember(M.command_later, arg)
end

---@param arg string
function M.command_search(arg)
  M.search_earlier(arg)
  remember(M.command_search, arg)
end

return M
