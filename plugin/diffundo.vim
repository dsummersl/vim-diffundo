command! -nargs=? DiffEarlier call diffundo#Earlier(<args>)
command! -nargs=? DiffLater call diffundo#Later(<args>)
