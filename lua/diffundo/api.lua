---@class diffundo.Api
---@field earlier fun(amount: string|nil)
---@field later fun(amount: string|nil)
---@field undo fun(seq: string)
---@field search fun(needle: string, opts?: diffundo.SearchOpts): diffundo.Hit|nil
---@field focus fun()
---@field close fun()
---@field move_save fun(dir: integer)
---@field place fun()
---@field apply fun()
---@field collapse fun(back: boolean)

---@diagnostic disable:missing-fields
---@type diffundo.Api
local M = {}

return M
