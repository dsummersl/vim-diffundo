local diffundo = require("diffundo")

if vim.g.loaded_diffundo then
  return
end
vim.g.loaded_diffundo = true

vim.api.nvim_create_user_command("DiffEarlier", function(opts)
  diffundo.command_earlier(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("DiffLater", function(opts)
  diffundo.command_later(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("DiffSearch", function(opts)
  diffundo.command_search(opts.args)
end, { nargs = 1 })

vim.keymap.set("n", "<Plug>(DiffundoRepeat)", diffundo.repeat_last, { silent = true })
