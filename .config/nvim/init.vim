let mapleader =","
call plug#begin('~/.vim/plugged')
Plug 'tpope/vim-surround'
Plug 'tpope/vim-commentary'
Plug 'tomasiser/vim-code-dark'
Plug 'junegunn/goyo.vim'
Plug 'bling/vim-airline'
Plug 'dhruvasagar/vim-table-mode'
call plug#end()

set clipboard+=unnamedplus
" Some basics:
	nnoremap c "_c
	set nocompatible
	filetype plugin on
	syntax on
	set encoding=utf-8
	set number relativenumber
" Enable autocompletion:
	set wildmode=longest,list,full
" Disables automatic commenting on newline:
	autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o
" Goyo plugin makes text more readable when writing prose:
	map <leader>g :Goyo \| set linebreak<CR>
" Spell-check set to <leader>o, 'o' for 'orthography':
	map <leader>o :setlocal spell! spelllang=en_us<CR>
" Splits open at the bottom and right, which is non-retarded, unlike vim defaults.
	set splitbelow splitright
" Replace all is aliased to S.
	nnoremap S :%s//g<Left><Left>
" Save file as sudo on files that require root permission
	cnoremap w!! execute 'silent! write !sudo tee % >/dev/null' <bar> edit!

" tab 
set tabstop=4
set shiftwidth=4
set expandtab

" theme
colorscheme codedark
let g:airline_theme = 'codedark'
" transparency
highlight Normal guibg=NONE ctermbg=NONE
highlight nonText guibg=NONE ctermbg=NONE
highlight EndOfBuffer guibg=NONE ctermbg=NONE
" Compile document, be it groff/LaTeX/markdown/etc.
	map <leader>c :w! \| !compiler "<c-r>%"<CR>
