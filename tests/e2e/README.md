End-to-end tests
================

`tests/diffundo/` covers the python half against a fake `vim` module. These
tests cover the other half: vimscript, `pythonx/` loading and the real undo
tree, by driving a real editor with
[denops.vim](https://github.com/vim-denops/denops.vim).

[`@denops/test`](https://jsr.io/@denops/test) starts a headless editor with
denops loaded and hands the deno test a `denops` object that evaluates
expressions and runs commands inside it. denops is only the remote control here
-- this plugin has no deno half.

Running them
------------

    make e2e

`make e2e` clones the pinned denops.vim into `.cache/denops.vim` (gitignored)
and runs `deno test -A` in this directory. It needs:

- `deno` (`brew install deno`)
- `nvim` 0.11.3+ on `PATH`, or `DENOPS_TEST_NVIM_EXECUTABLE` pointing at one
- `pynvim` for the python3 nvim provider (`pip install pynvim`), since the
  plugin runs `py3 from diffundo import VimInterface`

`make ci` does not run these -- it stays a pure python gate.

Neovim only, for now
--------------------

`mode: "nvim"` rather than `"all"`: denops needs Vim 9.1.1646 or newer, and the
Vim it drives also needs `+python3`, which the distro and CI vim builds do not
reliably have together. Adding `mode: "all"` once a suitable Vim is available in
CI is the obvious next step.
