local M = {}

---@param count string|nil
---@return string
function M.normalize(count)
  local trimmed = (count or ""):match("^%s*(.-)%s*$")
  if trimmed == "" then
    return "1"
  end

  if not trimmed:match("^%d+[smhdf]?$") then
    error(
      "invalid count: " .. trimmed .. " (expected a number, optionally followed by s, m, h, d or f)",
      0
    )
  end

  return trimmed
end

return M
