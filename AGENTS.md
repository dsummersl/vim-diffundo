# Agent Guidelines

This file provides guidance when working with code in this repository.

## Project Overview

See this project's README.md for an overview of the project, and ADR documents in docs/adr/ for architectural decisions.

This is a neovim plugin: `plugin/diffundo.lua` defines the commands and calls
into the Lua package in `lua/diffundo/`. See docs/adr/0003-lua-port.md before
moving anything.

## Development Commands

**IMPORTANT**: Always use the Makefile commands for development tasks.

### Setup
```bash
make setup  # Install rocks into the local lua_modules/ tree
```

### Testing
```bash
make test                                              # Run all tests with busted and coverage
eval $(luarocks --tree lua_modules path --bin) && busted spec/init_spec.lua   # Run specific test file
eval $(luarocks --tree lua_modules path --bin) && busted --filter "earlier"   # Run tests matching a name
```

Tests never launch neovim. `spec/fakevim.lua` is a fake of the slice of the
`vim` global the plugin uses (windows, buffers, `vim.t`, `vim.bo`/`vim.wo`,
`vim.cmd` and a linear undo history); each spec installs it with
`fake:install()`. Add to the fake when the plugin starts using a new part of
the neovim API, and declare that part in `types/vim.lua` so `make type` knows
about it.

The one exception is `tests/e2e/`, a deno test that drives a real headless
neovim through denops.vim to cover the commands and `plugin/` loading. `make
ci` does not run it -- `make e2e` does, and it needs `deno` and `nvim`.

```bash
make e2e                                               # End-to-end test in a real headless neovim
```

### Code Quality
```bash
make lint        # Check code with selene, stylua, and ast-grep
make fix         # Strip comments (ast-grep) and format (stylua)
make type        # Type check with lua-language-server (strict diagnostics)
make complexity  # Check cyclomatic complexity and function length
make ci          # Run all CI checks (test + lint + type + complexity)
```

**Before completing any feature**, run `make ci` to ensure all checks pass.

## Code Quality Requirements

Writing guidance:

- No comments. Use `---@param`/`---@return`/`---@class` annotations on every public function; no `---` prose lines.
- Modules return a local table `M`; no globals.
- `require` calls at the top of the file only.

## Project Structure

```
plugin/              # :DiffEarlier / :DiffLater / :DiffSearch definitions
lua/diffundo/        # Main package source code
spec/                # busted tests (mirror lua/diffundo/ structure, named *_spec.lua)
tests/e2e/           # deno + denops.vim end-to-end test against a real neovim
types/               # ---@meta stubs for lua-language-server (busted globals, the vim API used)
docs/adr/            # Architecture Decision Records
```
