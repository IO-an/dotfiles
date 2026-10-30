" Cross-platform OS theme observer for Vim and Neovim.
" Install this file under <config-root>/plugin/ and helpers under
" <config-root>/system-theme-observers/.

if exists('g:loaded_system_theme_observer')
    finish
endif
let g:loaded_system_theme_observer = 1

let s:config_root = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:observer_dir = s:config_root . '/system-theme-observers'
let s:observer_job = 0
let s:observer_running = 0
let s:observer_os = 'unknown'
let s:stopping = 0

function! s:DetectOS() abort
    if has('win32') || has('win64') || has('win32unix')
        return 'windows'
    endif

    if has('macunix') || has('mac')
        return 'macos'
    endif

    if has('unix')
        if filereadable('/etc/os-release')
            for l:line in readfile('/etc/os-release')
                if l:line =~? '^ID="\?ubuntu"\?\s*$'
                    return 'ubuntu'
                endif
                if l:line =~? '^ID_LIKE=.*\<ubuntu\>'
                    return 'ubuntu'
                endif
            endfor
        endif
        return 'linux'
    endif

    return 'unknown'
endfunction

function! s:DetectColorScheme(os) abort
    if a:os ==# 'windows'
        let l:key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

        for l:name in ['AppsUseLightTheme', 'SystemUsesLightTheme']
            let l:result = system('reg query "' . l:key . '" /v ' . l:name . ' 2>NUL')
            let l:status = v:shell_error

            if l:status == 0 && l:result =~? 'REG_DWORD\s\+0x0\s*$'
                return 'dark'
            endif
            if l:status == 0 && l:result =~? 'REG_DWORD\s\+0x1\s*$'
                return 'light'
            endif
        endfor

        return 'light'
    endif

    if a:os ==# 'macos'
        let l:result = system('defaults read -g AppleInterfaceStyle 2>/dev/null')
        if v:shell_error == 0 && l:result =~? 'dark'
            return 'dark'
        endif
        return 'light'
    endif

    if (a:os ==# 'ubuntu' || a:os ==# 'linux') && executable('gsettings')
        let l:result = system('gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null')
        let l:status = v:shell_error

        if l:status == 0
            if l:result =~? 'prefer-dark'
                return 'dark'
            endif
            if l:result =~? 'prefer-light'
                return 'light'
            endif
        endif

        " Older GNOME setups expose the selected variant through gtk-theme.
        let l:result = system('gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null')
        if v:shell_error == 0 && l:result =~? 'dark'
            return 'dark'
        endif
    endif

    return 'light'
endfunction

function! s:ApplyTheme() abort
    let s:observer_os = s:DetectOS()
    let l:scheme = s:DetectColorScheme(s:observer_os)
    let g:system_theme_os = s:observer_os
    let g:system_theme = l:scheme

    let l:colorscheme = l:scheme ==# 'dark' ? 'minimal-dark' : 'minimal-light'
    if get(g:, 'colors_name', '') !=# l:colorscheme
        try
            execute 'silent colorscheme ' . l:colorscheme
        catch /^Vim\%((\a\+)\)\=:E185/
            let g:system_theme_observer_error = 'Missing colorscheme: ' . l:colorscheme
        endtry
    endif
endfunction

function! s:OnVimOutput(channel, message) abort
    if !empty(a:message)
        call s:ApplyTheme()
    endif
endfunction

function! s:OnNvimOutput(jobid, data, event) abort
    for l:line in a:data
        if !empty(l:line)
            call s:ApplyTheme()
            return
        endif
    endfor
endfunction

function! s:RestartObserver(timer_id) abort
    if !s:stopping
        call s:StartObserver()
    endif
endfunction

function! s:OnVimExit(job, status) abort
    let s:observer_job = 0
    let s:observer_running = 0
    if !s:stopping && exists('*timer_start')
        call timer_start(2000, function('s:RestartObserver'))
    endif
endfunction

function! s:OnNvimExit(jobid, exitcode, event) abort
    let s:observer_job = 0
    let s:observer_running = 0
    if !s:stopping && exists('*timer_start')
        call timer_start(2000, function('s:RestartObserver'))
    endif
endfunction

function! s:GetObserverCommand() abort
    if s:observer_os ==# 'ubuntu' || s:observer_os ==# 'linux'
        let l:path = s:observer_dir . '/ubuntu-theme-observer.sh'
        if executable('gsettings') && filereadable(l:path)
            return ['/bin/sh', l:path]
        endif
        return []
    endif

    if s:observer_os ==# 'windows'
        let l:path = s:observer_dir . '/windows-theme-observer.ps1'
        if filereadable(l:path) && executable('powershell.exe')
            return ['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', l:path]
        endif
        return []
    endif

    if s:observer_os ==# 'macos'
        let l:path = s:observer_dir . '/macos-theme-observer'
        if filereadable(l:path) && executable(l:path)
            return [l:path]
        endif
        return []
    endif

    return []
endfunction

function! s:StartObserver() abort
    if s:observer_running
        if has('nvim') && exists('*jobwait')
            if jobwait([s:observer_job], 0)[0] == -1
                return
            endif
        elseif exists('*job_status') && job_status(s:observer_job) ==# 'run'
            return
        endif
        let s:observer_running = 0
        let s:observer_job = 0
    endif

    let s:observer_os = s:DetectOS()
    let l:cmd = s:GetObserverCommand()
    if empty(l:cmd)
        let g:system_theme_observer_status = 'unavailable'
        return
    endif

    let s:stopping = 0
    if has('nvim') && exists('*jobstart')
        let s:observer_job = jobstart(l:cmd, {
            \ 'on_stdout': function('s:OnNvimOutput'),
            \ 'on_exit': function('s:OnNvimExit'),
            \ 'stdout_buffered': v:false
            \ })
        if s:observer_job > 0
            let s:observer_running = 1
            let g:system_theme_observer_status = 'running'
        else
            let s:observer_job = 0
            let s:observer_running = 0
            let g:system_theme_observer_status = 'failed'
        endif
    elseif exists('*job_start')
        let s:observer_job = job_start(l:cmd, {
            \ 'out_cb': function('s:OnVimOutput'),
            \ 'exit_cb': function('s:OnVimExit'),
            \ 'out_mode': 'nl'
            \ })
        if job_status(s:observer_job) ==# 'run'
            let s:observer_running = 1
            let g:system_theme_observer_status = 'running'
        else
            let s:observer_job = 0
            let s:observer_running = 0
            let g:system_theme_observer_status = 'failed'
        endif
    else
        let g:system_theme_observer_status = 'unsupported'
    endif
endfunction

function! s:StopObserver() abort
    let s:stopping = 1
    if !s:observer_running
        return
    endif

    if has('nvim') && exists('*jobstop')
        call jobstop(s:observer_job)
    elseif exists('*job_stop')
        call job_stop(s:observer_job, 'term')
    endif
    let s:observer_job = 0
    let s:observer_running = 0
    let g:system_theme_observer_status = 'stopped'
endfunction

command! SystemThemeApply call <SID>ApplyTheme()
command! SystemThemeObserverRestart call <SID>StopObserver() | call <SID>StartObserver()

augroup SystemThemeObserver
    autocmd!
    autocmd VimEnter * call <SID>ApplyTheme() | call <SID>StartObserver()
    autocmd VimLeavePre * call <SID>StopObserver()
augroup END
