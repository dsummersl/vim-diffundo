local M = {}

---@param lines string[]
---@return table<string, integer>
local function counts(lines)
  local result = {}
  for _, line in ipairs(lines) do
    result[line] = (result[line] or 0) + 1
  end
  return result
end

---@param before string[]
---@param after string[]
---@return string[]
function M.added_lines(before, after)
  local remaining = counts(before)
  local added = {}
  for _, line in ipairs(after) do
    if (remaining[line] or 0) > 0 then
      remaining[line] = remaining[line] - 1
    else
      table.insert(added, line)
    end
  end
  return added
end

---@param needle string
---@param before string[]
---@param after string[]
---@return string|nil
function M.first_match(needle, before, after)
  for _, line in ipairs(M.added_lines(before, after)) do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

return M
