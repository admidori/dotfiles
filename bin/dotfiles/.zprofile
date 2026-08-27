typeset -U path PATH

# Add unconditionally (not [ -d ]-guarded): user-scoped tools (uv, pipx apps,
# the fd shim, agy) land here, and a login shell must keep it on PATH even when
# the dir is created after login. A non-existent entry is harmless; typeset -U
# dedups it.
path=("$HOME/.local/bin" $path)
