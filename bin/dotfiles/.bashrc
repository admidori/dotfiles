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


###### Export ######
GIT_PS1_SHOWDIRTYSTATE=true
GIT_PS1_SHOWUNTRACKEDFILES=true
GIT_PS1_SHOWSTASHSTATE=true
GIT_PS1_SHOWUPSTREAM=auto

export PS1='[\t]\[\033[32m\]\u@\h\[\033[00m\]:\[\033[34m\]\w\[\033[31m\]$(__git_ps1)\[\033[00m\]\$ '

###### Alias ######
alias vi='nvim'
alias vim='nvim'

###### Scripts ######
### enhancd ###
source $HOME/dotfiles/vendor/enhancd/init.sh

### Git status ###
if [ -f $HOME/dotfiles/vendor/git-branch/git-completion.bash ]; then
    source $HOME/dotfiles/vendor/git-branch/git-completion.bash
fi
if [ -f $HOME/dotfiles/vendor/git-branch/git-prompt.sh ]; then
    source $HOME/dotfiles/vendor/git-branch/git-prompt.sh
fi

###### bash-completion ######
source /etc/bash_completion

##### Software configuration ####
##### conda initialize #####
__conda_setup="$($HOME'/anaconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "$HOME/anaconda3/etc/profile.d/conda.sh" ]; then
        . "$HOME/anaconda3/etc/profile.d/conda.sh"  # commented out by conda initialize
    else
        . export PATH="$HOME/anaconda3/bin:$PATH"  # commented out by conda initialize
    fi
fi
unset __conda_setup

##### tmux initialize ####
alias tmux="tmux -u2"

count=`ps aux | grep tmux | grep -v grep | wc -l`
if test $count -eq 0; then
    echo `tmux`
elif test $count -eq 1; then
    echo `tmux a`
fi

#### nvm initialize ####
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export GPG_TTY=$(tty)

### bash completion ###
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
