local M = {}

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

---@param label string
function M.apply(label)
  vim.api.nvim_buf_set_name(0, label)
  vim.wo.statusline = label
  vim.wo.winbar = label
end

return M
