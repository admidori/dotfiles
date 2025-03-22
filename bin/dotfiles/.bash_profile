#!/bin/sh
# Copyright (c) Aoi Kondo All Rights Reserved.
#    _               _                           __ _ _
#   | |__   __ _ ___| |__       _ __  _ __ ___  / _(_) | ___
#   | '_ \ / _` / __| '_ \     | '_ \| '__/ _ \| |_| | |/ _ \
#  _| |_) | (_| \__ \ | | |    | |_) | | | (_) |  _| | |  __/
# (_)_.__/ \__,_|___/_| |_|____| .__/|_|  \___/|_| |_|_|\___|
#                        |_____|_|

# Path
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:/usr/local/bin/nvim
export PATH=$PATH:$HOME/dotfiles/vendor/vivify
export PATH="$PATH:/usr/local/texlive/2025/bin/x86_64-linux"

###### Scripts ######
### History ###
function share_history {
   history -a
   history -c
   history -r
}
PROMPT_COMMAND='share_history'
shopt -u histappend
export HISTSIZE=2000

### Directory Search ###
if [ -f $HOME/dotfiles/vendor/enhancd/init.sh ]; then
   source $HOME/dotfiles/vendor/enhancd/init.sh
fi

###### Initialize ######
if [[ -f ~/.bashrc ]] ; then
	. ~/.bashrc
fi
