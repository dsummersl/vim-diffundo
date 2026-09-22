local M = {}

---@param pattern string
---@return string
local function with_case_flag(pattern)
  if not vim.o.ignorecase then
    return "\\C" .. pattern
  end
  if vim.o.smartcase and pattern:find("%u") then
    return "\\C" .. pattern
  end
  return "\\c" .. pattern
end

---@param pattern string
---@return vim.regex
function M.compile(pattern)
  return vim.regex(with_case_flag(pattern))
end

return M
