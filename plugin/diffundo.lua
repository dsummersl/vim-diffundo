local diffundo = require("diffundo")
local subcommand = require("diffundo.subcommand")

if vim.g.loaded_diffundo then
  return
end
vim.g.loaded_diffundo = true

vim.api.nvim_create_user_command("Diffundo", function(opts)
  diffundo.command(opts.args)
end, { nargs = "*", complete = subcommand.complete })

vim.keymap.set("n", "<Plug>(DiffundoRepeat)", diffundo.repeat_last, { silent = true })
