" vim: ts=4 sw=4 et

if !exists('s:compile_script')
    let s:slash = neomake#utils#Slash()
    let s:compile_script = expand('<sfile>:p:h', 1).s:slash.'python'.s:slash.'compile.py'
endif

function! neomake#makers#ft#python#EnabledMakers() abort
    let makers = ['python', 'frosted']
    if executable('pylama')
        call add(makers, 'pylama')
    else
        if executable('flake8')
            call add(makers, 'flake8')
        else
            call extend(makers, ['pyflakes', 'pycodestyle', 'pydocstyle'])
        endif
        call add(makers, 'pylint')  " Last because it is the slowest
    endif
    return makers
endfunction

let neomake#makers#ft#python#project_root_files = ['setup.cfg', 'tox.ini']

function! neomake#makers#ft#python#DetectPythonVersion() abort
    let output = neomake#compat#systemlist('python -V 2>&1')
    if v:shell_error
        call neomake#log#error(printf(
                    \ 'Failed to detect Python version: %s.',
                    \ join(output)))
        let s:python_version = [-1, -1, -1]
    else
        let s:python_version = split(split(output[0])[1], '\.')
    endif
endfunction

let s:ignore_python_warnings = [
            \ '\v[\/]inspect.py:\d+: Warning:',
            \ '\v^.{-}:\d+: FutureWarning:',
            \ ]

" Filter Python warnings (the warning and the following line).
" To be used as a funcref with filter().
function! s:filter_py_warning(v) abort
    if s:filter_next_py_warning
        let s:filter_next_py_warning = 0
        " Only keep (expected) lines starting with two spaces.
        return a:v[0:1] !=# '  '
    endif
    for pattern in s:ignore_python_warnings
        if a:v =~# pattern
            let s:filter_next_py_warning = 1
            return 0
        endif
    endfor
    return 1
endfunction

function! neomake#makers#ft#python#FilterPythonWarnings(lines, context) abort
    if a:context.source ==# 'stderr'
        let s:filter_next_py_warning = 0
        call filter(a:lines, 's:filter_py_warning(v:val)')
    endif
endfunction

function! neomake#makers#ft#python#pylint() abort
    let maker = {
        \ 'args': [
            \ '--output-format=text',
            \ '--msg-template="{path}:{line}:{column}:{C}: [{symbol}] {msg} [{msg_id}]"',
            \ '--reports=no'
        \ ],
        \ 'errorformat':
            \ '%A%f:%l:%c:%t: %m,' .
            \ '%A%f:%l: %m,' .
            \ '%A%f:(%l): %m,' .
            \ '%-Z%p^%.%#,' .
            \ '%-G%.%#',
        \ 'output_stream': 'stdout',
        \ 'postprocess': [
        \   function('neomake#postprocess#generic_length'),
        \   function('neomake#makers#ft#python#PylintEntryProcess'),
        \ ]}
    function! maker.filter_output(lines, context) abort
        if a:context.source ==# 'stderr'
            call filter(a:lines, "v:val !=# 'No config file found, using default configuration' && v:val !~# '^Using config file '")
        endif
        call neomake#makers#ft#python#FilterPythonWarnings(a:lines, a:context)
    endfunction
    return maker
endfunction

function! neomake#makers#ft#python#PylintEntryProcess(entry) abort
    if a:entry.type ==# 'F'  " Fatal error which prevented further processing
        let type = 'E'
    elseif a:entry.type ==# 'E'  " Error for important programming issues
        let type = 'E'
    elseif a:entry.type ==# 'W'  " Warning for stylistic or minor programming issues
        let type = 'W'
    elseif a:entry.type ==# 'R'  " Refactor suggestion
        let type = 'W'
    elseif a:entry.type ==# 'C'  " Convention violation
        let type = 'W'
    elseif a:entry.type ==# 'I'  " Informations
        let type = 'I'
    else
        let type = ''
    endif
    let a:entry.type = type
    " Pylint uses 0-indexed columns, vim uses 1-indexed columns
    let a:entry.col += 1
endfunction

function! neomake#makers#ft#python#flake8() abort
    let maker = {
        \ 'args': ['--format=default'],
        \ 'errorformat':
            \ '%E%f:%l: could not compile,%-Z%p^,' .
            \ '%A%f:%l:%c: %t%n %m,' .
            \ '%A%f:%l: %t%n %m,' .
            \ '%-G%.%#',
        \ 'postprocess': function('neomake#makers#ft#python#Flake8EntryProcess'),
        \ 'short_name': 'fl8',
        \ 'output_stream': 'stdout',
        \ 'filter_output': function('neomake#makers#ft#python#FilterPythonWarnings'),
        \ }

    function! maker.supports_stdin(jobinfo) abort
        let self.args += ['--stdin-display-name', '%:.']
        call a:jobinfo.cd('%:h')
        return 1
    endfunction
    return maker
endfunction

function! neomake#makers#ft#python#Flake8EntryProcess(entry) abort
    if a:entry.type ==# 'F'  " pyflakes
        " Ref: http://flake8.pycqa.org/en/latest/user/error-codes.html
        if a:entry.nr > 400 && a:entry.nr < 500
            if a:entry.nr == 407
                let type = 'E'  " 'an undefined __future__ feature name was imported'
            else
                let type = 'W'
            endif
        elseif a:entry.nr == 841
            let type = 'W'
        else
            let type = 'E'
        endif
    elseif a:entry.type ==# 'E' && a:entry.nr >= 900  " PEP8 runtime errors (E901, E902)
        let type = 'E'
    elseif a:entry.type ==# 'E' || a:entry.type ==# 'W'  " PEP8 errors & warnings
        let type = 'W'
    elseif a:entry.type ==# 'N' || a:entry.type ==# 'D'  " Naming (PEP8) & docstring (PEP257) conventions
        let type = 'W'
    elseif a:entry.type ==# 'C' || a:entry.type ==# 'T'  " McCabe complexity & todo notes
        let type = 'I'
    elseif a:entry.type ==# 'I' " keep at least 'I' from isort (I1), could get style subtype?!
        let type = a:entry.type
    else
        let type = ''
    endif

    let token_pattern = '\v''\zs[^'']+\ze'
    if a:entry.type ==# 'F' && (a:entry.nr == 401 || a:entry.nr == 811)
        " Special handling for F401 (``module`` imported but unused) and
        " F811 (redefinition of unused ``name`` from line ``N``).
        " The unused column is incorrect for import errors and redefinition
        " errors.
        let token = matchstr(a:entry.text, token_pattern)
        if !empty(token)
            let l:view = winsaveview()
            call cursor(a:entry.lnum, a:entry.col)
            " The number of lines to give up searching afterwards
            let l:search_lines = 5

            if searchpos('\<from\>', 'cnW', a:entry.lnum)[1] == a:entry.col
                " for 'from xxx.yyy import zzz' the token looks like
                " xxx.yyy.zzz, but only the zzz part should be highlighted. So
                " this discards the module part
                let l:token = split(l:token, '\.')[-1]

                " Also the search should be started at the import keyword.
                " Otherwise for 'from os import os' the first os will be
                " found. This moves the cursor there.
                call search('\<import\>', 'cW', a:entry.lnum + l:search_lines)
            endif

            " Search for the first occurrence of the token and highlight in
            " the next couple of lines and change the lnum and col to that
            " position.
            " Don't match entries surrounded by dots, even though
            " it ends a word, we want to find a full identifier. It also
            " matches all seperators such as spaces and newlines with
            " backslashes until it knows for sure the previous real character
            " was not a dot.
            let l:ident_pos = searchpos('\(\.\(\_s\|\\\)*\)\@<!\<' .
                        \ l:token . '\>\(\(\_s\|\\\)*\.\)\@!',
                        \ 'cnW',
                        \ a:entry.lnum + l:search_lines)
            if l:ident_pos[1] > 0
                let a:entry.lnum = l:ident_pos[0]
                let a:entry.col = l:ident_pos[1]
            endif

            call winrestview(l:view)

            let a:entry.length = strlen(l:token)
        endif
    else
        call neomake#postprocess#generic_length_with_pattern(a:entry, token_pattern)

        " Special processing for F821 (undefined name) in f-strings.
        if !has_key(a:entry, 'length') && a:entry.type ==# 'F' && a:entry.nr == 821
            let token = matchstr(a:entry.text, token_pattern)
            if !empty(token)
                " Search for '{token}' in reported and following lines.
                " It seems like for the first line it is correct already (i.e.
                " flake8 reports the column therein), but we still test there
                " to be sure.
                " https://gitlab.com/pycqa/flake8/issues/407
                let line = get(getbufline(a:entry.bufnr, a:entry.lnum), 0, '')
                " NOTE: uses byte offset, starting at col means to start after
                " the opening quote.
                let pattern = '\V\C{\.\{-}\zs'.escape(token, '\').'\>'
                let pos = match(line, pattern, a:entry.col)
                if pos == -1
                    let line_offset = 0
                    while line_offset < 10
                        let line_offset += 1
                        let line = get(getbufline(a:entry.bufnr, a:entry.lnum + line_offset), 0, '')
                        let pos = match(line, pattern)
                        if pos != -1
                            let a:entry.lnum = a:entry.lnum + line_offset
                            break
                        endif
                    endwhile
                endif
                if pos > 0
                    let a:entry.col = pos + 1
                    let a:entry.length = strlen(token)
                endif
            endif
        endif
    endif

    let a:entry.text = a:entry.type . a:entry.nr . ' ' . a:entry.text
    let a:entry.type = type
    let a:entry.nr = ''  " Avoid redundancy in the displayed error message.
endfunction

function! neomake#makers#ft#python#pyflakes() abort
    return {
        \ 'errorformat':
            \ '%E%f:%l: could not compile,' .
            \ '%-Z%p^,'.
            \ '%E%f:%l:%c: %m,' .
            \ '%E%f:%l: %m,' .
            \ '%-G%.%#',
        \ }
endfunction

function! neomake#makers#ft#python#pycodestyle() abort
    if !exists('s:_pycodestyle_exe')
        " Use the preferred exe to avoid deprecation warnings.
        let s:_pycodestyle_exe = executable('pycodestyle') ? 'pycodestyle' : 'pep8'
    endif
    return {
        \ 'exe': s:_pycodestyle_exe,
        \ 'errorformat': '%f:%l:%c: %m',
        \ 'postprocess': function('neomake#makers#ft#python#Pep8EntryProcess')
        \ }
endfunction

" Note: pep8 has been renamed to pycodestyle, but is kept also as alias.
function! neomake#makers#ft#python#pep8() abort
    return neomake#makers#ft#python#pycodestyle()
endfunction

function! neomake#makers#ft#python#Pep8EntryProcess(entry) abort
    if a:entry.text =~# '^E9'  " PEP8 runtime errors (E901, E902)
        let a:entry.type = 'E'
    elseif a:entry.text =~# '^E113'  " unexpected indentation (IndentationError)
        let a:entry.type = 'E'
    else  " Everything else is a warning
        let a:entry.type = 'W'
    endif
endfunction

function! neomake#makers#ft#python#pydocstyle() abort
    if !exists('s:_pydocstyle_exe')
        " Use the preferred exe to avoid deprecation warnings.
        let s:_pydocstyle_exe = executable('pydocstyle') ? 'pydocstyle' : 'pep257'
    endif
    return {
        \ 'exe': s:_pydocstyle_exe,
        \ 'errorformat':
        \   '%W%f:%l %.%#:,' .
        \   '%+C        %m',
        \ 'postprocess': function('neomake#postprocess#compress_whitespace'),
        \ }
endfunction

" Note: pep257 has been renamed to pydocstyle, but is kept also as alias.
function! neomake#makers#ft#python#pep257() abort
    return neomake#makers#ft#python#pydocstyle()
endfunction

function! neomake#makers#ft#python#PylamaEntryProcess(entry) abort
    if a:entry.nr == -1
        " Get number from the beginning of text.
        let nr = matchstr(a:entry.text, '\v^\u\zs\d+')
        if !empty(nr)
            let a:entry.nr = nr + 0
        endif
    endif
    if a:entry.type ==# 'C' && a:entry.text =~# '\v\[%(pycodestyle|pep8)\]$'
        call neomake#makers#ft#python#Pep8EntryProcess(a:entry)
    elseif a:entry.type ==# 'D'  " pydocstyle/pep257
        let a:entry.type = 'W'
    elseif a:entry.type ==# 'C' && a:entry.nr == 901  " mccabe
        let a:entry.type = 'I'
    elseif a:entry.type ==# 'R'  " Radon
        let a:entry.type = 'W'
    endif
endfunction

function! neomake#makers#ft#python#pylama() abort
    let maker = {
        \ 'args': ['--format', 'parsable'],
        \ 'errorformat': '%f:%l:%c: [%t] %m',
        \ 'postprocess': function('neomake#makers#ft#python#PylamaEntryProcess'),
        \ 'output_stream': 'stdout',
        \ }
    " Pylama looks for the config only in the current directory.
    " Therefore we change to where the config likely is.
    " --options could be used to pass a config file, but we cannot be sure
    " which one really gets used.
    let ini_file = neomake#utils#FindGlobFile('{pylama.ini,setup.cfg,tox.ini,pytest.ini}')
    if !empty(ini_file)
        let maker.cwd = fnamemodify(ini_file, ':h')
    endif
    return maker
endfunction

function! neomake#makers#ft#python#python() abort
    return {
        \ 'args': [s:compile_script],
        \ 'errorformat': '%E%f:%l:%c: %m',
        \ 'serialize': 1,
        \ 'serialize_abort_on_error': 1,
        \ 'output_stream': 'stdout',
        \ 'short_name': 'py',
        \ }
endfunction

function! neomake#makers#ft#python#frosted() abort
    return {
        \ 'args': [
            \ '-vb'
        \ ],
        \ 'errorformat':
            \ '%f:%l:%c:%m,' .
            \ '%E%f:%l: %m,' .
            \ '%-Z%p^,' .
            \ '%-G%.%#'
        \ }
endfunction

function! neomake#makers#ft#python#vulture() abort
    return {
        \ 'errorformat': '%f:%l: %m',
        \ }
endfunction

" --fast-parser: adds experimental support for async/await syntax
" --silent-imports: replaced by --ignore-missing-imports
function! neomake#makers#ft#python#mypy() abort
    let l:args = ['--check-untyped-defs', '--ignore-missing-imports']

    " Append '--py2' to args with Python 2 for Python 2 mode.
    if !exists('s:python_version')
        call neomake#makers#ft#python#DetectPythonVersion()
    endif
    if s:python_version[0] ==# '2'
        call add(l:args, '--py2')
    endif

    return {
        \ 'args': l:args,
        \ 'errorformat':
            \ '%E%f:%l: error: %m,' .
            \ '%W%f:%l: warning: %m,' .
            \ '%I%f:%l: note: %m',
        \ }
endfunction

function! neomake#makers#ft#python#py3kwarn() abort
    return {
        \ 'errorformat': '%W%f:%l:%c: %m',
        \ }
endfunction
