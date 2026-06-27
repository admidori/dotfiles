#!/usr/bin/env bash
#
# Create/update symlinks from $HOME to the tracked dotfiles in this repo.
# Resolves its own location so it works via `make`, directly, or from install.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTFILES_DIR="$REPO_ROOT/bin/dotfiles"

echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"

# Top-level dotfiles. .oh-my-zsh is installed fresh (not vendored), AI tool
# dirs are handled file-by-file below, and .gitignore is repo-internal.
for src in "$DOTFILES_DIR"/.??*; do
  name="$(basename "$src")"
  case "$name" in
    .gitignore|.claude|.codex|.oh-my-zsh) continue ;;
  esac
  ln -snf "$src" "$HOME/$name"
  echo "linked $name"
done

link_tool_config_dir() {
  tool_dir="$1"
  mkdir -p "$HOME/$tool_dir"
  for src in "$DOTFILES_DIR/$tool_dir"/.* "$DOTFILES_DIR/$tool_dir"/*; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    case "$name" in
      .|..|.gitignore) continue ;;
    esac
    dest="$HOME/$tool_dir/$name"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      backup="$dest.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
      mv "$dest" "$backup"
      echo "backed up existing $tool_dir/$name to $backup"
    fi
    ln -snf "$src" "$dest"
    echo "linked $tool_dir/$name"
  done
}

# Link AI tool config files individually so we never clobber runtime data
# (auth, history, projects, state databases, etc.) in those directories.
link_tool_config_dir ".claude"
link_tool_config_dir ".codex"
