local M = {}

local spans = {
  { 60 * 60 * 24 * 365, "y" },
  { 60 * 60 * 24 * 30, "mo" },
  { 60 * 60 * 24 * 7, "w" },
  { 60 * 60 * 24, "d" },
  { 60 * 60, "h" },
  { 60, "m" },
}

---@class diffundo.UndoEntry
---@field seq integer
---@field time integer
---@field save integer|nil
---@field alt diffundo.UndoEntry[]|nil

---@param entries diffundo.UndoEntry[]
---@param seq integer
---@return diffundo.UndoEntry|nil
function M.find_entry(entries, seq)
  for _, entry in ipairs(entries) do
    if entry.seq == seq then
      return entry
    end
    local nested = entry.alt and M.find_entry(entry.alt, seq)
    if nested then
      return nested
    end
  end
  return nil
end

---@param undonr integer
---@return string
function M.for_undonr(undonr)
  if undonr == 0 then
    return "{original} - 0"
  end

  local entry = M.find_entry(vim.fn.undotree().entries, undonr)
  if entry == nil then
    return "{unknown} - " .. undonr
  end

  return os.date("%Y-%m-%d %I:%M:%S %p", entry.time) .. " - " .. entry.seq
end

---@param time integer
---@return string
function M.relative(time)
  local delta = os.time() - time
  if delta < 60 then
    return "just now"
  end
  for _, span in ipairs(spans) do
    local count = math.floor(delta / span[1])
    if count >= 1 then
      return string.format("%d%s ago", count, span[2])
    end
  end
  return "just now"
end

---@param label string
function M.apply(label)
  vim.api.nvim_buf_set_name(0, label)
  vim.wo.statusline = label
  vim.wo.winbar = label
end

return M
