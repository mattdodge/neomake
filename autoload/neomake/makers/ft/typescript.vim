" vim: ts=4 sw=4 et

function! neomake#makers#ft#typescript#EnabledMakers() abort
    return ['tsc', 'tslint']
endfunction

function! neomake#makers#ft#typescript#tsc() abort
    " tsc should not be passed a single file.
    let maker = {
        \ 'args': ['--noEmit', '--watch', 'false', '--pretty', 'false'],
        \ 'append_file': 0,
        \ 'errorformat':
            \ '%E%f %#(%l\,%c): error %m,' .
            \ '%E%f %#(%l\,%c): %m,' .
            \ '%Eerror %m,' .
            \ '%C%\s%\+%m'
        \ }
    let config = neomake#utils#FindGlobFile('tsconfig.json')
    if !empty(config)
        let maker.args += ['--project', config]
    endif
    return maker
endfunction

function! neomake#makers#ft#typescript#tslint() abort
    let maker = {
        \ 'errorformat': '%-G,%EERROR: %f[%l\, %c]: %m,%E%f[%l\, %c]: %m',
        \ }
    let config = neomake#utils#FindGlobFile('tsconfig.json')
    if !empty(config)
        let maker.args = ['--project', config]
        let maker.cwd = fnamemodify(config, ':h')
    endif
    return maker
endfunction
