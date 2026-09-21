rockspec_format = "3.0"
package = "vim-diffundo"
version = "dev-1"

source = {
  url = "git+https://github.com/dsummersl/vim-diffundo.git",
}

description = {
  summary = "Diff the current buffer against its own undo history.",
  license = "Apache-2.0",
  maintainer = "Dane Summers <dsummersl@gmail.com>",
}

dependencies = {
  "lua >= 5.1",
}

test_dependencies = {
  "busted >= 2.2.0",
  "luacov >= 0.15.0",
}

test = {
  type = "busted",
}

build = {
  type = "builtin",
  modules = {
    ["diffundo"] = "lua/diffundo/init.lua",
    ["diffundo.additions"] = "lua/diffundo/additions.lua",
    ["diffundo.count"] = "lua/diffundo/count.lua",
    ["diffundo.label"] = "lua/diffundo/label.lua",
    ["diffundo.split"] = "lua/diffundo/split.lua",
  },
  copy_directories = { "plugin" },
}
