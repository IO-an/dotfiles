" Minimal Light
highlight clear

if exists('syntax_on')
    syntax reset
endif

let g:colors_name = 'minimal-light'
set background=light

" Основной текст
highlight Normal       guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight NormalNC     guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight NonText      guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight EndOfBuffer  guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight Whitespace   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight SpecialKey   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Выделение: белый текст на чёрном фоне
highlight Visual       guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight VisualNOS    guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Комментарии: зелёные, как в VS Code
highlight Comment      guifg=#008000 guibg=#FFFFFF ctermfg=Green ctermbg=White
highlight SpecialComment guifg=#008000 guibg=#FFFFFF ctermfg=Green ctermbg=White
highlight! link Todo Comment

" Поиск
highlight Search       guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight IncSearch    guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight CurSearch    guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Курсор и текущая строка
highlight CursorLine   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight CursorColumn guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight Cursor       guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Номера строк
highlight LineNr       guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight CursorLineNr guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Интерфейс
highlight StatusLine   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight StatusLineNC guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight VertSplit    guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight WinSeparator guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight TabLine      guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight TabLineFill  guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight TabLineSel   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Popup-меню
highlight Pmenu        guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight PmenuSel     guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight PmenuSbar    guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight PmenuThumb   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Остальные элементы интерфейса
highlight Directory    guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight Folded       guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight FoldColumn   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight SignColumn   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight ColorColumn  guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight MatchParen   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Подсветка синтаксиса: всё чёрное, кроме комментариев
highlight! link Constant      Normal
highlight! link String        Normal
highlight! link Character     Normal
highlight! link Number        Normal
highlight! link Boolean       Normal
highlight! link Float         Normal
highlight! link Identifier    Normal
highlight! link Function      Normal
highlight! link Statement     Normal
highlight! link Conditional   Normal
highlight! link Repeat        Normal
highlight! link Label         Normal
highlight! link Operator      Normal
highlight! link Keyword       Normal
highlight! link Exception     Normal
highlight! link PreProc       Normal
highlight! link Include       Normal
highlight! link Define        Normal
highlight! link Macro         Normal
highlight! link PreCondit     Normal
highlight! link Type          Normal
highlight! link StorageClass  Normal
highlight! link Structure     Normal
highlight! link Typedef       Normal
highlight! link Special       Normal
highlight! link SpecialChar   Normal
highlight! link Tag           Normal
highlight! link Delimiter     Normal
highlight! link Debug         Normal
highlight! link Underlined    Normal
highlight! link Ignore        Normal
highlight! link Error         Normal
