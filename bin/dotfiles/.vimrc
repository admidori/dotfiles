" 
"            _
"     __   _(_)_ __ ___  _ __ ___
"     \ \ / / | '_ ` _ \| '__/ __|
"      \ V /| | | | | | | | | (__
"       \_/ |_|_| |_| |_|_|  \___|
"

"----------------------------------------
" Colorscheme
"----------------------------------------
if !has('gui_running') && &term =~ '^\%(screen\|tmux\)'
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
endif

syntax enable
set t_Co=256

"----------------------------------------
" General
"----------------------------------------
set nowritebackup
set nobackup
set virtualedit=block
set backspace=indent,eol,start
set ambiwidth=double
set wildmenu
set cursorline
set scrolloff=1
let &t_ti .= "\e[2 q"
let &t_SI .= "\e[6 q"
let &t_EI .= "\e[2 q"
let &t_SR .= "\e[4 q"
let &t_te .= "\e[6 q"
set encoding=utf-8
set fileencodings=iso-2022-jp,cp932,euc-jp,sjis,utf-8,windows932

"----------------------------------------
" Search
"----------------------------------------
set ignorecase
set smartcase
set wrapscan
set incsearch
set hlsearch

"----------------------------------------
" Appearance
"----------------------------------------
set noerrorbells
set shellslash
set showmatch matchtime=1
set cinoptions+=:0
set cmdheight=1
set showcmd
set display=lastline
set history=10000
set shiftwidth=2
set softtabstop=2
set tabstop=2
set guioptions-=T
set guioptions+=a
set guioptions-=m
set guioptions+=R
set showmatch
set smartindent
set noswapfile
set nofoldenable
set title
set number
set clipboard=unnamedplus,autoselect
nnoremap <Esc><Esc> :nohlsearch<CR><ESC>
set nrformats=
set whichwrap=b,s,h,l,<,>,[,],~
set mouse=a
set laststatus=2

