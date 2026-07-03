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
    .gitignore|.oh-my-zsh) continue ;;
  esac
  is_tool_dir "$name" && continue
  ln -snf "$src" "$HOME/$name"
  echo "linked $name"
done

# link_dir_contents <src_dir> <dest_dir> <label>
# Symlinks each entry of src_dir into dest_dir individually, backing up any
# pre-existing non-symlink entry first. <label> is the dest path relative to
# $HOME, used both for logging and to check MERGE_DIRS. Recurses instead of
# linking the whole entry when <label>/<name> is a merge dir (see common.sh),
# so mixed-ownership subdirectories merge rather than get clobbered.
link_dir_contents() {
  local src_dir="$1"
  local dest_dir="$2"
  local label="$3"
  local src name dest backup
  mkdir -p "$dest_dir"
  for src in "$src_dir"/.* "$src_dir"/*; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    case "$name" in
      .|..|.gitignore) continue ;;
    esac
    if is_merge_dir "$label/$name"; then
      dest="$dest_dir/$name"
      if [ -L "$dest" ]; then
        # A prior run may have linked this whole directory as one symlink
        # before it became a merge dir; drop it so a real, per-entry-linked
        # directory can take its place below.
        rm "$dest"
      elif [ -e "$dest" ] && [ ! -d "$dest" ]; then
        backup="$dest.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
        mv "$dest" "$backup"
        echo "backed up existing $label/$name to $backup"
      fi
      link_dir_contents "$src" "$dest" "$label/$name"
      continue
    fi
    dest="$dest_dir/$name"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      backup="$dest.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
      mv "$dest" "$backup"
      echo "backed up existing $label/$name to $backup"
    fi
    ln -snf "$src" "$dest"
    echo "linked $label/$name"
  done
}

# Link AI tool config files individually so we never clobber runtime data
# (auth, history, projects, state databases, etc.) in those directories.
for tool in "${TOOL_DIRS[@]}"; do
  link_dir_contents "$DOTFILES_DIR/$tool" "$HOME/$tool" "$tool"
done
