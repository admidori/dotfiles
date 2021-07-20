alias tmux="tmux -u2"
alias ghidra '~/Documents/Ghidra/10.0.1_PUBLIC/ghidraRun'

# Auto tmux
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

# easy moving directory
zplug "b4b4r07/enhancd", use:enhancd.sh

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

# Source Prezto.
if [[ -s "${ZDOTDIR:-$HOME}/.zprezto/init.zsh" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"
fi

# Source powerlevel10k
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Autocomplete
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
export PATH="/usr/local/Cellar/qemu/6.0.0/bin:$PATH"
export PATH="/usr/local/opt/openjdk/bin:$PATH"
