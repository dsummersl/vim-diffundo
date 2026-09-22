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
  self.entries = {}
  for index, lines in ipairs(states) do
    local seq = index - 1
    self.entries[seq] = {
      lines = copy(lines),
      parent = math.max(0, seq - 1),
      time = times and times[index] or 1627784659 + seq * 60,
    }
  end
  self.seq_last = #states - 1
  self.seq = self.seq_last
  return self
end

---@param parent integer
---@param lines string[]
---@param opts { time?: integer, save?: integer }|nil
---@return integer
function History:branch(parent, lines, opts)
  local options = opts or {}
  local seq = self.seq_last + 1
  self.entries[seq] = {
    lines = copy(lines),
    parent = parent,
    time = options.time or (1627784659 + seq * 60),
    save = options.save,
  }
  self.seq_last = seq
  self.seq = seq
  return seq
end

---@return string[]
function History:lines()
  return self.entries[self.seq].lines
end

---@param seq integer
function History:undo(seq)
  self.seq = math.max(0, math.min(seq, self.seq_last))
end

---@param count integer
function History:earlier(count)
  self:undo(self.seq - count)
end

---@param count integer
function History:later(count)
  self:undo(self.seq + count)
end

---@param self table
---@param parent integer
---@return integer[]
local function children(self, parent)
  local result = {}
  for seq = self.seq_last, 1, -1 do
    if self.entries[seq].parent == parent then
      table.insert(result, seq)
    end
  end
  return result
end

---@param list integer[]
---@return integer[]
local function tail(list)
  local result = {}
  for index = 2, #list do
    result[index - 1] = list[index]
  end
  return result
end

---@param self table
---@param seq integer
---@param siblings integer[]
---@return table[]
local function chain(self, seq, siblings)
  local entry = self.entries[seq]
  local head = { seq = seq, time = entry.time, save = entry.save }
  if siblings[1] then
    head.alt = chain(self, siblings[1], tail(siblings))
  end
  local list = { head }
  local kids = children(self, seq)
  if kids[1] then
    for _, item in ipairs(chain(self, kids[1], tail(kids))) do
      table.insert(list, item)
    end
  end
  return list
end

function History:undotree()
  local kids = children(self, 0)
  local entries = kids[1] and chain(self, kids[1], tail(kids)) or {}
  return { seq_last = self.seq_last, seq_cur = self.seq, entries = entries }
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
      self.windows[win] =
        { buf = self.windows[self.current_win].buf, options = {}, cursor = { 1, 0 } }
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
---@param win integer
---@return table
local function window(self, win)
  local resolved = win == 0 and self.current_win or win
  local found = self.windows[resolved]
  if found == nil then
    error("Invalid window id: " .. tostring(win), 0)
  end
  return found
end

---@param self table
---@return table
local function api(self)
  return {
    nvim_get_current_win = function()
      return self.current_win
    end,
    nvim_win_is_valid = function(win)
      return self.windows[win] ~= nil
    end,
    nvim_win_get_cursor = function(win)
      return copy(window(self, win).cursor)
    end,
    nvim_win_set_cursor = function(win, pos)
      window(self, win).cursor = { pos[1], pos[2] }
    end,
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
  self.windows[win] = { buf = self.source_bn, options = {}, cursor = { 1, 0 } }
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
  self.regex = function(pattern)
    local literal = pattern:gsub("^\\V", "")
    return {
      match_str = function(_, line)
        local start, stop = line:find(literal, 1, true)
        if start == nil then
          return nil
        end
        return start - 1, stop
      end,
    }
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
