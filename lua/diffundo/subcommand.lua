local M = {}

---@class diffundo.Subcommand
---@field name string
---@field bang boolean
---@field rest string
---@field no_history boolean

M.names = { "earlier", "later", "search", "search!", "history" }
M.flags = { "-no-history" }

local takes_bang = { earlier = false, later = false, search = true, history = false }

---@param head string
---@param rest string
---@return diffundo.Subcommand|nil
local function finish(head, rest)
  local name, bang = head:match("^(%a+)(!?)$")
  local allowed = name and takes_bang[name]
  if allowed == nil or (bang == "!" and not allowed) then
    return nil
  end
  return { name = name, bang = bang == "!", rest = rest, no_history = false }
end

---@param args string
---@return diffundo.Subcommand|nil
function M.parse(args)
  local head, rest = args:match("^%s*(%S+)%s?(.*)$")
  if head == nil then
    return nil
  end
  if head ~= "-no-history" then
    return finish(head, rest)
  end
  local second, tail = rest:match("^%s*(%S+)%s?(.*)$")
  if second == nil then
    return nil
  end
  local parsed = finish(second, tail)
  if parsed then
    parsed.no_history = true
  end
  return parsed
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local before = cmdline:sub(1, #cmdline - #arglead)
  if not before:match("^%s*%S+%s+$") then
    return {}
  end
  local pool = M.names
  if arglead:sub(1, 1) == "-" then
    pool = M.flags
  end
  local candidates = {}
  for _, candidate in ipairs(pool) do
    if candidate:sub(1, #arglead) == arglead then
      table.insert(candidates, candidate)
    end
  end
  return candidates
end

return M
