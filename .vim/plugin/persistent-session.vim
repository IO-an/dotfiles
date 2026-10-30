" ============================================================
" Persistent Session
" Global session storage for Vim and Neovim
" ============================================================

if exists('g:loaded_persistent_session')
    finish
endif

let g:loaded_persistent_session = 1

" ------------------------------------------------------------
" Configuration
" ------------------------------------------------------------

let s:session_dir = expand('~/.vim/sessions')

let s:session_file = s:session_dir . '/current.vim'

" Restore buffers, tabs, folds and window layout.
" Do not save the current working directory or override
" the user's global options and mappings.
set sessionoptions=blank,buffers,folds,help,tabpages,winsize

if !exists('g:session_autosave_enabled')
    let g:session_autosave_enabled = 1
endif

" ------------------------------------------------------------
" Save
" ------------------------------------------------------------

function! SessionSave() abort
    if !exists(':mksession')
        echoerr 'PersistentSession: mksession is unavailable'
        return
    endif

    if !isdirectory(s:session_dir)
        call mkdir(s:session_dir, 'p')
    endif

    execute 'mksession! ' . fnameescape(s:session_file)

    let g:session_autosave_enabled = 1

    echo 'Session saved: ' . s:session_file
endfunction

" ------------------------------------------------------------
" Restore
" ------------------------------------------------------------

function! SessionRestore() abort
    if !filereadable(s:session_file)
        echo 'PersistentSession: no saved session'
        return
    endif

    execute 'source ' . fnameescape(s:session_file)

    echo 'Session restored: ' . s:session_file
endfunction

" ------------------------------------------------------------
" Clear
" ------------------------------------------------------------

function! SessionClear() abort
    if filereadable(s:session_file)
        if delete(s:session_file) != 0
            echoerr 'PersistentSession: failed to delete session'
            return
        endif
    endif

    " Do not recreate the deleted session when this Vim exits.
    let g:session_autosave_enabled = 0

    echo 'PersistentSession: saved session cleared'
endfunction

" ------------------------------------------------------------
" Information
" ------------------------------------------------------------

function! SessionInfo() abort
    echo 'Session file: ' . s:session_file
    echo 'Exists: ' . (filereadable(s:session_file) ? 'yes' : 'no')
    echo 'Autosave: ' . (g:session_autosave_enabled ? 'on' : 'off')
endfunction

" ------------------------------------------------------------
" Commands
" ------------------------------------------------------------

command! SessionSave    call SessionSave()
command! SessionRestore call SessionRestore()
command! SessionClear   call SessionClear()
command! SessionInfo    call SessionInfo()

" ------------------------------------------------------------
" Automatic restoration
" ------------------------------------------------------------

augroup PersistentSession
    autocmd!

    autocmd VimEnter * call s:RestoreOnStartup()
    autocmd VimLeavePre * call s:SaveOnExit()
augroup END

function! s:RestoreOnStartup() abort
    " Do not override files or sessions explicitly supplied
    " through command-line arguments.
    if argc() != 0
        return
    endif

    " Do not override a session loaded with Vim's -S option.
    if !empty(v:this_session)
        return
    endif

    if filereadable(s:session_file)
        execute 'source ' . fnameescape(s:session_file)
    endif
endfunction

function! s:SaveOnExit() abort
    if !g:session_autosave_enabled
        return
    endif

    if !isdirectory(s:session_dir)
        call mkdir(s:session_dir, 'p')
    endif

    execute 'silent! mksession! ' . fnameescape(s:session_file)
endfunction
