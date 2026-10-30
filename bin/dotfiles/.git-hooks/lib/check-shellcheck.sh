#!/usr/bin/env bash
#
# Shell script linter using shellcheck.
# Warnings only: never blocks commits; skips silently if shellcheck is not installed.
# Targets staged files ending in .sh/.bash or files with a sh/bash shebang (not zsh).
#
set -euo pipefail

check_shellcheck() {
  local target_dir="$1"
  shift

  if ! command -v shellcheck >/dev/null 2>&1; then
    return 0
  fi

  [ $# -gt 0 ] || return 0

  local targets=()
  local file
  for file in "$@"; do
    case "$file" in
      *.sh|*.bash)
        if [ -f "$target_dir/$file" ]; then
          targets+=("$file")
        fi
        ;;
      *)
        if [ -f "$target_dir/$file" ]; then
          local first_line=""
          read -r first_line < "$target_dir/$file" 2>/dev/null || true
          first_line="${first_line%$'\r'}"
          if [[ "$first_line" =~ ^#\!.*[[:space:]/](ba)?sh([[:space:]]|$) ]]; then
            targets+=("$file")
          fi
        fi
        ;;
    esac
  done

  [ "${#targets[@]}" -gt 0 ] || return 0

  local out=""
  out="$(cd "$target_dir" && shellcheck -f gcc "${targets[@]}" 2>&1)" || true

  if [ -n "$out" ]; then
    echo "git-hooks: shellcheck warnings (not blocking):" >&2
    printf '%s\n' "$out" >&2
  fi

  return 0
}
