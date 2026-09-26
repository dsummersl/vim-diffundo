local M = {}

---@class diffundo.CacheSlot
---@field lines table<integer, string[]>
---@field counts table<integer, integer[]>
---@field tick integer|nil
---@field rows diffundo.Row[]|nil
---@field rows_key string|nil

---@type table<integer, diffundo.CacheSlot>
local store = {}

---@param bufnr integer
---@return diffundo.CacheSlot
local function slot(bufnr)
  local found = store[bufnr]
  if found == nil then
    found = { lines = {}, counts = {} }
    store[bufnr] = found
  end
  return found
end

---@param bufnr integer
---@param seq integer
---@param lines string[]
function M.remember(bufnr, seq, lines)
  slot(bufnr).lines[seq] = lines
end

---@param bufnr integer
---@param seq integer
---@return string[]|nil
function M.lines(bufnr, seq)
  return slot(bufnr).lines[seq]
end

---@param bufnr integer
---@param seq integer
---@param tick integer
---@param compute fun(): integer, integer
---@return integer, integer
function M.counts(bufnr, seq, tick, compute)
  local found = slot(bufnr)
  if found.tick ~= tick then
    found.counts = {}
    found.tick = tick
  end
  local hit = found.counts[seq]
  if hit == nil then
    local added, removed = compute()
    hit = { added, removed }
    found.counts[seq] = hit
  end
  return hit[1], hit[2]
end

---@param bufnr integer
---@return diffundo.Row[]|nil, string|nil
function M.rows(bufnr)
  local found = slot(bufnr)
  return found.rows, found.rows_key
end

---@param bufnr integer
---@param key string
---@param rows diffundo.Row[]
function M.store_rows(bufnr, key, rows)
  local found = slot(bufnr)
  found.rows = rows
  found.rows_key = key
end

---@param bufnr integer
function M.reset(bufnr)
  store[bufnr] = nil
end

return M
