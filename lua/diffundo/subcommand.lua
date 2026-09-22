local M = {}

---@class diffundo.Subcommand
---@field name string
---@field bang boolean
---@field rest string

M.names = { "earlier", "later", "search", "search!" }

local takes_bang = { earlier = false, later = false, search = true }

---@param args string
---@return diffundo.Subcommand|nil
function M.parse(args)
  local head, rest = args:match("^%s*(%S+)%s?(.*)$")
  if head == nil then
    return nil
  end
  local name, bang = head:match("^(%a+)(!?)$")
  if takes_bang[name] == nil then
    return nil
  end
  if bang == "!" and not takes_bang[name] then
    return nil
  end
  return { name = name, bang = bang == "!", rest = rest }
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local before = cmdline:sub(1, #cmdline - #arglead)
  if not before:match("^%s*%S+%s+$") then
    return {}
  end
  local result = {}
  for _, name in ipairs(M.names) do
    if name:sub(1, #arglead) == arglead then
      table.insert(result, name)
    end
  end
  return result
end

return M
