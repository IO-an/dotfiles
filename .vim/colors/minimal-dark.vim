" Minimal Dark
highlight clear

if exists('syntax_on')
    syntax reset
endif

let g:colors_name = 'minimal-dark'
set background=dark

" Основной текст
highlight Normal       guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight NormalNC     guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight NonText      guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight EndOfBuffer  guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight Whitespace   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight SpecialKey   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Выделение: чёрный текст на белом фоне
highlight Visual       guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight VisualNOS    guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Комментарии: зелёные, как в VS Code
highlight Comment       guifg=#6A9955 guibg=#000000 ctermfg=Green ctermbg=Black
highlight SpecialComment guifg=#6A9955 guibg=#000000 ctermfg=Green ctermbg=Black
highlight! link Todo Comment

" Поиск
highlight Search       guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight IncSearch    guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight CurSearch    guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Курсор и текущая строка
highlight CursorLine   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight CursorColumn guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight Cursor       guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Номера строк
highlight LineNr       guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight CursorLineNr guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black

" Интерфейс
highlight StatusLine   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight StatusLineNC guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight VertSplit    guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight WinSeparator guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight TabLine      guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight TabLineFill  guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight TabLineSel   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Popup-меню
highlight Pmenu        guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight PmenuSel     guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White
highlight PmenuSbar    guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight PmenuThumb   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Остальные элементы интерфейса
highlight Directory    guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight Folded       guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight FoldColumn   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight SignColumn   guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight ColorColumn  guifg=#FFFFFF guibg=#000000 ctermfg=White ctermbg=Black
highlight MatchParen   guifg=#000000 guibg=#FFFFFF ctermfg=Black ctermbg=White

" Подсветка синтаксиса: всё белое, кроме комментариев
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
