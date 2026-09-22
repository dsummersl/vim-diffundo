local M = {}

---@class diffundo.State
---@field seq integer
---@field parent integer
---@field time integer
---@field save integer|nil

---@param entries diffundo.UndoEntry[]
---@param parent integer
---@param states diffundo.State[]
local function collect(entries, parent, states)
  local previous = parent
  for _, entry in ipairs(entries) do
    table.insert(
      states,
      { seq = entry.seq, parent = previous, time = entry.time, save = entry.save }
    )
    if entry.alt then
      collect(entry.alt, previous, states)
    end
    previous = entry.seq
  end
end

---@param undotree vim.undotree
---@return diffundo.State[]
function M.states(undotree)
  local states = {}
  collect(undotree.entries, 0, states)
  table.sort(states, function(a, b)
    return a.seq > b.seq
  end)
  return states
end

return M
