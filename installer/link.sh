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

# Top-level dotfiles. .oh-my-zsh is installed fresh (not vendored), .claude is
# handled file-by-file below, and .gitignore is repo-internal.
for src in "$DOTFILES_DIR"/.??*; do
  name="$(basename "$src")"
  case "$name" in
    .gitignore|.claude|.oh-my-zsh) continue ;;
  esac
  ln -snf "$src" "$HOME/$name"
  echo "linked $name"
done

# Link .claude config files individually so we never clobber runtime data
# (history, projects, etc.) that lives in ~/.claude.
mkdir -p "$HOME/.claude"
for src in "$DOTFILES_DIR"/.claude/.* "$DOTFILES_DIR"/.claude/*; do
  [ -e "$src" ] || continue
  name="$(basename "$src")"
  case "$name" in
    .|..|.gitignore) continue ;;
  esac
  ln -snf "$src" "$HOME/.claude/$name"
  echo "linked .claude/$name"
done
