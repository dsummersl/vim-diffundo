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

---@param pool string[]
---@param candidates string[]
---@return string[]
local function not_in(pool, candidates)
  local remaining = counts(pool)
  local result = {}
  for _, line in ipairs(candidates) do
    if (remaining[line] or 0) > 0 then
      remaining[line] = remaining[line] - 1
    else
      table.insert(result, line)
    end
  end
  return result
end

---@param before string[]
---@param after string[]
---@return string[]
function M.added_lines(before, after)
  return not_in(before, after)
end

---@param before string[]
---@param after string[]
---@return string[]
function M.removed_lines(before, after)
  return not_in(after, before)
end

---@param lines string[]
---@param line string
---@return integer|nil
function M.index_of(lines, line)
  for index, candidate in ipairs(lines) do
    if candidate == line then
      return index
    end
  end
  return nil
end

---@param regex vim.regex
---@param candidates string[]
---@return string|nil, integer|nil
function M.first_match(regex, candidates)
  for _, line in ipairs(candidates) do
    local col = regex:match_str(line)
    if col then
      return line, col
    end
  end
  return nil
end

return M
