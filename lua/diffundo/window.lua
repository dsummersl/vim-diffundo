local M = {}

---@param opts { lines: string[], title: string, width: integer }
---@return integer
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = opts.width,
    height = math.max(1, math.min(#opts.lines, vim.o.lines - 4)),
  })
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.wo.winbar = opts.title
  M.render(win, opts.lines)
  return win
end

---@param win integer
---@param lines string[]
function M.render(win, lines)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, lines)
  vim.api.nvim_win_set_config(win, {
    height = math.max(1, math.min(#lines, vim.o.lines - 4)),
  })
end

---@param win integer
---@param lhs string
---@param fn fun()
function M.map(win, lhs, fn)
  vim.api.nvim_buf_set_keymap(vim.api.nvim_win_get_buf(win), "n", lhs, "", {
    callback = fn,
    silent = true,
  })
end

---@param win integer
function M.close(win)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_close(win, true)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

---@param win integer|nil
---@return boolean
function M.is_open(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

return M
