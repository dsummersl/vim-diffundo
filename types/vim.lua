---@meta vim

---@class vim.undotree
---@field seq_last integer
---@field seq_cur integer
---@field save_last integer|nil
---@field entries diffundo.UndoEntry[]

---@class vim.fn
---@field changenr fun(): integer
---@field undotree fun(buf?: integer): vim.undotree
---@field winline fun(): integer
---@field input fun(prompt: any): string
---@field [string] fun(...): any

---@class vim.api
---@field nvim_tabpage_list_wins fun(tabpage: integer): integer[]
---@field nvim_win_get_buf fun(window: integer): integer
---@field nvim_win_call fun(window: integer, fn: fun(): any): any
---@field nvim_win_get_height fun(window: integer): integer
---@field nvim_win_get_width fun(window: integer): integer
---@field nvim_buf_get_changedtick fun(buffer: integer): integer
---@field nvim_create_augroup fun(name: string, opts: table): integer
---@field nvim_del_augroup_by_id fun(id: integer)
---@field nvim_create_autocmd fun(events: string|string[], opts: table): integer
---@field nvim_set_hl fun(ns_id: integer, name: string, opts: table)
---@field nvim_set_current_win fun(window: integer)
---@field nvim_get_current_win fun(): integer
---@field nvim_win_is_valid fun(window: integer): boolean
---@field nvim_win_get_cursor fun(window: integer): [integer, integer]
---@field nvim_win_set_cursor fun(window: integer, pos: integer[])
---@field nvim_get_current_buf fun(): integer
---@field nvim_buf_is_valid fun(buffer: integer): boolean
---@field nvim_buf_get_lines fun(buffer: integer, start: integer, stop: integer, strict: boolean): string[]
---@field nvim_buf_set_lines fun(buffer: integer, start: integer, stop: integer, strict: boolean, lines: string[])
---@field nvim_buf_set_name fun(buffer: integer, name: string)
---@field nvim_create_buf fun(scratch: boolean, listed: boolean): integer
---@field nvim_open_win fun(buffer: integer, enter: boolean, config: table): integer
---@field nvim_win_close fun(window: integer, force: boolean)
---@field nvim_win_set_config fun(window: integer, config: table)
---@field nvim_win_get_config fun(window: integer): table
---@field nvim_buf_set_keymap fun(buffer: integer, mode: string, lhs: string, rhs: string, opts: table)
---@field nvim_buf_delete fun(buffer: integer, opts: table)
---@field nvim_create_user_command fun(name: string, command: fun(opts: { args: string }), opts: table)
---@field nvim_create_namespace fun(name: string): integer
---@field nvim_buf_add_highlight fun(buffer: integer, ns_id: integer, hl_group: string, line: integer, col_start: integer, col_end: integer)
---@field nvim_buf_clear_namespace fun(buffer: integer, ns_id: integer, line_start: integer, line_end: integer)
---@field nvim_buf_call fun(buffer: integer, fn: fun())

---@class vim.bo
---@field filetype string
---@field buftype string
---@field bufhidden string
---@field swapfile boolean
---@field readonly boolean
---@field modifiable boolean

---@class vim.wo
---@field diff boolean
---@field scrollbind boolean
---@field cursorbind boolean
---@field foldmethod string
---@field foldlevel integer
---@field foldtext string
---@field foldcolumn string
---@field signcolumn string
---@field number boolean
---@field relativenumber boolean
---@field spell boolean
---@field wrap boolean
---@field cursorline boolean
---@field statusline string
---@field winbar string

---@class vim.log
---@field levels { ERROR: integer, INFO: integer }

---@class vim.o
---@field ignorecase boolean
---@field smartcase boolean
---@field lines integer
---@field columns integer
---@field winbar string

---@class vim.keymap
---@field set fun(mode: string, lhs: string, rhs: string|fun(), opts: table)

---@class vim.regex
---@field match_str fun(self: vim.regex, str: string): integer|nil, integer|nil

---@class vim
---@field fn vim.fn
---@field api vim.api
---@field bo vim.bo
---@field wo vim.wo
---@field o vim.o
---@field t table<string, any>
---@field g table<string, any>
---@field log vim.log
---@field keymap vim.keymap
---@field cmd fun(command: string)
---@field schedule fun(callback: fun())
---@field notify fun(message: string, level?: integer)
---@field keycode fun(keys: string): string
---@field regex fun(pattern: string): vim.regex
vim = {}
