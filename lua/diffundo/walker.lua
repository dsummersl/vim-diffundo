local lines = require("diffundo.lines")
local tree = require("diffundo.tree")

local M = {}

---@class diffundo.Step
---@field seq integer
---@field parent integer
---@field time integer
---@field save integer|nil
---@field lines string[]
---@field parent_lines string[]
---@field added string[]
---@field removed string[]

---@param seq integer
---@return string[]
local function lines_at(seq)
  vim.cmd("silent undo " .. seq)
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@param state diffundo.State
---@return diffundo.Step
local function step_for(state)
  local parent_lines = lines_at(state.parent)
  local current = lines_at(state.seq)
  return {
    seq = state.seq,
    parent = state.parent,
    time = state.time,
    save = state.save,
    lines = current,
    parent_lines = parent_lines,
    added = lines.added_lines(parent_lines, current),
    removed = lines.removed_lines(parent_lines, current),
  }
end

---@param from_seq integer
---@param floor integer|nil
---@return fun(): diffundo.Step|nil
function M.steps(from_seq, floor)
  local states = tree.states(vim.fn.undotree())
  local lowest = floor or -1
  local index = 0
  return function()
    repeat
      index = index + 1
    until states[index] == nil or states[index].seq < from_seq
    local state = states[index]
    if state == nil or state.seq <= lowest then
      return nil
    end
    return step_for(state)
  end
end

return M
