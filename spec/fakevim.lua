local M = {}

---@param lines string[]
---@return string[]
local function copy(lines)
  local result = {}
  for index, line in ipairs(lines) do
    result[index] = line
  end
  return result
end

local History = {}
History.__index = History

---@param states string[][]
---@param times integer[]|nil
function M.history(states, times)
  local self = setmetatable({}, History)
  self.states = {}
  self.times = {}
  for index, lines in ipairs(states) do
    self.states[index] = copy(lines)
    self.times[index] = times and times[index] or 1627784659 + (index - 1) * 60
  end
  self.seq = #states - 1
  return self
end

---@return string[]
function History:lines()
  return self.states[self.seq + 1]
end

---@param seq integer
function History:undo(seq)
  self.seq = math.max(0, math.min(seq, #self.states - 1))
end

---@param count integer
function History:earlier(count)
  self:undo(self.seq - count)
end

---@param count integer
function History:later(count)
  self:undo(self.seq + count)
end

function History:undotree()
  local entries = {}
  for index = 2, #self.states do
    table.insert(entries, { seq = index - 1, time = self.times[index] })
  end
  return { seq_last = #self.states - 1, seq_cur = self.seq, entries = entries }
end

local Fake = {}
Fake.__index = Fake

---@param self table
---@return table
local function current_buffer(self)
  return self.buffers[self.windows[self.current_win].buf]
end

---@param self table
---@param bufnr integer|nil
---@return integer|nil
local function window_of_buffer(self, bufnr)
  for _, win in ipairs(self.win_order) do
    if self.windows[win].buf == bufnr then
      return win
    end
  end
  return nil
end

---@param self table
---@param lines string[]|nil
---@param name string|nil
---@return integer
local function new_buffer(self, lines, name)
  local bufnr = self.next_bufnr
  self.next_bufnr = bufnr + 1
  self.buffers[bufnr] =
    { number = bufnr, lines = copy(lines or {}), name = name or "", options = {} }
  return bufnr
end

---@param self table
local function sync_source(self)
  self.buffers[self.source_bn].lines = copy(self.history:lines())
end

---@param self table
---@return table
local function commands(self)
  return {
    undo = function(rest)
      self.history:undo(tonumber(rest))
      sync_source(self)
    end,
    earlier = function(rest)
      local count = (rest == "" and "1" or rest):match("^(%d+)[smhdf]?$")
      if count == nil then
        error("Vim(earlier):E475: Invalid argument: " .. rest, 0)
      end
      self.history:earlier(tonumber(count))
      sync_source(self)
    end,
    later = function(rest)
      local count = (rest == "" and "1" or rest):match("^(%d+)[smhdf]?$")
      if count == nil then
        error("Vim(later):E475: Invalid argument: " .. rest, 0)
      end
      self.history:later(tonumber(count))
      sync_source(self)
    end,
    diffupdate = function() end,
    enew = function()
      self.windows[self.current_win].buf = new_buffer(self)
    end,
    vert = function(rest)
      if rest ~= "diffsplit" then
        error("unsupported command: vert " .. rest, 0)
      end
      local win = self.next_win
      self.next_win = win + 1
      self.windows[win] = { buf = self.windows[self.current_win].buf, options = {} }
      table.insert(self.win_order, 1, win)
      self.current_win = win
    end,
  }
end

---@param self table
---@param command string
local function run_command(self, command)
  table.insert(self.commands, command)
  local stripped = command:gsub("^silent ", "")
  local head, rest = stripped:match("^(%S+)%s*(.*)$")
  local handler = commands(self)[head]
  if handler == nil then
    error("unsupported command: " .. command, 0)
  end
  handler(rest)
end

---@param self table
---@return table
local function api(self)
  return {
    nvim_tabpage_list_wins = function()
      return copy(self.win_order)
    end,
    nvim_win_get_buf = function(win)
      return self.windows[win].buf
    end,
    nvim_set_current_win = function(win)
      self.current_win = win
    end,
    nvim_get_current_buf = function()
      return current_buffer(self).number
    end,
    nvim_buf_is_valid = function(bufnr)
      return self.buffers[bufnr] ~= nil
    end,
    nvim_buf_get_lines = function()
      return copy(current_buffer(self).lines)
    end,
    nvim_buf_set_lines = function(_, _, _, _, lines)
      current_buffer(self).lines = copy(lines)
    end,
    nvim_buf_set_name = function(_, name)
      current_buffer(self).name = name
    end,
  }
end

---@param self table
---@return table
local function fn(self)
  return {
    changenr = function()
      return self.history.seq
    end,
    undotree = function()
      return self.history:undotree()
    end,
    escape = function(text)
      return text
    end,
    search = function(pattern)
      table.insert(self.searches, pattern)
      return 1
    end,
  }
end

---@param get fun(): table
---@return table
local function option_proxy(get)
  return setmetatable({}, {
    __index = function(_, name)
      return get()[name]
    end,
    __newindex = function(_, name, value)
      get()[name] = value
    end,
  })
end

---@param history table
---@param opts { filetype?: string, name?: string }|nil
---@return table
function M.new(history, opts)
  local options = opts or {}
  local self = setmetatable({}, Fake)
  self.history = history
  self.buffers = {}
  self.windows = {}
  self.win_order = {}
  self.next_bufnr = 1
  self.next_win = 1000
  self.notifications = {}
  self.commands = {}
  self.searches = {}
  self.t = {}
  self.log = { levels = { ERROR = 4, INFO = 2 } }

  self.source_bn = new_buffer(self, history:lines(), options.name or "source.lua")
  self.buffers[self.source_bn].options.filetype = options.filetype or "lua"
  local win = self.next_win
  self.next_win = win + 1
  self.windows[win] = { buf = self.source_bn, options = {} }
  self.win_order = { win }
  self.current_win = win

  self.api = api(self)
  self.fn = fn(self)
  self.bo = option_proxy(function()
    return current_buffer(self).options
  end)
  self.wo = option_proxy(function()
    return self.windows[self.current_win].options
  end)
  self.cmd = function(command)
    run_command(self, command)
  end
  self.notify = function(message)
    table.insert(self.notifications, message)
  end
  self.keycode = function(keys)
    return keys
  end
  return self
end

---@return table
function Fake:source_buffer()
  return self.buffers[self.source_bn]
end

---@return table
function Fake:diff_buffer()
  return self.buffers[self.t.diffundo_diff_bn]
end

---@return table
function Fake:diff_window()
  return self.windows[window_of_buffer(self, self.t.diffundo_diff_bn)]
end

---@return table
function Fake:current_buffer()
  return current_buffer(self)
end

---@param bufnr integer
---@return integer|nil
function Fake:window_of_buffer(bufnr)
  return window_of_buffer(self, bufnr)
end

---@param win integer
function Fake:close_window(win)
  for index, candidate in ipairs(self.win_order) do
    if candidate == win then
      table.remove(self.win_order, index)
    end
  end
  local closed = self.windows[win]
  self.windows[win] = nil
  if self.current_win == win then
    self.current_win = self.win_order[1]
  end
  if self.buffers[closed.buf].options.bufhidden == "wipe" then
    self.buffers[closed.buf] = nil
  end
end

-- selene: allow(global_usage)
function Fake:install()
  _G.vim = self
end

---@return string
function Fake:last_notification()
  return self.notifications[#self.notifications] or ""
end

return M
