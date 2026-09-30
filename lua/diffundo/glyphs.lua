local config = require("diffundo.config")

local M = {}

---@class diffundo.Glyphs
---@field buffer string
---@field write string
---@field gap string
---@field ellipsis string

---@type diffundo.Glyphs
M.defaults = config.defaults.glyphs

---@return diffundo.Glyphs
function M.get()
  return config.get().glyphs
end

return M
