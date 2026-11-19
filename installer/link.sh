#!/usr/bin/env bash
#
# Create/update symlinks from $HOME to the tracked dotfiles in this repo.
# Resolves its own location so it works via `make`, directly, or from install.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTFILES_DIR="$REPO_ROOT/bin/dotfiles"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"

# Top-level dotfiles. .oh-my-zsh is installed fresh (not vendored), AI tool
# dirs are handled file-by-file below, and .gitignore is repo-internal.
for src in "$DOTFILES_DIR"/.??*; do
  name="$(basename "$src")"
  case "$name" in
    .gitignore|.oh-my-zsh|.config) continue ;;
  esac
  is_tool_dir "$name" && continue
  ln -snf "$src" "$HOME/$name"
  echo "linked $name"
done

# XDG config directory entries are linked individually into XDG_CONFIG_HOME
# so unrelated user configs and tools are preserved.
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
# An older installer could have linked the config root directly to this repo.
if [ -d "$DOTFILES_DIR/.config" ] && [ ! "$DOTFILES_DIR/.config" -ef "$config_home" ]; then
  link_dir_contents "$DOTFILES_DIR/.config" "$config_home" ".config"
fi

# Link AI tool config files individually so we never clobber runtime data
# (auth, history, projects, state databases, etc.) in those directories.
for tool in "${TOOL_DIRS[@]}"; do
  link_dir_contents "$DOTFILES_DIR/$tool" "$HOME/$tool" "$tool"
done
