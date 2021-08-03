command! -nargs=? DiffEarlier call diffundo#Earlier("<args>")
command! -nargs=? DiffLater call diffundo#Later("<args>")

command! -nargs=1 DiffSearch call diffundo#SearchEarlier("<args>")
