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
