---@meta vim

---@class vim.undotree
---@field seq_last integer
---@field seq_cur integer
---@field entries diffundo.UndoEntry[]

---@class vim.fn
---@field changenr fun(): integer
---@field undotree fun(): vim.undotree
---@field escape fun(text: string, chars: string): string
---@field search fun(pattern: string): integer
---@field [string] fun(...): any

---@class vim.api
---@field nvim_tabpage_list_wins fun(tabpage: integer): integer[]
---@field nvim_win_get_buf fun(window: integer): integer
---@field nvim_set_current_win fun(window: integer)
---@field nvim_get_current_win fun(): integer
---@field nvim_win_is_valid fun(window: integer): boolean
---@field nvim_win_get_cursor fun(window: integer): integer[]
---@field nvim_win_set_cursor fun(window: integer, pos: integer[])
---@field nvim_get_current_buf fun(): integer
---@field nvim_buf_is_valid fun(buffer: integer): boolean
---@field nvim_buf_get_lines fun(buffer: integer, start: integer, stop: integer, strict: boolean): string[]
---@field nvim_buf_set_lines fun(buffer: integer, start: integer, stop: integer, strict: boolean, lines: string[])
---@field nvim_buf_set_name fun(buffer: integer, name: string)
---@field nvim_create_user_command fun(name: string, command: fun(opts: { args: string }), opts: table)

---@class vim.bo
---@field filetype string
---@field buftype string
---@field bufhidden string
---@field swapfile boolean
---@field readonly boolean

---@class vim.wo
---@field diff boolean
---@field scrollbind boolean
---@field cursorbind boolean
---@field foldmethod string
---@field statusline string
---@field winbar string

---@class vim.log
---@field levels { ERROR: integer, INFO: integer }

---@class vim.keymap
---@field set fun(mode: string, lhs: string, rhs: string|fun(), opts: table)

---@class vim.regex
---@field match_str fun(self: vim.regex, str: string): integer|nil, integer|nil

---@class vim
---@field fn vim.fn
---@field api vim.api
---@field bo vim.bo
---@field wo vim.wo
---@field t table<string, any>
---@field g table<string, any>
---@field log vim.log
---@field keymap vim.keymap
---@field cmd fun(command: string)
---@field notify fun(message: string, level?: integer)
---@field keycode fun(keys: string): string
---@field regex fun(pattern: string): vim.regex
vim = {}
