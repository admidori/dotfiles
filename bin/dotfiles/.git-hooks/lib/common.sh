#!/usr/bin/env bash
#
# Shared helper functions for git hooks.
#
set -euo pipefail

# join_strings <delimiter> <elements...>
# Joins arguments with the specified delimiter.
join_strings() {
  local sep="$1"
  shift
  local out=""
  while [ $# -gt 0 ]; do
    if [ -z "$out" ]; then
      out="$1"
    else
      out="${out}${sep}${1}"
    fi
    shift
  done
  echo "$out"
}

# chain_pre_commit <args...>
# Chains to the repo-local pre-commit hook if present and executable,
# or executes pre-commit run if .pre-commit-config.yaml is present.
chain_pre_commit() {
  local common_dir local_hook toplevel

  # 1. Executable repo-local pre-commit hook (guarding against self-recursion)
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  if [ -d "$common_dir" ]; then
    common_dir="$(cd "$common_dir" && pwd -P)"
  fi
  local_hook="$common_dir/hooks/pre-commit"

  if [ -x "$local_hook" ]; then
    local self target
    self="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
    target="$(readlink -f "$local_hook" 2>/dev/null || realpath "$local_hook")"
    if [ "$self" != "$target" ]; then
      exec "$local_hook" "$@"
    fi
  fi

  # 2. pre-commit framework, only after a per-repo opt-in. The config file
  #    comes with the clone and makes pre-commit fetch and run arbitrary
  #    code, so its presence alone must not be trusted. Local git config can't
  #    be set by a clone, which makes it the opt-in (it replaces
  #    `pre-commit install`, which refuses to run under core.hooksPath).
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || toplevel=""
  if [ -n "$toplevel" ] && [ -f "$toplevel/.pre-commit-config.yaml" ]; then
    if [ "$(git config --local --type=bool --get hooks.preCommitFramework 2>/dev/null)" != "true" ]; then
      echo "git-hooks: .pre-commit-config.yaml not run; if you trust this repo: git config --local hooks.preCommitFramework true" >&2
      return 0
    fi
    if command -v pre-commit >/dev/null 2>&1; then
      exec pre-commit run --hook-stage pre-commit "$@"
    else
      echo "git-hooks: warning: .pre-commit-config.yaml found but pre-commit is not installed or not on PATH" >&2
      return 0
    fi
  fi

  return 0
}
