typeset -U path PATH

[ -d /usr/local/texlive/2025/bin/x86_64-linux ] && path=(/usr/local/texlive/2025/bin/x86_64-linux $path)
[ -d /opt/REAPER/reaper ] && path=(/opt/REAPER/reaper $path)
# Add unconditionally (not [ -d ]-guarded): user-scoped tools (uv, pipx apps,
# the fd shim, agy) land here, and a login shell must keep it on PATH even when
# the dir is created after login. A non-existent entry is harmless; typeset -U
# dedups it.
path=("$HOME/.local/bin" $path)
