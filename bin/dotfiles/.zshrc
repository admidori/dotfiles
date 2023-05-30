# 
#              _
#      _______| |__  _ __ ___
#     |_  / __| '_ \| '__/ __|
#      / /\__ \ | | | | | (__
#     /___|___/_| |_|_|  \___|
# 

# tmux autmatic start
alias tmux="tmux -u2"
count=`ps aux | grep tmux | grep -v grep | wc -l`
if test $count -eq 0; then
    echo `tmux`
elif test $count -eq 1; then
    echo `tmux a`
fi

# zplug setting
source ~/.zplug/init.zsh
zplug 'zplug/zplug', hook-build:'zplug --self-manage'

# ----------Zsh plugins----------
# async job
zplug "mafredri/zsh-async"
# syntax-highlighting
zplug "zsh-users/zsh-syntax-highlighting", defer:2
# auto-complete
zplug "zsh-users/zsh-completions"
# history-search
zplug "zsh-users/zsh-history-substring-search"
# history-search
zplug "zsh-users/zsh-autosuggestions"
# easy moving directory
zplug "b4b4r07/enhancd", use:init.sh
# 256color
zplug "chrissicool/zsh-256color"
# theme
zplug "romkatv/powerlevel10k", as:theme, depth:1

# ----------Plugins END----------

# Install plugins if there are plugins that have not been installed
if ! zplug check --verbose; then
  printf "Install? [y/N]: "
  if read -q; then
    echo; zplug install
  fi
fi
zplug load

# Source powerlevel10k
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Autocomplete
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# peco settings
function peco-select-history() {
  BUFFER=$(\history -n -r 1 | peco --query "$LBUFFER")
  CURSOR=$#BUFFER
  zle clear-screen
}
zle -N peco-select-history
bindkey '^r' peco-select-history

# search a destination from cdr list
function peco-get-destination-from-cdr() {
  cdr -l | \
  sed -e 's/^[[:digit:]]*[[:blank:]]*//' | \
  peco --query "$LBUFFER"
}

function peco-cdr() {
  local destination="$(peco-get-destination-from-cdr)"
  if [ -n "$destination" ]; then
    BUFFER="cd $destination"
    zle accept-line
  else
    zle reset-prompt
  fi
}
zle -N peco-cdr
bindkey '^u' peco-cdr
