local M = {}

---@class diffundo.Glyphs
---@field buffer string
---@field diff string
---@field write string
---@field gap string
---@field ellipsis string

---@type diffundo.Glyphs
M.defaults = { buffer = "@", diff = "○", write = "w", gap = "┆", ellipsis = "…" }

---@return diffundo.Glyphs
function M.get()
  ---@type diffundo.Glyphs
  local merged = { buffer = "", diff = "", write = "", gap = "", ellipsis = "" }
  for key, value in pairs(M.defaults) do
    merged[key] = value
  end
  for key, value in pairs(vim.g.diffundo_glyphs or {}) do
    merged[key] = value
  end
  return merged
end

return M
