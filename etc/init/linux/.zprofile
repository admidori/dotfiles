#Python3のPath設定
export PATH=/usr/local/bin:$PATH
export PATH=$PATH:/usr/local/texlive/current/bin/x86_64-darwin

if [ -f ~/.zshrc ]; then
    . ~/.zshrc
fi