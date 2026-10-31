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
  # The shell joins a backslash-newline before parsing, so `--g\<newline>lobal`
  # is `--global` to git; every line-based match below would otherwise see two
  # harmless halves. Join continuations the way bash does (see
  # guard_join_continuations), and also check the raw form, blocking if either
  # reading is dangerous.
  case "$1" in
    *$'\\\n'*)
      guard_check_single "$1" || return 1
      guard_check_single "$(guard_join_continuations "$1")" || return 1
      # Comments, single quotes and heredocs change whether a backslash-newline
      # is a continuation (`# x\<newline>git …` is not one), and a text matcher
      # can follow neither that nor how the shell would spell the command name
      # (`g'i't`, `g${x}it`). So fail closed on any such command, whatever it
      # runs; it can always be written on one line instead.
      case "$1" in
        *'#'* | *"'"* | *'<<'*)
          printf 'ambiguous line continuation (put the command on one line)'
          return 1
          ;;
      esac
      ;;
    *) guard_check_single "$1" ;;
  esac
}

# guard_join_continuations <command>
# Removes a backslash-newline only when the backslash is itself unescaped,
# i.e. preceded by an even number of backslashes. In `x\\<newline>git …` the
# backslash pair is a literal backslash and the newline ends the command, so a
# blanket replace would glue `git` onto `x` and hide it; with this rule a
# later real continuation (`--no-\<newline>verify`) is still joined.
guard_join_continuations() {
  local s="$1" out="" c i run=0
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [ "$c" = $'\n' ] && [ $((run % 2)) -eq 1 ]; then
      out="${out%\\}"
      run=0
      continue
    fi
    out+="$c"
    if [ "$c" = "\\" ]; then
      run=$((run + 1))
    else
      run=0
    fi
  done
  printf '%s' "$out"
}

# guard_check_single <command>
# The rules themselves, applied to one textual form of the command.
guard_check_single() {
  cmd="$1"
  # Collapse tabs and runs of spaces to a single space so e.g. "rm  -rf"
  # (multiple spaces) cannot slip past the literal patterns below.
  norm="$(printf '%s' "$cmd" | tr '\t' ' ' | tr -s ' ')"

  # ANSI-C quoting decodes escapes before the command runs: `$'\x2d-no-verify'`
  # is `--no-verify` to git, but every rule below would see `\x2d`. Decoding
  # every escape form faithfully is another parser to keep in sync, so any
  # `$'…'` text with a backslash escape fails closed; write it plainly.
  case "$norm" in
    *"\$'"*\\*)
      printf 'ANSI-C quoted text with escapes (write it plainly)'; return 1 ;;
  esac

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
  # Message values are deliberately not stripped: a regex cannot follow shell
  # quoting, and crafted quotes (`"-m '" --no-verify "'"`) would hide a real
  # flag. So an inline -m message that mentions these flags is blocked as
  # well; write such messages to a file and use `git commit -F <file>`.
  # `$'…'` without escapes and `$"…"` (locale strings) are plain quoting, so
  # drop their `$` first; otherwise `$'--global'` would leave `$--global`
  # behind and evade the word matches.
  unquoted="$(printf '%s' "$norm" | sed -e "s/\\\$'/'/g" -e 's/\$"/"/g' | tr -d "\"'\\\\")"

  # Git hook bypass: --no-verify in a git command.
  # The most common reaction of an agent to a failing hook is to retry with
  # --no-verify (supported by commit, push, merge, rebase, am, cherry-pick,
  # or placed anywhere after git). git also accepts any unambiguous prefix of
  # a long option, so `--no-veri` counts too. git may also start right after
  # `(`, a backtick or `{` (subshells, command substitution, groups).
  # shellcheck disable=SC2016 # the backticks are literal pattern characters
  if printf '%s' "$unquoted" \
      | grep -Eq '(^|[|;&(`{[:space:]])([[:alnum:]_./-]*\/)?git[[:space:]](.*[[:space:]])?--no-v(e(r(i(f(y)?)?)?)?)?([[:space:]|;&)`}]|$)'; then
    printf 'git hook bypass (--no-verify)'; return 1
  fi

  # Git hook bypass: git commit -n (short flag alone or in a cluster where n
  # precedes any argument-taking flag: m, F, c, C, t, u).
  if printf '%s' "$unquoted" \
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

  # Git hook machinery file protection (Rule A): block shell commands that
  # reference files the global git hooks depend on, scanner binaries, guard files,
  # or global/system git configs using home-anchored or XDG paths.
  # Best effort: relative paths after cd ~ or arbitrary interpreters (python, node)
  # writing to these paths are not caught here; file tools are covered by
  # permission rules (see design.md).
  # Whole-name matching is used for .gitconfig (so .gitconfig-work and .gitconfig.bak
  # stay allowed) and scanner binaries (so e.g. gitleaks-foo stays allowed).
  # Worktree checkouts (e.g. under ~/dotfiles/.claude/worktrees/ or ~/dotfiles-*-impl)
  # and relative paths remain allowed.
  # `~user/` is the same home directory as `~/` for the shell, so the tilde
  # prefix also accepts a user name; /root and /Users/<name> are homes too.
  # `~/.config/git/config` is read as global git config, like ~/.gitconfig.
  # Paths are matched after collapsing `//`, `/./` and `seg/../`, and any
  # home-anchored path that still climbs with `..` towards a protected name
  # is blocked outright.
  # Each substitution only fires when there is something to collapse, so the
  # `ta` loop ends once the path is normal (a bare `/+` would loop forever).
  home_paths="$(printf '%s' "$unquoted" \
    | sed -E ':a
s#//+#/#g
s#/\./#/#g
s#/[^/[:space:]]+/\.\./#/#
ta')"
  # A glob or brace in a home-anchored path lets the shell spell a protected
  # name the matcher cannot see (`~/.git-hoo*`, `~/.local/bin/git{leaks,x}`),
  # so a glob in the first component under home, or anywhere below the
  # directories that hold protected files, is blocked as well.
  # shellcheck disable=SC2016 # $HOME and $XDG_* are literal pattern characters
  if printf '%s' "$home_paths" \
      | grep -Eq '(^|[^[:alnum:]_./-])(~[[:alnum:]_.-]*|\$HOME|\$\{HOME\}|/home/[^/]+|/Users/[^/]+|/root)/(\.git-hooks|\.gitconfig\.local|\.gitconfig|\.config/git|\.local/bin/(gitleaks|semgrep|osv-scanner|pre-commit)|\.local/share/pipx/venvs/(semgrep|pre-commit)|\.local/share/git-hooks|\.claude/hooks|\.claude/settings\.json|\.claude/settings\.local\.json|\.codex/hooks|\.codex/config\.toml|dotfiles/bin/dotfiles/(\.git-hooks|\.gitconfig|\.claude/hooks))(/|[[:space:]|;&()<>{}:,]|$)' \
      || printf '%s' "$home_paths" \
      | grep -Eq '(^|[^[:alnum:]_./-])(~[[:alnum:]_.-]*|\$HOME|\$\{HOME\}|/home/[^/]+|/Users/[^/]+|/root)/([^/[:space:]]*[]*?[{]|(\.local|\.claude|\.codex|\.config|dotfiles/bin)/[^[:space:]]*[]*?[{])' \
      || printf '%s' "$home_paths" \
      | grep -Eq '(^|[^[:alnum:]_./-])(\$XDG_DATA_HOME|\$\{XDG_DATA_HOME\})/git-hooks(/|[[:space:]|;&()<>{}:,]|$)' \
      || printf '%s' "$home_paths" \
      | grep -Eq '(^|[^[:alnum:]_./-])(\$XDG_CONFIG_HOME|\$\{XDG_CONFIG_HOME\})/git(/|[[:space:]|;&()<>{}:,]|$)' \
      || printf '%s' "$unquoted" \
      | grep -Eq '(^|[^[:alnum:]_./-])(~[[:alnum:]_.-]*|\$HOME|\$\{HOME\}|/home|/Users|/root)/([^[:space:]]*/)?\.\./[^[:space:]]*(\.git-hooks|\.gitconfig|\.config/git|\.local/(bin|share)|\.claude/(hooks|settings)|\.codex/hooks|dotfiles/bin/dotfiles)'; then
    printf 'protected hook machinery path'; return 1
  fi

  # Agent settings (Rule C): a project's .claude/settings.json or
  # settings.local.json takes precedence over user settings and can switch
  # hooks off (`disableAllHooks`), so shell access to them is blocked wherever
  # they live, including glob spellings directly under .claude/.
  # Matched on the path-normalised form too (`.claude//settings.json`,
  # `.claude/./settings.json`), and a glob or brace inside a hidden directory
  # name (`.cla{u,}de/`, `.c*/`) is blocked because it can spell `.claude`.
  if printf '%s\n%s' "$unquoted" "$home_paths" \
      | grep -Eq '(^|/|[^[:alnum:]_-])\.claude/(settings[^[:space:]/]*|[^[:space:]/]*[]*?[{][^[:space:]/]*)([[:space:]|;&()<>{}:,]|$)' \
      || printf '%s' "$unquoted" \
      | grep -Eq '(^|/|[^[:alnum:]_.-])\.[^[:space:]/]*[]*?[{][^[:space:]/]*/' \
      || printf '%s' "$unquoted" \
      | grep -Eq '[]*?[{}$`()][^[:space:]]*/settings[^[:space:]/]*\.json'; then
    # The last pattern: a brace, glob, variable or substitution anywhere in a
    # path before settings*.json can spell `.claude` however it is written
    # (`{.claude,x}/`, `$d/` or `$d/./` with d=.claude), so it fails closed.
    printf 'agent settings file'; return 1
  fi

  # Global or system git config writes (Rule B): block git config commands with
  # --global or --system unless the invocation is a read (--get, --get-all,
  # --get-regexp, --list, -l, or get/list subcommands).
  # Best effort: compound commands are split on command delimiters (|;& and
  # grouping operators) so each command segment is evaluated independently.
  # Interpreters writing directly to git config files are not caught here.
  # git accepts unambiguous prefixes of long options, so `--glob` and `--sys`
  # select the global/system file too; read flags are matched only in full,
  # so an abbreviated read is blocked rather than an abbreviated write let
  # through.
  # The read exemption is fail-closed: the read flag (or get/list
  # subcommand) must sit among the options directly after `config`, and the
  # segment must have no redirection or comment, so `… user.name x # --get`
  # or `… 2> --get` cannot pass a write off as a read.
  # `$'…'` text has its quotes stripped above, which leaves `$git …` that the
  # per-segment matcher does not see as a git command, while the shell runs it
  # (e.g. via `bash -c $'…'`). Any such command touching global/system config
  # is blocked outright.
  case "$norm" in
    *"\$'"*)
      if printf '%s' "$unquoted" | grep -Eq 'config' \
          && printf '%s' "$unquoted" | grep -Eq '(^|[[:space:]])(--gl(o(b(a(l)?)?)?)?|--sy(s(t(e(m)?)?)?)?)([[:space:]]|$)'; then
        printf 'global git config write'; return 1
      fi
      ;;
  esac
  while IFS= read -r segment; do
    [ -z "$segment" ] && continue
    if printf '%s' "$segment" | grep -Eq '(^|[[:space:]])([[:alnum:]_./-]*\/)?git[[:space:]]([^|;&`]*[[:space:]])?config([[:space:]]|$)'; then
      if printf '%s' "$segment" | grep -Eq '(^|[[:space:]])(--gl(o(b(a(l)?)?)?)?|--sy(s(t(e(m)?)?)?)?)([[:space:]]|$)'; then
        # No exemption when the read could belong to a different invocation:
        # a second `config` in the segment, or a command that re-parses text
        # (`$'…'` escapes turn `\n` into a separator once quotes are gone,
        # `eval`, `sh -c`).
        case "$segment" in
          *'<'* | *'>'* | *'#'*) ;;
          *)
            if ! printf '%s' "$segment" | grep -Eq 'config([[:space:]].*)?[[:space:]]config([[:space:]]|$)' \
                && ! printf '%s' "$norm" | grep -Eq "\\\$'|(^|[^[:alnum:]_-])eval([[:space:]]|\$)|(^|[^[:alnum:]_-])(ba|z|da|k)?sh[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*-[[:alnum:]]*c" \
                && printf '%s' "$segment" | grep -Eq '(^|[[:space:]])([[:alnum:]_./-]*\/)?git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?config([[:space:]]+-[^[:space:]]+)*[[:space:]]+(--get|--get-all|--get-regexp|--list|-l|get|list)([[:space:]]|$)'; then
              continue
            fi
            ;;
        esac
        printf 'global git config write'; return 1
      fi
    fi
  done <<EOF
$(printf '%s\n' "$unquoted" | tr '|;&`(){}' '\n')
EOF

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
