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

# is_tool_dir <name> — true if <name> is one of the file-by-file tool dirs.
is_tool_dir() {
  local d
  for d in "${TOOL_DIRS[@]}"; do
    [ "$1" = "$d" ] && return 0
  done
  return 1
}
