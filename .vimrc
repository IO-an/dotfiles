let mapleader = " "

" ===== Менеджер плагинов vim-plug =====
call plug#begin('~/.vim/plugged')

" LSP и автодополнение
Plug 'neoclide/coc.nvim', {'branch': 'release'}

call plug#end()

set langmap=ФИСВУАПРШОЛДЬТЩЗЙКЫЕГМЦЧНЯ;ABCDEFGHIJKLMNOPQRSTUVWXYZ,фисвуапршолдьтщзйкыегмцчня;abcdefghijklmnopqrstuvwxyz

" ===== Основные настройки =====
" set guifont=FantasqueSansM\ Nerd\ Font\ Mono\ 12
set guifont=JetBrainsMono\ Nerd\ Font\ Mono\ 10

set guioptions+=m
set guioptions-=T

set tabstop=2                " Display existing tabs as 2 spaces
set shiftwidth=2             " Indentation amount for >> and <<
set softtabstop=2            " How many spaces a tab counts for when editing
set expandtab

set hidden                   " скрытые буферы (нужно для LSP)
set updatetime=300           " быстрый отклик на изменения
set shortmess+=c             " не показывать лишние сообщения
set signcolumn=yes           " всегда показывать колонку знаков
set mouse=a

set number
syntax on
set termguicolors
colorscheme minimal-light

filetype plugin indent on

set path+=**

set directory=$HOME/.vim/swap//

" ============================================================
" Coc diagnostics and Git signs
" Automatically adapts to the current colorscheme
" ============================================================

function! s:ApplyCocColors() abort
    " --------------------------------------------------------
    " Light theme: dark, high-contrast colors
    " --------------------------------------------------------
    if &background ==# 'light'

        " Diagnostic signs
        highlight CocErrorSign
                    \ guifg=#C62828 guibg=NONE
                    \ ctermfg=124 ctermbg=NONE
                    \ gui=bold cterm=bold

        highlight CocWarningSign
                    \ guifg=#8A6100 guibg=NONE
                    \ ctermfg=130 ctermbg=NONE
                    \ gui=bold cterm=bold

        highlight CocInfoSign
                    \ guifg=#006D8F guibg=NONE
                    \ ctermfg=24 ctermbg=NONE
                    \ gui=bold cterm=bold

        highlight CocHintSign
                    \ guifg=#237A3B guibg=NONE
                    \ ctermfg=28 ctermbg=NONE
                    \ gui=bold cterm=bold

        " Diagnostic virtual text
        highlight CocErrorVirtualText
                    \ guifg=#C62828 guibg=NONE
                    \ ctermfg=124 ctermbg=NONE

        highlight CocWarningVirtualText
                    \ guifg=#8A6100 guibg=NONE
                    \ ctermfg=130 ctermbg=NONE

        highlight CocInfoVirtualText
                    \ guifg=#006D8F guibg=NONE
                    \ ctermfg=24 ctermbg=NONE

        highlight CocHintVirtualText
                    \ guifg=#237A3B guibg=NONE
                    \ ctermfg=28 ctermbg=NONE

        " Git signs
        highlight CocGitAddedSign
                    \ guifg=#237A3B guibg=NONE
                    \ ctermfg=28 ctermbg=NONE

        highlight CocGitChangedSign
                    \ guifg=#8A6100 guibg=NONE
                    \ ctermfg=130 ctermbg=NONE

        highlight CocGitRemovedSign
                    \ guifg=#C62828 guibg=NONE
                    \ ctermfg=124 ctermbg=NONE

        highlight CocGitTopRemovedSign
                    \ guifg=#C62828 guibg=NONE
                    \ ctermfg=124 ctermbg=NONE

    " --------------------------------------------------------
    " Dark theme: light, readable colors
    " --------------------------------------------------------
    else

        " Diagnostic signs
        highlight CocErrorSign
                    \ guifg=#FF6B81 guibg=NONE
                    \ ctermfg=210 ctermbg=NONE
                    \ gui=bold cterm=bold

        highlight CocWarningSign
                    \ guifg=#FFD166 guibg=NONE
                    \ ctermfg=221 ctermbg=NONE
                    \ gui=bold cterm=bold

        highlight CocInfoSign
                    \ guifg=#70D6FF guibg=NONE
                    \ ctermfg=117 ctermbg=NONE
                    \ gui=bold cterm=bold

        highlight CocHintSign
                    \ guifg=#8CE99A guibg=NONE
                    \ ctermfg=151 ctermbg=NONE
                    \ gui=bold cterm=bold

        " Diagnostic virtual text
        highlight CocErrorVirtualText
                    \ guifg=#FF6B81 guibg=NONE
                    \ ctermfg=210 ctermbg=NONE

        highlight CocWarningVirtualText
                    \ guifg=#FFD166 guibg=NONE
                    \ ctermfg=221 ctermbg=NONE

        highlight CocInfoVirtualText
                    \ guifg=#70D6FF guibg=NONE
                    \ ctermfg=117 ctermbg=NONE

        highlight CocHintVirtualText
                    \ guifg=#8CE99A guibg=NONE
                    \ ctermfg=151 ctermbg=NONE

        " Git signs
        highlight CocGitAddedSign
                    \ guifg=#8CE99A guibg=NONE
                    \ ctermfg=151 ctermbg=NONE

        highlight CocGitChangedSign
                    \ guifg=#FFD166 guibg=NONE
                    \ ctermfg=221 ctermbg=NONE

        highlight CocGitRemovedSign
                    \ guifg=#FF6B81 guibg=NONE
                    \ ctermfg=210 ctermbg=NONE

        highlight CocGitTopRemovedSign
                    \ guifg=#FF6B81 guibg=NONE
                    \ ctermfg=210 ctermbg=NONE

    endif
endfunction


" Reapply colors after every colorscheme change.
augroup CocAdaptiveColors
    autocmd!
    autocmd ColorScheme * call <SID>ApplyCocColors()
augroup END

" Apply colors immediately.
call <SID>ApplyCocColors()

" ===== Базовые клавиши coc.nvim =====

nmap <silent> gd <Plug>(coc-definition)
nmap <silent> gD :call CocAction('jumpDefinition', 'vsplit')<CR>
nmap <silent> gy <Plug>(coc-type-definition)
nmap <silent> gi <Plug>(coc-implementation)
nmap <silent> gr <Plug>(coc-references)

" Показать документацию
nnoremap <silent> K :call CocActionAsync('doHover')<CR>

" Переименование
nmap <leader>rn <Plug>(coc-rename)

" Форматирование выделенного фрагмента
xmap <leader>af <Plug>(coc-format-selected)
nmap <leader>af <Plug>(coc-format-selected)

" Применение автофикса (ESLint --fix)
nmap <leader>qf <Plug>(coc-codeaction)

" ============================================================
" Cross-platform system theme detection
" Supported: Windows, Ubuntu, macOS
" ============================================================

" ------------------------------------------------------------
" Detect operating system
" Returns: windows | ubuntu | macos | linux | unknown
" ------------------------------------------------------------

function! DetectSystemOS() abort
    " Windows
    if has('win32') || has('win64') || has('win32unix')
        return 'windows'
    endif

    " macOS
    if has('macunix') || has('mac')
        return 'macos'
    endif

    " Linux / Ubuntu
    if has('unix')
        if filereadable('/etc/os-release')
            for l:line in readfile('/etc/os-release')
                if l:line =~? '^ID=.*ubuntu'
                    return 'ubuntu'
                endif

                if l:line =~? '^ID_LIKE=.*ubuntu'
                    return 'ubuntu'
                endif
            endfor
        endif

        return 'linux'
    endif

    return 'unknown'
endfunction

" ------------------------------------------------------------
" Detect system color scheme
" Argument: operating system
" Returns: light | dark
" ------------------------------------------------------------

function! DetectSystemColorScheme(os) abort
    " Windows
    if a:os ==# 'windows'
        " AppsUseLightTheme:
        " 0 = dark, 1 = light
        "
        " SystemUsesLightTheme is used as a fallback.

        for l:value_name in [
            \ 'AppsUseLightTheme',
            \ 'SystemUsesLightTheme'
            \ ]

            let l:result = system(
                \ 'reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v '
                \ . l:value_name
                \ . ' 2>NUL'
                \ )

            if l:result =~? '0x0\s*$'
                return 'dark'
            endif

            if l:result =~? '0x1\s*$'
                return 'light'
            endif
        endfor

        return 'light'
    endif


    " macOS
    if a:os ==# 'macos'
        let l:result = system(
            \ 'defaults read -g AppleInterfaceStyle 2>/dev/null'
            \ )

        if v:shell_error == 0 && l:result =~? 'dark'
            return 'dark'
        endif

        " On macOS, absence of AppleInterfaceStyle means light mode.
        return 'light'
    endif


    " Ubuntu / GNOME
    if a:os ==# 'ubuntu' && executable('gsettings')
        " Prefer the explicit color scheme preference.
        let l:result = system(
            \ 'gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null'
            \ )

        let l:status = v:shell_error

        if l:status == 0
            if l:result =~? 'prefer-dark'
                return 'dark'
            endif

            if l:result =~? 'prefer-light'
                return 'light'
            endif
        endif

        " Fallback for older GNOME / Ubuntu configurations.
        let l:result = system(
            \ 'gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null'
            \ )

        if v:shell_error == 0 && l:result =~? 'dark'
            return 'dark'
        endif

        return 'light'
    endif

    " Other Linux distributions or unsupported environments.
    return 'light'
endfunction

" ------------------------------------------------------------
" Detect OS, determine system theme and apply it to Vim
" ------------------------------------------------------------

function! DetectAndApplyTheme(...) abort
    let g:system_os = DetectSystemOS()
    let g:system_theme = DetectSystemColorScheme(g:system_os)

    let l:colorscheme = g:system_theme ==# 'dark'
        \ ? 'minimal-dark'
        \ : 'minimal-light'

    " Reload only if the selected scheme has changed.
    if get(g:, 'colors_name', '') !=# l:colorscheme
        execute 'colorscheme ' . l:colorscheme
    endif
endfunction

" ============================================================
" Automatic theme synchronization
" ============================================================

augroup SystemTheme
    autocmd!
    autocmd VimEnter * call DetectAndApplyTheme()
augroup END

" Check for system theme changes every 5 seconds.
if exists('*timer_start')
    if exists('g:system_theme_timer')
        call timer_stop(g:system_theme_timer)
    endif

    let g:system_theme_timer = timer_start(
        \ 5000,
        \ function('DetectAndApplyTheme'),
        \ {'repeat': -1}
        \ )
endif

" Apply the theme immediately.
call DetectAndApplyTheme()

autocmd BufNewFile,BufRead *.ts  set filetype=javascript
autocmd BufNewFile,BufRead *.jsx set filetype=javascriptreact
autocmd BufNewFile,BufRead *.ts  set filetype=typescript
autocmd BufNewFile,BufRead *.tsx set filetype=typescriptreact

" ===== Автоматическая установка расширений coc =====
let g:coc_global_extensions = [
      \ 'coc-tsserver',
      \ 'coc-eslint',
      \ 'coc-prettier',
      \ 'coc-git',
      \ 'coc-json',
      \ 'coc-html',
      \ 'coc-css',
      \ ]
