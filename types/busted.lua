---@meta busted

---@alias busted.block fun()

---@param name string
---@param block busted.block
function describe(name, block) end

---@param name string
---@param block busted.block
function it(name, block) end

---@param name string
---@param block busted.block
function pending(name, block) end

---@param block busted.block
function before_each(block) end

---@param block busted.block
function after_each(block) end

---@param block busted.block
function setup(block) end

---@param block busted.block
function teardown(block) end

---@class luassert.modifier
---@field are luassert.assertions
---@field is luassert.assertions
---@field are_not luassert.assertions
---@field is_not luassert.assertions
---@field has luassert.assertions
---@field has_no luassert.assertions

---@class luassert.assertions
---@field equal fun(expected: any, actual: any, message?: string)
---@field equals fun(expected: any, actual: any, message?: string)
---@field same fun(expected: any, actual: any, message?: string)
---@field truthy fun(value: any, message?: string)
---@field falsy fun(value: any, message?: string)
---@field error fun(fn: function, message?: string)
---@field errors fun(fn: function, message?: string)
---@field Nil fun(value: any, message?: string)
---@field True fun(value: any, message?: string)
---@field False fun(value: any, message?: string)

---@class luassert : luassert.modifier
---@field is_nil fun(value: any, message?: string)
---@field is_not_nil fun(value: any, message?: string)
---@field is_true fun(value: any, message?: string)
---@field is_false fun(value: any, message?: string)
---@field matches fun(pattern: string, actual: string, message?: string)
---@field has_error fun(fn: function, message?: string)
---@overload fun(value: any, message?: string): any
assert = {}
