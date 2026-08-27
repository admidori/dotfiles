# Read by EVERY zsh: interactive or not, login or not. Keep it minimal — PATH
# only, no command substitution, nothing slow — because it also runs once per
# `#!/bin/zsh` script. It is the only startup file that applies to
# `ssh <host> '<cmd>'`, scp/sftp/rsync, and other non-interactive remote
# invocations, which read neither .zprofile nor .zshrc — so the PATH entries
# that must hold everywhere belong here, not there.

typeset -U path PATH

# rustup writes this exact line into ~/.zshenv itself on install, and checks for
# it before appending, so keeping it verbatim (guard and all) stops a reinstall
# from adding a duplicate. Guarded because the installer in this repo does not
# set up rust: on a machine without it, sourcing the missing file would print an
# error on every single zsh start.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# User-scoped tools (uv, pipx apps, the fd shim, agy) land here and must resolve
# non-interactively too. Added unconditionally: the dir may be created after a
# shell starts, a non-existent entry is harmless, and typeset -U collapses the
# duplicate when .zshrc re-prepends it as part of its own precedence list.
path=("$HOME/.local/bin" $path)
