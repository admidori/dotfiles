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

# Mirror of link.sh's link_dir_contents: remove only the per-file symlinks
# this repo created under an AI tool dir, leaving runtime data in place.
# Recurses into MERGE_DIRS the same way link.sh does, since those entries
# were linked one level deeper rather than as a single directory symlink.
unlink_dir_contents() {
  src_dir="$1"
  dest_dir="$2"
  label="$3"
  for src in "$src_dir"/.* "$src_dir"/*; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    case "$name" in
      .|..) continue ;;
    esac
    if is_merge_dir "$label/$name"; then
      unlink_dir_contents "$src" "$dest_dir/$name" "$label/$name"
      continue
    fi
    unlink_if_managed "$dest_dir/$name"
  done
}

for src in "$DOTFILES_DIR"/.??*; do
  unlink_if_managed "$HOME/$(basename "$src")"
done

for tool in "${TOOL_DIRS[@]}"; do
  unlink_dir_contents "$DOTFILES_DIR/$tool" "$HOME/$tool" "$tool"
done
