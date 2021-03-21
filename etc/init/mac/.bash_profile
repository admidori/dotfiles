export BASH_SILENCE_DEPRECATION_WARNING=1
#Python3のPath設定
export PATH=/usr/local/bin:$PATH
export PATH=$PATH:/usr/local/texlive/current/bin/x86_64-darwin

#Powerline-shellの設定
function _update_ps1() {
    PS1=$(powerline-shell $?)
}

if [[ $TERM != linux && ! $PROMPT_COMMAND =~ _update_ps1 ]]; then
    PROMPT_COMMAND="_update_ps1; $PROMPT_COMMAND"
fi