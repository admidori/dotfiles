# zplug setting
source ~/.zplug/init.zsh
zplug 'zplug/zplug', hook-build:'zplug --self-manage'

# ----------Zsh plugins----------
# theme
zplug "romkatv/powerlevel10k", as:theme, depth:1

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

# ----------Plugins END----------

# Install plugins if there are plugins that have not been installed
if ! zplug check --verbose; then
  printf "Install? [y/N]: "
  if read -q; then
    echo; zplug install
  fi
fi

zplug load

# powerlevel10k setting
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh