if exists("b:autoloaded_diffundo")
    finish
endif
let b:autoloaded_diffundo = 1

py3 from diffundo import VimInterface

function! diffundo#Earlier(count="1")
  py3 interface = VimInterface()
  py3 interface.earlier(vim.eval('a:count'))
endfunction

function! diffundo#Later(count="1")
  py3 interface = VimInterface()
  py3 interface.later(vim.eval('a:count'))
endfunction
