#!/usr/bin/env bash
#
# Remove only the symlinks that this repo created (i.e. links whose target
# points inside bin/dotfiles). Leaves unrelated links in $HOME untouched.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTFILES_DIR="$REPO_ROOT/bin/dotfiles"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

echo "########################"
echo "# UNLINK SYMBOLIC LINK #"
echo "########################"

unlink_if_managed() {
  link="$1"
  if [ -L "$link" ]; then
    target="$(readlink "$link")"
    case "$target" in
      "$DOTFILES_DIR"/*|*//bin/dotfiles/*)
        unlink "$link"
        echo "unlinked $link"
        ;;
    esac
  fi
}

# Mirror of link.sh's link_tool_config_dir: remove only the per-file symlinks
# this repo created under an AI tool dir, leaving runtime data in place.
unlink_tool_config_dir() {
  tool_dir="$1"
  for src in "$DOTFILES_DIR/$tool_dir"/.* "$DOTFILES_DIR/$tool_dir"/*; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    case "$name" in
      .|..) continue ;;
    esac
    unlink_if_managed "$HOME/$tool_dir/$name"
  done
}

for src in "$DOTFILES_DIR"/.??*; do
  unlink_if_managed "$HOME/$(basename "$src")"
done

for tool in "${TOOL_DIRS[@]}"; do
  unlink_tool_config_dir "$tool"
done
