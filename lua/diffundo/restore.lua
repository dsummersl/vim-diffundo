local split = require("diffundo.split")

local M = {}

---@param fn fun()
function M.within_source(fn)
  local has_split = split.is_open()
  if has_split then
    split.focus(true)
  end
  local undonr = vim.fn.changenr()

  local ok, err = pcall(fn)

  if has_split then
    split.focus(true)
  end
  vim.cmd("silent undo " .. undonr)
  vim.cmd("diffupdate")
  if not ok then
    error(err, 0)
  end
end

return M
