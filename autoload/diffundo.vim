if exists("s:autoloaded_diffundo")
    finish
endif
let s:autoloaded_diffundo = 1

py3 from diffundo import VimInterface

let s:repeat_function = ""
let s:repeat_argument = ""

" WHY: tpope/vim-repeat replays a <Plug> map, so the last invocation is stored
" for <Plug>(DiffundoRepeat) to replay, and repeat#set() only records a usable
" change tick once the diff is in place.
function! s:SetRepeat(function, argument)
  let s:repeat_function = a:function
  let s:repeat_argument = a:argument

  if exists("*repeat#set")
    call repeat#set("\<Plug>(DiffundoRepeat)")
  endif
endfunction

function! diffundo#Earlier(count="1")
  py3 interface = VimInterface()
  py3 interface.earlier(vim.eval('a:count'))
  call s:SetRepeat("diffundo#Earlier", a:count)
endfunction

function! diffundo#Later(count="1")
  py3 interface = VimInterface()
  py3 interface.later(vim.eval('a:count'))
  call s:SetRepeat("diffundo#Later", a:count)
endfunction

function! diffundo#SearchEarlier(search)
  py3 interface = VimInterface()
  py3 interface.search_earlier(vim.eval('a:search'))
  call s:SetRepeat("diffundo#SearchEarlier", a:search)
endfunction

function! diffundo#RepeatLast()
  if s:repeat_function ==# ""
    return
  endif

  call call(s:repeat_function, [s:repeat_argument])
endfunction
