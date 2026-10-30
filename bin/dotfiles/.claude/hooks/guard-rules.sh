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

  # Commit author identity override. The repo's git config is the only correct
  # source for author/committer; an agent substituting an address it read from
  # its own session context silently splits one human across two accounts in
  # `git log`, and undoing it after a push needs a history rewrite. Covers
  # `git -c user.email=...` (also the quoted form) and the GIT_AUTHOR_* /
  # GIT_COMMITTER_* environment prefix. Deliberately NOT covered:
  # `git commit --author=`, a legitimate attribution to someone else.
  if printf '%s' "$norm" | grep -Eq -- "-c[[:space:]]+['\"]?user\.(name|email)="; then
    printf 'git author identity override (let the repo git config supply it)'; return 1
  fi
  if printf '%s' "$norm" | grep -Eq 'GIT_(AUTHOR|COMMITTER)_(NAME|EMAIL)='; then
    printf 'git author identity override via environment'; return 1
  fi

  # The shell drops quotes and backslashes before git sees its arguments, so
  # `"--no-verify"`, `--no-verif\y` and `core.hooks"Path"` must match too.
  unquoted="$(printf '%s' "$norm" | tr -d "\"'\\\\")"

  # Arguments as git sees them, for the two hook-bypass rules below. Quoted
  # -m / --message values are stripped first so a message that merely mentions
  # a flag (`-m "fix -n handling"`) is not mistaken for it. A double-quoted
  # value containing `$` or a backtick is kept: it may hide a command
  # substitution such as `-m "$(git commit -n ...)"`.
  git_args="$(printf '%s' "$norm" \
    | sed -E 's/(-[^n[:space:]-]*m[[:space:]]+|--message(=|[[:space:]]+))("[^"$`]*"|'\''[^'\'']*'\'')//g' \
    | tr -d "\"'\\\\")"

  # Git hook bypass: --no-verify in a git command.
  # The most common reaction of an agent to a failing hook is to retry with
  # --no-verify (supported by commit, push, merge, rebase, am, cherry-pick,
  # or placed anywhere after git). git also accepts any unambiguous prefix of
  # a long option, so `--no-veri` counts too. git may also start right after
  # `(`, a backtick or `{` (subshells, command substitution, groups).
  # shellcheck disable=SC2016 # the backticks are literal pattern characters
  if printf '%s' "$git_args" \
      | grep -Eq '(^|[|;&(`{[:space:]])([[:alnum:]_./-]*\/)?git[[:space:]](.*[[:space:]])?--no-v(e(r(i(f(y)?)?)?)?)?([[:space:]|;&)`}]|$)'; then
    printf 'git hook bypass (--no-verify)'; return 1
  fi

  # Git hook bypass: git commit -n (short flag alone or in a cluster where n
  # precedes any argument-taking flag: m, F, c, C, t, u).
  if printf '%s' "$git_args" \
      | grep -Eq '(^|[|;&(`{[:space:]])([[:alnum:]_./-]*\/)?git[[:space:]]([^|;&]*[[:space:]])?commit[[:space:]]([^|;&]*[[:space:]])?-[a-ln-sv-zA-BDEG-Z]*n'; then
    printf 'git hook bypass (commit -n)'; return 1
  fi

  # Git hook redirection: blocking core.hooksPath override (case-insensitive)
  # or environment variables that bypass/override global git configuration.
  # Note: GIT_CONFIG_NOSYSTEM is deliberately allowed because hooksPath is global.
  # Not covered (best effort): HOME=... git commit, editing ~/.git-hooks with
  # file tools, git -c alias.x=...
  if printf '%s' "$unquoted" | grep -iEq 'core\.hookspath\b'; then
    printf 'git hooks redirection'; return 1
  fi
  if printf '%s' "$unquoted" | grep -Eq '\bGIT_CONFIG_(GLOBAL|COUNT|KEY_|PARAMETERS)'; then
    printf 'git hooks redirection'; return 1
  fi

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
