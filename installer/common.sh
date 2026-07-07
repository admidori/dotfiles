#!/usr/bin/env bash
#
# Shared definitions for the installer scripts. Source this after defining
# DOTFILES_DIR. The single source of truth for which AI-tool config directories
# are linked file-by-file (so their runtime data is never clobbered): add a tool
# here once and link.sh/unlink.sh/test.sh all pick it up.
#
# Note: each tool's shared baseline reaches a single canonical file —
# .gemini/AGENTS.md is a repo-internal symlink to .codex/AGENTS.md, and
# .claude/CLAUDE.md @-imports it — so editing .codex/AGENTS.md updates all three.

TOOL_DIRS=(.claude .codex .gemini)

# Nested directories, relative to a tool dir, that mix dotfiles-tracked
# content with content this repo doesn't own — e.g. ~/.claude/skills holds
# both our tracked skills and marketplace-installed ones. These need the same
# file-by-file linking as a tool dir itself, one level deeper, instead of
# being replaced by a single directory symlink.
MERGE_DIRS=(.claude/skills)

# contains <needle> <haystack...> — true if needle is one of the remaining args.
contains() {
  local needle="$1"
  shift
  local hay
  for hay in "$@"; do
    [ "$needle" = "$hay" ] && return 0
  done
  return 1
}

# is_tool_dir <name> — true if <name> is one of the file-by-file tool dirs.
is_tool_dir() {
  contains "$1" "${TOOL_DIRS[@]}"
}

# is_merge_dir <tool_dir>/<name> — true if that path must be linked
# file-by-file rather than as a single directory symlink.
is_merge_dir() {
  contains "$1" "${MERGE_DIRS[@]}"
}

# Files, relative to a tool dir, that the tool itself writes local/private
# state back into (e.g. Codex writes per-project trust decisions and a UI
# nux counter directly into ~/.codex/config.toml). Symlinking these would
# send every such write straight into this tracked repo, so they're seeded
# once via a real copy instead and left alone on every later install.
COPY_ONCE_FILES=(.codex/config.toml)

# is_copy_once_file <tool_dir>/<name> — true if that path must be seeded
# once via a copy instead of kept in sync via a symlink.
is_copy_once_file() {
  contains "$1" "${COPY_ONCE_FILES[@]}"
}

# link_dir_contents <src_dir> <dest_dir> <label>
# Symlinks each entry of src_dir into dest_dir individually, backing up any
# pre-existing non-symlink entry first. <label> is the dest path relative to
# $HOME, used both for logging and to check MERGE_DIRS. Recurses instead of
# linking the whole entry when <label>/<name> is a merge dir (see MERGE_DIRS),
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
    if is_copy_once_file "$label/$name"; then
      # A prior run may have symlinked this before it became a copy-once
      # file; drop that self-managed symlink so the seed step below can
      # replace it with a real, independently-writable file.
      if [ -L "$dest" ]; then
        case "$(readlink "$dest")" in
          "$DOTFILES_DIR"/*) rm "$dest" ;;
        esac
      fi
      if [ -e "$dest" ]; then
        echo "$label/$name already exists locally; leaving it as-is"
      else
        cp "$src" "$dest"
        echo "seeded $label/$name (one-time copy, not kept in sync)"
      fi
      continue
    fi
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      backup="$dest.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
      mv "$dest" "$backup"
      echo "backed up existing $label/$name to $backup"
    fi
    ln -snf "$src" "$dest"
    echo "linked $label/$name"
  done
}
