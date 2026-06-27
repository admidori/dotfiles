#!/usr/bin/env bash
#
# Shared dangerous-command rules for the bash-guard PreToolUse hooks.
#
# Sourced by both .claude/hooks/bash-guard.sh and .codex/hooks/bash-guard.sh
# (the latter reaches this file via a repo-internal symlink at
# .codex/hooks/guard-rules.sh -> ../../.claude/hooks/guard-rules.sh). This is the
# single source of truth for WHAT counts as dangerous; each hook keeps only its
# own command-extraction and block-output glue. Keep tool-specific I/O out.
#
# This is best-effort defense in depth, not a security boundary: a determined
# command can still evade these patterns. The matching below normalizes runs of
# whitespace and covers the common flag/spacing variants on top of that.

# guard_check_command <command>
# Prints a human-readable reason and returns 1 if the command looks dangerous;
# returns 0 with no output otherwise. All match attempts live inside `if` so a
# non-match never trips the caller's `set -e`.
guard_check_command() {
  cmd="$1"
  # Collapse tabs and runs of spaces to a single space so e.g. "rm  -rf"
  # (multiple spaces) cannot slip past the literal patterns below.
  norm="$(printf '%s' "$cmd" | tr '\t' ' ' | tr -s ' ')"

  case "$norm" in
    *"git reset --hard"*|*"git clean -f"*|*"git clean -d"*|*"git push --force"*|*"git push -f"*)
      printf 'destructive git command'; return 1 ;;
    *"sudo rm "*|*"chmod -R 777"*)
      printf 'destructive filesystem command'; return 1 ;;
  esac

  # rm with BOTH recursive and force, in the common orderings/spellings. Listed
  # explicitly (rather than two independent greps) so flags belonging to a
  # different command in a compound line — e.g. `rm a; cp -rf b` — don't match.
  case "$norm" in
    *"rm -rf"*|*"rm -fr"*|*"rm -Rf"*|*"rm -fR"*|\
    *"rm -r -f"*|*"rm -f -r"*|*"rm -R -f"*|*"rm -f -R"*|\
    *"rm --recursive --force"*|*"rm --force --recursive"*|\
    *"rm -r --force"*|*"rm --recursive -f"*|*"rm -f --recursive"*|*"rm --force -r"*)
      printf 'destructive filesystem command'; return 1 ;;
  esac

  # Remote script execution: curl/wget piped (optionally via sudo) into a shell.
  if printf '%s' "$norm" \
      | grep -Eq '(curl|wget)[^|;&]*(\||;|&&)[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)\b'; then
    printf 'remote script execution'; return 1
  fi
  # Remote script execution via process substitution: bash <(curl ...).
  if printf '%s' "$norm" \
      | grep -Eq '(sh|bash|zsh)[[:space:]]+<\([[:space:]]*(curl|wget)\b'; then
    printf 'remote script execution'; return 1
  fi

  return 0
}
