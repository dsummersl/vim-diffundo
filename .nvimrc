" lua << EOF
" require('lazy-loader')()
" EOF

let g:gutentags_ctags_exclude += ['*/.venv/*']
let g:projectionist_heuristics = {
      \ 'pyproject.toml': {
      \   'pythonx/diffundo/*.py': {
      \     'type': 'function',
      \     'alternate': 'tests/diffundo/test_{basename}.py'
      \   },
      \   'tests/diffundo/test_*.py': {
      \     'type': 'test',
      \     'alternate': 'pythonx/diffundo/{basename}.py'
      \   },
      \ },
      \ }
