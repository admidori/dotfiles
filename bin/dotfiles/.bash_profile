#!/bin/sh

# Path
export PATH=$PATH:/usr/local/go/bin

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
