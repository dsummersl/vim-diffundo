local M = {}

---@class diffundo.Mark
---@field hl string
---@field from integer
---@field to integer

---@param a string
---@param b string
---@return integer
local function common_prefix(a, b)
  local limit = math.min(#a, #b)
  local p = 0
  while p < limit and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  return p
end

---@param a string
---@param b string
---@param p integer
---@return integer
local function common_suffix(a, b, p)
  local limit = math.min(#a, #b) - p
  local s = 0
  while s < limit and a:byte(#a - s) == b:byte(#b - s) do
    s = s + 1
  end
  return s
end

---@param s string
---@param i integer
---@return boolean
local function word_at(s, i)
  return s:sub(i, i):find("%S") ~= nil
end

---@param old string
---@param new string
---@param p integer
---@return integer
local function snap_prefix(old, new, p)
  while p > 0 and word_at(old, p) and (word_at(old, p + 1) or word_at(new, p + 1)) do
    p = p - 1
  end
  return p
end

---@param old string
---@param new string
---@param s integer
---@return integer
local function snap_suffix(old, new, s)
  while
    s > 0
    and word_at(old, #old - s + 1)
    and (word_at(old, #old - s) or word_at(new, #new - s))
  do
    s = s - 1
  end
  return s
end

---@param before string
---@param ellipsis string
---@return string
local function lead_for(before, ellipsis)
  local context = before:match("(%S+%s*)$") or ""
  if before:sub(1, #before - #context):find("%S") then
    return ellipsis .. context
  end
  return context
end

---@param after string
---@param ellipsis string
---@return string
local function trail_for(after, ellipsis)
  local context = after:match("^%s*%S+") or ""
  if after:sub(#context + 1):find("%S") then
    return context .. ellipsis
  end
  return context
end

---@param old string
---@param new string
---@param p integer
---@param s integer
---@return string, string
local function changed_for(old, new, p, s)
  local added = new:sub(p + 1, #new - s)
  if added ~= "" then
    return added, "DiffText"
  end
  return old:sub(p + 1, #old - s), "DiffDelete"
end

---@param old string
---@param new string
---@param ellipsis string
---@return string, diffundo.Mark[]
function M.changed(old, new, ellipsis)
  local p = snap_prefix(old, new, common_prefix(old, new))
  local s = snap_suffix(old, new, common_suffix(old, new, p))
  local lead = lead_for(old:sub(1, p), ellipsis)
  local trail = trail_for(old:sub(#old - s + 1), ellipsis)
  local changed, hl = changed_for(old, new, p, s)
  local stop = #lead + #changed
  return lead .. changed .. trail,
    {
      { hl = "DiffChange", from = 0, to = #lead },
      { hl = hl, from = #lead, to = stop },
      { hl = "DiffChange", from = stop, to = stop + #trail },
    }
end

return M
