local M = {}

---@class diffundo.GlyphsOpts
---@field buffer? string
---@field write? string
---@field gap? string
---@field ellipsis? string

---@class diffundo.Keys
---@field pane table<string, fun(api: diffundo.Api)>

---@class diffundo.KeysOpts
---@field pane? table<string, false|""|fun(api: diffundo.Api)>

---@class diffundo.Opts
---@field history? boolean
---@field glyphs? diffundo.GlyphsOpts
---@field date_format? string|fun(time: integer): string
---@field history_width? integer
---@field fold_min? integer
---@field keys? diffundo.KeysOpts

---@class diffundo.Config
---@field history boolean
---@field glyphs diffundo.Glyphs
---@field date_format string|fun(time: integer): string
---@field history_width integer
---@field fold_min integer
---@field keys diffundo.Keys

---@type diffundo.Config
M.defaults = {
  history = true,
  glyphs = { buffer = "@", write = "w", gap = "┆", ellipsis = "…" },
  date_format = "%Y-%m-%d %H:%M:%S",
  history_width = 40,
  fold_min = 3,
  keys = {
    pane = {
      J = function(api)
        api.move_save(1)
      end,
      K = function(api)
        api.move_save(-1)
      end,
      ["<cr>"] = function(api)
        api.place()
      end,
      ["<c-cr>"] = function(api)
        api.apply()
      end,
      q = function(api)
        api.collapse(true)
      end,
      ["<esc>"] = function(api)
        api.collapse(true)
      end,
    },
  },
}

---@type diffundo.Config
local state

---@generic T
---@param base T
---@param over T|nil
---@return T
local function merge(base, over)
  local merged = {}
  for key, value in pairs(base) do
    merged[key] = value
  end
  for key, value in pairs(over or {}) do
    merged[key] = value
  end
  return merged
end

---@param base table<string, false|""|fun(api: diffundo.Api)>
---@param over table<string, false|""|fun(api: diffundo.Api)>|nil
---@return table<string, fun(api: diffundo.Api)>
local function merge_keys(base, over)
  local merged = merge(base, over)
  for key, value in pairs(merged) do
    if value == false or value == "" then
      merged[key] = nil
    end
  end
  ---@type table<string, fun(api: diffundo.Api)>
  return merged
end

---@param value unknown
---@param fallback unknown
---@return unknown
local function pick(value, fallback)
  if value == nil then
    return fallback
  end
  return value
end

---@param opts diffundo.Opts|nil
---@return diffundo.Config
local function build(opts)
  local over = opts or {}
  local defaults = M.defaults
  ---@type diffundo.Glyphs
  local glyphs = merge(defaults.glyphs, over.glyphs)
  ---@type diffundo.Config
  local result = {
    history = pick(over.history, defaults.history),
    glyphs = glyphs,
    date_format = pick(over.date_format, defaults.date_format),
    history_width = pick(over.history_width, defaults.history_width),
    fold_min = pick(over.fold_min, defaults.fold_min),
    keys = { pane = merge_keys(defaults.keys.pane, over.keys and over.keys.pane) },
  }
  return result
end

---@param opts diffundo.Opts|nil
function M.setup(opts)
  state = build(opts)
end

---@return diffundo.Config
function M.get()
  return state
end

M.setup(nil)

return M
