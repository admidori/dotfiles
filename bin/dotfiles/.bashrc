#!/bin/sh
# Copyright (c) Aoi Kondo All Rights Reserved.
#    _               _
#   | |__   __ _ ___| |__  _ __ ___
#   | '_ \ / _` / __| '_ \| '__/ __|
#  _| |_) | (_| \__ \ | | | | | (__
# (_)_.__/ \__,_|___/_| |_|_|  \___|

# Initialize
if [ -f /etc/bashrc ]; then
        . /etc/bashrc
fi

###### Alias ######
alias vi='nvim'
alias vim='nvim'

###### Scripts ######
### Git status ###
if [ -f $HOME/dotfiles/vendor/git-branch/git-completion.bash ]; then
    source $HOME/dotfiles/vendor/git-branch/git-completion.bash
fi
if [ -f $HOME/dotfiles/vendor/git-branch/git-prompt.sh ]; then
    source $HOME/dotfiles/vendor/git-branch/git-prompt.sh
fi

GIT_PS1_SHOWDIRTYSTATE=true
GIT_PS1_SHOWUNTRACKEDFILES=true
GIT_PS1_SHOWSTASHSTATE=true
GIT_PS1_SHOWUPSTREAM=auto

###### Export ######
export PS1='[\t]\[\033[32m\]\u@\h\[\033[00m\]:\[\033[34m\]\w\[\033[31m\]$(__git_ps1)\[\033[00m\]\$ '
export GPG_TTY=$(tty)

##### conda initialize #####
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/home/admidori/anaconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/home/admidori/anaconda3/etc/profile.d/conda.sh" ]; then
        . "/home/admidori/anaconda3/etc/profile.d/conda.sh"
    else
        export PATH="/home/admidori/anaconda3/bin:$PATH"
    fi
fi
unset __conda_setup

##### Tmux initialize ####
alias tmux="tmux -u2"

count=`ps aux | grep tmux | grep -v grep | wc -l`
if test $count -eq 0; then
    echo `tmux`
elif test $count -eq 1; then
    echo `tmux a`
fi
