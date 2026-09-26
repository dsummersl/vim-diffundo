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
function M.name(undonr)
  return ("diffundo://%d/#%d"):format(vim.t.diffundo_source_bn or 0, undonr)
end

---@param time integer
---@return string
function M.date(time)
  local format = vim.g.diffundo_date_format or "%Y-%m-%d %H:%M:%S"
  if type(format) == "function" then
    return format(time)
  end
  return tostring(os.date(format, time))
end

---@param seq integer
---@param time integer
---@return string
function M.title(seq, time)
  if seq == 0 then
    return "#0"
  end
  return "#" .. seq .. "  " .. M.date(time)
end

---@param name string
function M.apply(name)
  pcall(vim.api.nvim_buf_set_name, 0, name)
end

return M
