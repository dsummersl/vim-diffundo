local diffundo = require("diffundo")

if vim.g.loaded_diffundo then
  return
end
vim.g.loaded_diffundo = true

vim.api.nvim_create_user_command("Diffundo", function(opts)
  diffundo.command(opts.args)
end, { nargs = "*" })

vim.keymap.set("n", "<Plug>(DiffundoRepeat)", diffundo.repeat_last, { silent = true })
