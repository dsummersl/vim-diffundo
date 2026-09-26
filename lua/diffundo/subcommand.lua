local M = {}

---@class diffundo.Subcommand
---@field name string
---@field bang boolean
---@field rest string

M.names = { "earlier", "later", "undo", "search", "search!", "focus", "close" }

local takes_bang =
  { earlier = false, later = false, undo = false, search = true, focus = false, close = false }

---@param head string
---@param rest string
---@return diffundo.Subcommand|nil
local function finish(head, rest)
  local name, bang = head:match("^(%a+)(!?)$")
  local allowed = name and takes_bang[name]
  if allowed == nil or (bang == "!" and not allowed) then
    return nil
  end
  return { name = name, bang = bang == "!", rest = rest }
end

---@param args string
---@return diffundo.Subcommand|nil
function M.parse(args)
  local head, rest = args:match("^%s*(%S+)%s?(.*)$")
  if head == nil then
    return nil
  end
  return finish(head, rest)
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local before = cmdline:sub(1, #cmdline - #arglead)
  if not before:match("^%s*%S+%s+$") then
    return {}
  end
  local candidates = {}
  for _, candidate in ipairs(M.names) do
    if candidate:sub(1, #arglead) == arglead then
      table.insert(candidates, candidate)
    end
  end
  return candidates
end

return M
