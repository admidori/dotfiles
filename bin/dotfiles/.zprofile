typeset -U path PATH

[ -d /usr/local/texlive/2025/bin/x86_64-linux ] && path=(/usr/local/texlive/2025/bin/x86_64-linux $path)
[ -d /opt/REAPER/reaper ] && path=(/opt/REAPER/reaper $path)
[ -d "$HOME/.local/bin" ] && path=("$HOME/.local/bin" $path)
