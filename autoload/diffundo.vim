if exists("b:autoloaded_diffundo")
    finish
endif
let b:autoloaded_diffundo = 1

" Also import vim as we expect it to be imported in many places.
py3 from diffundo import VimInterface

function! diffundo#OpenDiff(count="1f")
  py3 interface = VimInterface(vim.eval('a:count'))
  py3 interface.vert_diffs()
endfunction
