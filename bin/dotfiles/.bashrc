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

###### Appearance ######
export PS1='[\t]\[\033[32m\]\u@\h\[\033[00m\]:\[\033[34m\]\w\[\033[31m\]$(__git_ps1)\[\033[00m\]\$ '
