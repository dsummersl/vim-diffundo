local count = require("diffundo.count")
local cursor = require("diffundo.cursor")
local lines = require("diffundo.lines")
local pattern = require("diffundo.pattern")
local restore = require("diffundo.restore")
local sidebar = require("diffundo.sidebar")
local split = require("diffundo.split")
local subcommand = require("diffundo.subcommand")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.SearchOpts
---@field removed boolean|nil

---@generic T
---@param fn fun(): T
---@return T
local function cursor_neutral(fn)
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  local ok, result = pcall(fn)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_cursor, win, pos)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

---@return string[]
local function current_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@param command string
---@param amount string
local function early_late(command, amount)
  restore.within_source(function()
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
  local line, col = lines.first_match(regex, candidates)
  if line and col then
    return hit_for(step, line, col, removed)
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

---@param needle string
---@param opts diffundo.SearchOpts|nil
---@return diffundo.Hit|nil
function M.search(needle, opts)
  return cursor_neutral(function()
    local regex = pattern.compile(needle)
    local was_open = split.is_open()
    if not split.open() then
      return nil
    end
    local from_seq = was_open and vim.t.diffundo_diff_undonr or vim.fn.changenr() + 1
    ---@type diffundo.Hit|nil
    local hit
    restore.within_source(function()
      hit = find(regex, from_seq, opts ~= nil and opts.removed == true)
    end)
    if hit == nil then
      split.place(current_lines(), vim.fn.changenr())
    end
    return hit
  end)
end

---@param sub diffundo.Subcommand
---@return diffundo.Hit|nil
local function dispatch(sub)
  if sub.name == "history" then
    sidebar.toggle()
    return nil
  end
  if sub.name == "earlier" then
    M.earlier(sub.rest)
    return nil
  end
  if sub.name == "later" then
    M.later(sub.rest)
    return nil
  end
  if sub.rest == "" then
    error("search needs a pattern", 0)
  end
  return M.search(sub.rest, { removed = sub.bang })
end

---@param hit diffundo.Hit
local function place_cursor(hit)
  split.focus(true)
  local lnum, col = cursor.locate(current_lines(), hit)
  vim.api.nvim_win_set_cursor(0, { lnum, col })
end

---@param sub diffundo.Subcommand
---@param hit diffundo.Hit|nil
local function finish_search(sub, hit)
  if hit then
    place_cursor(hit)
  elseif split.is_open() then
    local verb = sub.bang and "removes" or "adds"
    vim.notify(("diffundo: no state %s a line matching %s"):format(verb, sub.rest))
  end
end

---@type string|nil
local last_args

---@param args string
local function notify_unknown(args)
  local head = args:match("^%s*(%S*)") or ""
  vim.notify(
    ('diffundo: unknown subcommand "%s" (%s)'):format(head, table.concat(subcommand.names, ", "))
  )
end

---@param hit diffundo.Hit|nil
---@return integer|nil
local function reveal_search(hit)
  if hit == nil then
    return nil
  end
  return hit.seq
end

---@return integer|nil
local function reveal_diff()
  if split.is_open() then
    return vim.t.diffundo_diff_undonr
  end
  return nil
end

---@param sub diffundo.Subcommand
---@param hit diffundo.Hit|nil
---@return integer|nil
local function reveal_from(sub, hit)
  if sub.no_history or vim.g.diffundo_history == false then
    return nil
  end
  if sub.name == "search" then
    return reveal_search(hit)
  end
  if sub.name == "history" then
    return nil
  end
  return reveal_diff()
end

---@param args string
function M.command(args)
  last_args = args
  pcall(vim.fn["repeat#set"], vim.keycode("<Plug>(DiffundoRepeat)"))
  local sub = subcommand.parse(args)
  if sub == nil then
    notify_unknown(args)
    return
  end
  local ok, hit = pcall(dispatch, sub)
  if not ok then
    vim.notify("diffundo: " .. tostring(hit))
    return
  end
  if sub.name == "search" then
    finish_search(sub, hit)
  end
  local seq = reveal_from(sub, hit)
  if seq then
    sidebar.reveal(seq)
  end
end

function M.repeat_last()
  if last_args then
    M.command(last_args)
  end
end

return M
