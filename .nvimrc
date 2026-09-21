" lua << EOF
" require('lazy-loader')()
" EOF

let g:gutentags_ctags_exclude += ['*/lua_modules/*']
let g:projectionist_heuristics = {
      \ 'lua/&spec/': {
      \   'lua/diffundo/*.lua': {
      \     'type': 'function',
      \     'alternate': [
      \       'spec/{dirname}{basename}_spec.lua',
      \       'spec/{dirname}/{basename}_spec.lua',
      \     ]
      \   },
      \   'spec/**/*_spec.lua': {
      \     'type': 'test',
      \     'alternate': [
      \       'lua/diffundo/{dirname}{basename}.lua',
      \       'lua/diffundo/{dirname}/{basename}.lua',
      \     ]
      \   },
      \ },
      \ }
