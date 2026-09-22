local lines = require("diffundo.lines")

local M = {}

---@class diffundo.Hit
---@field seq integer
---@field time integer
---@field save integer|nil
---@field line string
---@field col integer
---@field lnum integer

---@param source string[]
---@param hit diffundo.Hit
---@return integer, integer
function M.locate(source, hit)
  local index = lines.index_of(source, hit.line)
  if index then
    return index, hit.col
  end
  return math.max(1, math.min(hit.lnum, #source)), 0
end

return M
