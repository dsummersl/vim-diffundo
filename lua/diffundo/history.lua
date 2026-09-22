local label = require("diffundo.label")
local lines = require("diffundo.lines")
local restore = require("diffundo.restore")
local walker = require("diffundo.walker")

local M = {}

---@class diffundo.Row
---@field seq integer
---@field time integer
---@field save integer|nil
---@field added string[]
---@field removed string[]
---@field label string

local older = {
  seq = 0,
  time = 0,
  save = nil,
  added = {},
  removed = {},
  label = "",
}

---@param text string
---@param width integer
---@return string
local function truncate(text, width)
  if #text <= width then
    return text
  end
  return text:sub(1, width)
end

---@param row diffundo.Row
---@return string
local function preview_for(row)
  if #row.added == 1 and #row.removed == 0 then
    return "+ " .. row.added[1]
  end
  if #row.added == 0 and #row.removed == 1 then
    return "- " .. row.removed[1]
  end
  return ("~ %d added, %d removed"):format(#row.added, #row.removed)
end

---@param step diffundo.Step
---@return diffundo.Row
function M.row_for(step)
  return {
    seq = step.seq,
    time = step.time,
    save = step.save,
    added = step.added,
    removed = step.removed,
    label = label.for_undonr(step.seq),
  }
end

---@param opts { limit?: integer }
---@return diffundo.Row[]
function M.rows(opts)
  local limit = opts.limit or 500
  local collected = {}
  restore.within_source(function()
    local count = 0
    for step in walker.steps(vim.fn.undotree().seq_last + 1) do
      if count < limit then
        table.insert(collected, M.row_for(step))
        count = count + 1
      elseif count == limit then
        table.insert(collected, older)
        count = count + 1
      end
    end
  end)
  return collected
end

---@param row diffundo.Row
---@param width integer
---@return string
function M.render(row, width)
  if row.seq == 0 then
    return truncate("…older…", width)
  end
  local marker = row.save and " [saved]" or ""
  return truncate(row.label .. marker .. "  " .. preview_for(row), width)
end

---@param options { written?: boolean }
---@param row diffundo.Row
---@return boolean
local function should_skip(options, row)
  return options.written == true and row.save == nil
end

---@param candidate integer
---@param last integer
---@return boolean
local function inside_bounds(candidate, last)
  return candidate >= 1 and candidate <= last
end

---@param rows diffundo.Row[]
---@param index integer
---@param opts { dir?: integer, written?: boolean }|nil
---@return integer
function M.next(rows, index, opts)
  local options = opts or {}
  local dir = options.dir or 1
  local candidate = index + dir
  local last = #rows
  while inside_bounds(candidate, last) do
    if should_skip(options, rows[candidate]) then
      candidate = candidate + dir
    else
      return candidate
    end
  end
  return index
end

---@param row diffundo.Row
---@param removed boolean
---@return string[]
local function pool_for(row, removed)
  if removed then
    return row.removed
  end
  return row.added
end

---@param rows diffundo.Row[]
---@param regex vim.regex
---@param opts { removed?: boolean }|nil
---@return diffundo.Row[]
function M.filtered(rows, regex, opts)
  local removed = opts ~= nil and opts.removed == true
  local result = {}
  for _, row in ipairs(rows) do
    if lines.first_match(regex, pool_for(row, removed)) then
      table.insert(result, row)
    end
  end
  return result
end

return M
