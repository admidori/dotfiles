#!/usr/bin/env bash
#
# Offline, mock-based test suite for dotfiles global git hooks.
# Verifies pass-through dispatcher, core security pre-commit checks (conflict
# markers, file size, gitleaks fail-closed detection), and hook chaining.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/bin/dotfiles/.git-hooks"

fail=0
check() {
  # check <description> <test-expression...>
  local desc="$1"; shift
  if "$@"; then
    echo "  ok   : $desc"
  else
    echo "  FAIL : $desc"
    fail=1
  fi
}

not() {
  ! "$@"
}

echo "==> Setting up isolated test environment"
TEST_DIR="$(mktemp -d)"
export TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_HOME="$TEST_DIR/fake_home"
mkdir -p "$FAKE_HOME"
export HOME="$FAKE_HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig_global"

git config --file "$GIT_CONFIG_GLOBAL" user.name "Test Committer"
git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.com"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch "main"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$HOOKS_DIR"

# Build restricted PATH directory excluding security scanners and git-lfs
SYSTEM_BIN="$TEST_DIR/system_bin"
MOCK_BIN="$TEST_DIR/mock_bin"
mkdir -p "$SYSTEM_BIN" "$MOCK_BIN"

declare -A is_excluded_map=(
  [gitleaks]=1
  [semgrep]=1
  [shellcheck]=1
  [jq]=1
  [osv-scanner]=1
  [pre-commit]=1
  [git-lfs]=1
)

for bindir in /usr/local/bin /usr/bin; do
  [ -d "$bindir" ] || continue
  for binpath in "$bindir"/*; do
    [ -e "$binpath" ] || continue
    bname="${binpath##*/}"
    if [ -z "${is_excluded_map[$bname]:-}" ] && [ ! -e "$SYSTEM_BIN/$bname" ]; then
      ln -s "$binpath" "$SYSTEM_BIN/$bname"
    fi
  done
done

REAL_JQ="$(command -v jq)"
export PATH="$MOCK_BIN:$SYSTEM_BIN"

# jq is controlled via MOCK_BIN so jq absence can be tested
ln -s "$REAL_JQ" "$MOCK_BIN/jq"

# Set up mock tool stubs in MOCK_BIN
cat > "$MOCK_BIN/gitleaks" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/gitleaks.log"

if [ "${1:-}" = "dir" ] && [ "${2:-}" = "--help" ]; then
  if [ -f "$TEST_DIR/gitleaks_flavor_legacy" ]; then
    exit 1
  fi
  exit 0
fi

if [ "${1:-}" = "dir" ]; then
  find . -name .gitleaksignore -printf '%P\n' > "$TEST_DIR/gitleaks_ignores.log"
  find . -type f ! -name .semgrepignore -printf '%P\n' | sort > "$TEST_DIR/gitleaks_files.log"
  echo "${GITLEAKS_CONFIG:-unset} ${GITLEAKS_CONFIG_TOML:-unset}" > "$TEST_DIR/gitleaks_env.log"
fi

if [ -f "$TEST_DIR/gitleaks_exit" ]; then
  exit "$(cat "$TEST_DIR/gitleaks_exit")"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/gitleaks"

cat > "$MOCK_BIN/semgrep" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/semgrep.log"

target="${@: -1}"
if [ -d "$target" ]; then
  find "$target" -type f -exec grep -H ".*" {} + >> "$TEST_DIR/semgrep_target_contents.log" 2>/dev/null || true
  find "$target" -name .semgrepignore -printf '%P %s\n' > "$TEST_DIR/semgrep_ignores.log"
  find "$target" -type l -printf '%P\n' > "$TEST_DIR/semgrep_symlinks.log"
fi

if [ -f "$TEST_DIR/semgrep_exit" ]; then
  exit_code="$(cat "$TEST_DIR/semgrep_exit")"
  if [ -f "$TEST_DIR/semgrep_output" ]; then
    cat "$TEST_DIR/semgrep_output"
  fi
  exit "$exit_code"
fi

if [ -f "$TEST_DIR/semgrep_canned_json" ]; then
  sed "s|TARGET_DIR|$target|g" "$TEST_DIR/semgrep_canned_json"
  exit 0
fi

if [ -f "$TEST_DIR/semgrep_output" ]; then
  cat "$TEST_DIR/semgrep_output"
  exit 0
fi

echo '{"version":"1.183.0","results":[],"errors":[]}'
exit 0
EOF
chmod +x "$MOCK_BIN/semgrep"

cat > "$MOCK_BIN/shellcheck" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/shellcheck.log"

if [ -f "$TEST_DIR/shellcheck_exit" ]; then
  exit_code="$(cat "$TEST_DIR/shellcheck_exit")"
  if [ -f "$TEST_DIR/shellcheck_output" ]; then
    cat "$TEST_DIR/shellcheck_output"
  fi
  exit "$exit_code"
fi

if [ -f "$TEST_DIR/shellcheck_output" ]; then
  cat "$TEST_DIR/shellcheck_output"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/shellcheck"

cat > "$MOCK_BIN/git-lfs" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/git_lfs.log"
exit 0
EOF
chmod +x "$MOCK_BIN/git-lfs"

cat > "$MOCK_BIN/pre-commit" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/pre_commit.log"
if [ -f "$TEST_DIR/pre_commit_exit" ]; then
  exit "$(cat "$TEST_DIR/pre_commit_exit")"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/pre-commit"

cat > "$MOCK_BIN/osv-scanner" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/osv_scanner.log"

first_lockfile=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-L" ] || [ "$prev" = "--lockfile" ]; then
    [ -n "$first_lockfile" ] || first_lockfile="$arg"
    if [ -f "$arg" ]; then
      echo "=== $arg ===" >> "$TEST_DIR/osv_scanner_files.log"
      cat "$arg" >> "$TEST_DIR/osv_scanner_files.log"
    fi
  fi
  if [ "$prev" = "--config" ]; then
    wc -c < "$arg" > "$TEST_DIR/osv_scanner_config_size"
  fi
  prev="$arg"
done

target_dir=""
if [ -n "$first_lockfile" ]; then
  target_dir="$(dirname "$first_lockfile")"
fi

if [ -f "$TEST_DIR/osv_scanner_exit" ]; then
  exit_code="$(cat "$TEST_DIR/osv_scanner_exit")"
  if [ -f "$TEST_DIR/osv_scanner_canned_json" ]; then
    if [ -n "$target_dir" ]; then
      sed "s|TARGET_DIR|$target_dir|g" "$TEST_DIR/osv_scanner_canned_json"
    else
      cat "$TEST_DIR/osv_scanner_canned_json"
    fi
  elif [ -f "$TEST_DIR/osv_scanner_output" ]; then
    cat "$TEST_DIR/osv_scanner_output"
  fi
  exit "$exit_code"
fi

if [ -f "$TEST_DIR/osv_scanner_canned_json" ]; then
  if [ -n "$target_dir" ]; then
    sed "s|TARGET_DIR|$target_dir|g" "$TEST_DIR/osv_scanner_canned_json"
  else
    cat "$TEST_DIR/osv_scanner_canned_json"
  fi
  exit 0
fi

if [ -f "$TEST_DIR/osv_scanner_output" ]; then
  cat "$TEST_DIR/osv_scanner_output"
  exit 0
fi

echo '{"results":[]}'
exit 0
EOF
chmod +x "$MOCK_BIN/osv-scanner"

create_repo() {
  local repo_path
  repo_path="$(mktemp -d "$TEST_DIR/repo_XXXXXX")"
  git init -q "$repo_path"
  echo "$repo_path"
}

echo "==> Testing pass-through dispatcher and git-lfs fallback"
# 1.1 Local hook absent: exits 0
r="$(create_repo)"
check "pass-through exits 0 when repo-local hook is absent" \
  env -C "$r" "$HOOKS_DIR/pre-rebase"

# 1.2 Local hook runs with args and stdin, propagates exit status
r="$(create_repo)"
mkdir -p "$r/.git/hooks"
cat > "$r/.git/hooks/commit-msg" << 'EOF'
#!/usr/bin/env bash
echo "ARGS:$*" > hook_output.txt
cat >> hook_output.txt
exit 42
EOF
chmod +x "$r/.git/hooks/commit-msg"

status=0
(cd "$r" && printf 'stdin-payload\n' | "$HOOKS_DIR/commit-msg" foo bar) || status=$?
check "pass-through propagates non-zero exit status from local hook" [ "$status" -eq 42 ]
check "pass-through forwards args and stdin to local hook" \
  grep -q "ARGS:foo bar" "$r/hook_output.txt"
check "pass-through forwarded stdin payload" \
  grep -q "stdin-payload" "$r/hook_output.txt"

# 1.3 Linked worktree finds main repo hook
r="$(create_repo)"
(cd "$r" && echo "init" > init.txt && git add init.txt && git commit -m "init" >/dev/null 2>&1)
mkdir -p "$r/.git/hooks"
cat > "$r/.git/hooks/post-commit" << 'EOF'
#!/usr/bin/env bash
echo "main-hook-executed" > "$TEST_DIR/wt_hook_result.txt"
EOF
chmod +x "$r/.git/hooks/post-commit"
wt="$TEST_DIR/wt_linked"
(cd "$r" && git worktree add -q "$wt" -b wt-branch)
rm -f "$TEST_DIR/wt_hook_result.txt"
(cd "$wt" && "$HOOKS_DIR/post-commit")
check "pass-through in linked worktree finds main repo hook" \
  test -f "$TEST_DIR/wt_hook_result.txt"

# 1.4 git-lfs fallback when no local hook exists
r="$(create_repo)"
rm -f "$TEST_DIR/git_lfs.log"
(cd "$r" && "$HOOKS_DIR/post-commit" lfs-arg1 lfs-arg2)
check "git-lfs fallback invokes git lfs when local hook absent" \
  grep -q "post-commit lfs-arg1 lfs-arg2" "$TEST_DIR/git_lfs.log"

# 1.5 git-lfs fallback does not run when local hook exists
r="$(create_repo)"
mkdir -p "$r/.git/hooks"
cat > "$r/.git/hooks/post-commit" << 'EOF'
#!/usr/bin/env bash
echo "local-lfs-override" > local_lfs_override.txt
EOF
chmod +x "$r/.git/hooks/post-commit"
rm -f "$TEST_DIR/git_lfs.log"
(cd "$r" && "$HOOKS_DIR/post-commit")
check "local hook executed instead of git-lfs fallback" \
  test -f "$r/local_lfs_override.txt"
check "git-lfs stub was not called when local hook exists" \
  not test -f "$TEST_DIR/git_lfs.log"

echo "==> Testing pre-commit clean commits and gitleaks execution"
# 2.1 Clean commit passes and calls gitleaks with staged-scan args
r="$(create_repo)"
rm -f "$TEST_DIR/gitleaks.log"
(cd "$r" && echo "safe code" > file.txt && git add file.txt && git commit -m "feat: clean commit" >/dev/null 2>&1)
check "clean commit succeeds" test -f "$r/file.txt"
check "gitleaks called on clean commit" test -f "$TEST_DIR/gitleaks.log"
check "gitleaks scans the export dir in dir mode" grep -q -- "^dir \. " "$TEST_DIR/gitleaks.log"
check "gitleaks passed --redact flag" grep -q -- "--redact" "$TEST_DIR/gitleaks.log"
check "gitleaks passed --config override" grep -q -- "--config [^ ]*/config.toml" "$TEST_DIR/gitleaks.log"
check "gitleaks passed --ignore-gitleaks-allow" grep -q -- "--ignore-gitleaks-allow" "$TEST_DIR/gitleaks.log"
check "gitleaks passed --gitleaks-ignore-path override" grep -q -- "--gitleaks-ignore-path " "$TEST_DIR/gitleaks.log"
check "gitleaks sees the staged file" grep -qx "file.txt" "$TEST_DIR/gitleaks_files.log"

echo "==> Testing gitleaks failure modes and fail-closed behavior"
# 3.1 Blocks on gitleaks exit 1 (secrets found)
r="$(create_repo)"
echo "1" > "$TEST_DIR/gitleaks_exit"
status=0
(cd "$r" && echo "content" > file.txt && git add file.txt && git commit -m "leak commit" 2>"$TEST_DIR/err_leak.log") || status=$?
rm -f "$TEST_DIR/gitleaks_exit"
check "commit blocked on gitleaks exit 1" [ "$status" -ne 0 ]
check "error message reports secrets found" \
  grep -q "gitleaks found secrets in staged changes" "$TEST_DIR/err_leak.log"
check "summary mentions gitleaks failed" \
  grep -q "commit blocked: gitleaks" "$TEST_DIR/err_leak.log"

# 3.2 Blocks on gitleaks exit 2 (tool failure)
r="$(create_repo)"
echo "2" > "$TEST_DIR/gitleaks_exit"
status=0
(cd "$r" && echo "content" > file.txt && git add file.txt && git commit -m "error commit" 2>"$TEST_DIR/err_tool.log") || status=$?
rm -f "$TEST_DIR/gitleaks_exit"
check "commit blocked on gitleaks error exit 2" [ "$status" -ne 0 ]
check "error message reports gitleaks failure code" \
  grep -q "gitleaks failed with exit code 2" "$TEST_DIR/err_tool.log"
check "summary mentions gitleaks failed on tool error" \
  grep -q "commit blocked: gitleaks" "$TEST_DIR/err_tool.log"

# 3.3 Blocks when gitleaks is absent from PATH
r="$(create_repo)"
mv "$MOCK_BIN/gitleaks" "$MOCK_BIN/gitleaks.bak"
status=0
(cd "$r" && echo "content" > file.txt && git add file.txt && git commit -m "absent commit" 2>"$TEST_DIR/err_absent.log") || status=$?
mv "$MOCK_BIN/gitleaks.bak" "$MOCK_BIN/gitleaks"
check "commit blocked when gitleaks absent from PATH" [ "$status" -ne 0 ]
check "error message directs user to make install" \
  grep -q "run 'make install' in the dotfiles repo" "$TEST_DIR/err_absent.log"
check "summary mentions gitleaks failed when absent" \
  grep -q "commit blocked: gitleaks" "$TEST_DIR/err_absent.log"

echo "==> Testing gitleaks version requirement and ignore overrides"
# 4.1 gitleaks without the 'dir' command (older than 8.19) fails closed
r="$(create_repo)"
touch "$TEST_DIR/gitleaks_flavor_legacy"
rm -f "$TEST_DIR/gitleaks.log"
status=0
(cd "$r" && echo "content legacy" > file.txt && git add file.txt && git commit -m "test legacy" >/dev/null 2>"$TEST_DIR/err_legacy.log") || status=$?
rm -f "$TEST_DIR/gitleaks_flavor_legacy"
check "commit blocked when gitleaks lacks 'dir'" [ "$status" -ne 0 ]
check "old gitleaks message directs user to make install" \
  grep -q "gitleaks is too old" "$TEST_DIR/err_legacy.log"
check "old gitleaks is never asked to scan" \
  not grep -q -- "^dir \. " "$TEST_DIR/gitleaks.log"

# 4.2 A staged .gitleaksignore never reaches the scan, at the root or nested
r="$(create_repo)"
mkdir -p "$r/sub"
echo "file.txt:generic-api-key:1" > "$r/.gitleaksignore"
echo "file.txt:generic-api-key:1" > "$r/sub/.gitleaksignore"
echo "content" > "$r/file.txt"
(cd "$r" && git add .gitleaksignore sub file.txt && git commit -m "gitleaksignore" >/dev/null 2>&1) || true
check "no .gitleaksignore reaches gitleaks" [ ! -s "$TEST_DIR/gitleaks_ignores.log" ]

# 4.3 GITLEAKS_CONFIG from the environment is dropped
r="$(create_repo)"
echo "content" > "$r/file.txt"
(cd "$r" && git add file.txt && GITLEAKS_CONFIG=/x GITLEAKS_CONFIG_TOML=y git commit -m "env config" >/dev/null 2>&1) || true
check "GITLEAKS_CONFIG and GITLEAKS_CONFIG_TOML are unset for gitleaks" \
  [ "$(cat "$TEST_DIR/gitleaks_env.log")" = "unset unset" ]

# 4.4 Scanner temp dirs are cleaned up
check "gitleaks work dir removed" \
  not compgen -G "${TMPDIR:-/tmp}/git-hooks-gitleaks.*"

echo "==> Testing conflict markers check"
m_left="<"
m7_left="${m_left}${m_left}${m_left}${m_left}${m_left}${m_left}${m_left}"
m_right=">"
m7_right="${m_right}${m_right}${m_right}${m_right}${m_right}${m_right}${m_right}"

# 5.1 Staged conflict marker blocks commit
r="$(create_repo)"
printf '%s HEAD\ncode\n%s main\n' "$m7_left" "$m7_right" > "$r/conflict.txt"
(cd "$r" && git add conflict.txt)
status=0
(cd "$r" && git commit -m "conflict commit" 2>"$TEST_DIR/err_cm.log") || status=$?
check "commit blocked when staged file has conflict markers" [ "$status" -ne 0 ]
check "error message identifies file with conflict markers" \
  grep -q "conflict markers found in: conflict.txt" "$TEST_DIR/err_cm.log"
check "summary mentions conflict markers" \
  grep -q "commit blocked: conflict markers" "$TEST_DIR/err_cm.log"

# 5.2 Lone ======= allowed (markdown/rst heading)
r="$(create_repo)"
printf 'Heading 1\n=======\nParagraph text.\n' > "$r/doc.md"
(cd "$r" && git add doc.md)
status=0
(cd "$r" && git commit -m "heading commit" >/dev/null 2>&1) || status=$?
check "lone ======= allowed as heading underline" [ "$status" -eq 0 ]

# 5.3 Working tree conflict marker allowed if not staged in index
r="$(create_repo)"
printf 'staged clean line\n' > "$r/clean_index.txt"
(cd "$r" && git add clean_index.txt)
printf '%s HEAD\nunstaged marker\n' "$m7_left" >> "$r/clean_index.txt"
status=0
(cd "$r" && git commit -m "unstaged marker commit" >/dev/null 2>&1) || status=$?
check "working tree conflict marker allowed when index is clean" [ "$status" -eq 0 ]

# 5.4 Marker at the top of a diff larger than a pipe buffer still blocks
r="$(create_repo)"
{ printf '%s HEAD\n' "$m7_left"; seq 1 20000; } > "$r/big_conflict.txt"
(cd "$r" && git add big_conflict.txt)
status=0
(cd "$r" && git commit -m "big conflict commit" >/dev/null 2>&1) || status=$?
check "conflict marker early in a large diff blocks commit" [ "$status" -ne 0 ]

echo "==> Testing file size limit check (5 MiB = 5242880 bytes)"
# 6.1 Exactly 5242880 bytes allowed
r="$(create_repo)"
dd if=/dev/zero of="$r/exact_5m.dat" bs=1024 count=5120 status=none
(cd "$r" && git add exact_5m.dat)
status=0
(cd "$r" && git commit -m "exact 5m commit" >/dev/null 2>&1) || status=$?
check "file of exactly 5 MiB is allowed" [ "$status" -eq 0 ]

# 6.2 5242881 bytes (> 5 MiB) blocked
r="$(create_repo)"
dd if=/dev/zero of="$r/over_5m.dat" bs=1024 count=5120 status=none
printf 'x' >> "$r/over_5m.dat"
(cd "$r" && git add over_5m.dat)
status=0
(cd "$r" && git commit -m "over 5m commit" 2>"$TEST_DIR/err_size.log") || status=$?
check "file exceeding 5 MiB is blocked" [ "$status" -ne 0 ]
check "error message reports file exceeds 5 MiB limit" \
  grep -q "exceeds 5 MiB limit" "$TEST_DIR/err_size.log"
check "summary mentions oversized files" \
  grep -q "commit blocked: oversized files" "$TEST_DIR/err_size.log"

echo "==> Testing pre-commit chaining behavior"
# 7.1 Chains to repo-local pre-commit hook (propagating failure)
r="$(create_repo)"
mkdir -p "$r/.git/hooks"
cat > "$r/.git/hooks/pre-commit" << 'EOF'
#!/usr/bin/env bash
echo "local-pre-commit-ran" > local_pre_commit.log
exit 77
EOF
chmod +x "$r/.git/hooks/pre-commit"
echo "clean" > "$r/clean.txt"
(cd "$r" && git add clean.txt)

hook_status=0
(cd "$r" && "$HOOKS_DIR/pre-commit") || hook_status=$?
check "chains to local pre-commit hook and propagates exit status" [ "$hook_status" -eq 77 ]

commit_status=0
(cd "$r" && git commit -m "chain test" >/dev/null 2>&1) || commit_status=$?
check "git commit blocked by local pre-commit failure" [ "$commit_status" -ne 0 ]
check "local pre-commit hook was executed" test -f "$r/local_pre_commit.log"

# 7.2 Security checks run before chaining (failing check prevents local hook execution)
r="$(create_repo)"
mkdir -p "$r/.git/hooks"
cat > "$r/.git/hooks/pre-commit" << 'EOF'
#!/usr/bin/env bash
echo "should-not-run" > "$TEST_DIR/should_not_run.log"
exit 0
EOF
chmod +x "$r/.git/hooks/pre-commit"
echo "1" > "$TEST_DIR/gitleaks_exit"
rm -f "$TEST_DIR/should_not_run.log"
echo "clean" > "$r/clean.txt"
(cd "$r" && git add clean.txt)
status=0
(cd "$r" && git commit -m "failing security check" 2>/dev/null) || status=$?
rm -f "$TEST_DIR/gitleaks_exit"
check "security check failure blocks commit before chaining" [ "$status" -ne 0 ]
check "local hook does not run when security check fails" \
  not test -f "$TEST_DIR/should_not_run.log"

# 7.3a Without the local opt-in, .pre-commit-config.yaml alone is not run
r="$(create_repo)"
touch "$r/.pre-commit-config.yaml"
rm -f "$TEST_DIR/pre_commit.log"
echo "clean" > "$r/clean.txt"
(cd "$r" && git add clean.txt .pre-commit-config.yaml)
status=0
(cd "$r" && git commit -m "pre-commit no opt-in" >/dev/null 2>"$TEST_DIR/err_pc_optin.log") || status=$?
check "commit allowed without pre-commit opt-in" [ "$status" -eq 0 ]
check "pre-commit framework not invoked without opt-in" \
  not test -f "$TEST_DIR/pre_commit.log"
check "hint printed explaining the opt-in" \
  grep -q "hooks.preCommitFramework true" "$TEST_DIR/err_pc_optin.log"

# 7.3 Runs pre-commit run when opted in and tool is available
r="$(create_repo)"
git -C "$r" config --local hooks.preCommitFramework true
touch "$r/.pre-commit-config.yaml"
rm -f "$TEST_DIR/pre_commit.log"
echo "clean" > "$r/clean.txt"
(cd "$r" && git add clean.txt .pre-commit-config.yaml)
status=0
(cd "$r" && git commit -m "pre-commit yaml test" >/dev/null 2>&1) || status=$?
check "commit succeeds and chains to pre-commit run" [ "$status" -eq 0 ]
check "pre-commit framework invoked with run" \
  grep -q "run" "$TEST_DIR/pre_commit.log"

# 7.4 Warns but allows commit when opted in and the tool is absent
r="$(create_repo)"
git -C "$r" config --local hooks.preCommitFramework true
touch "$r/.pre-commit-config.yaml"
mv "$MOCK_BIN/pre-commit" "$MOCK_BIN/pre-commit.bak"
echo "clean" > "$r/clean.txt"
(cd "$r" && git add clean.txt .pre-commit-config.yaml)
status=0
(cd "$r" && git commit -m "pre-commit absent test" >/dev/null 2>"$TEST_DIR/err_pc_absent.log") || status=$?
mv "$MOCK_BIN/pre-commit.bak" "$MOCK_BIN/pre-commit"
check "commit allowed when pre-commit tool is absent" [ "$status" -eq 0 ]
check "warning emitted when pre-commit tool is absent" \
  grep -q "warning: .pre-commit-config.yaml found but pre-commit is not installed" "$TEST_DIR/err_pc_absent.log"

echo "==> Testing self-recursion guard"
# 8.1 Local pre-commit hook symlinked to global hook does not self-recurse
r="$(create_repo)"
mkdir -p "$r/.git/hooks"
ln -s "$HOOKS_DIR/pre-commit" "$r/.git/hooks/pre-commit"
echo "clean" > "$r/clean.txt"
(cd "$r" && git add clean.txt)
status=0
(cd "$r" && git commit -m "self-recursion test" >/dev/null 2>&1) || status=$?
check "self-recursion guarded on pre-commit" [ "$status" -eq 0 ]

# 8.2 Local post-commit hook symlinked to global hook does not self-recurse
r="$(create_repo)"
mkdir -p "$r/.git/hooks"
ln -s "$HOOKS_DIR/post-commit" "$r/.git/hooks/post-commit"
status=0
(cd "$r" && "$HOOKS_DIR/post-commit") || status=$?
check "self-recursion guarded on passthrough" [ "$status" -eq 0 ]

echo "==> Testing semgrep security scanner and fail-closed behavior"
# 9.1 semgrep JSON with an ERROR result blocks commit and reports repo-relative path
r="$(create_repo)"
cat > "$TEST_DIR/semgrep_canned_json" << 'EOF'
{
  "version": "1.183.0",
  "results": [
    {
      "check_id": "ai-python-eval-exec",
      "path": "TARGET_DIR/app/server.py",
      "start": {"line": 15, "col": 1},
      "extra": {
        "severity": "ERROR",
        "message": "Dangerous eval usage\nDo not use eval"
      }
    }
  ],
  "errors": []
}
EOF
mkdir -p "$r/app"
echo "eval(user_code)" > "$r/app/server.py"
(cd "$r" && git add app/server.py)
status=0
(cd "$r" && git commit -m "error finding commit" >/dev/null 2>"$TEST_DIR/err_semgrep_error.log") || status=$?
rm -f "$TEST_DIR/semgrep_canned_json"
check "commit blocked on semgrep ERROR finding" [ "$status" -ne 0 ]
check "finding reported with repo-relative path (no temp prefix)" \
  grep -q "ERROR app/server.py:15 ai-python-eval-exec: Dangerous eval usage" "$TEST_DIR/err_semgrep_error.log"
check "finding path does not leak temp directory" \
  not grep -q "git-hooks-staged" "$TEST_DIR/err_semgrep_error.log"
check "summary mentions semgrep blocked commit" \
  grep -q "commit blocked: semgrep" "$TEST_DIR/err_semgrep_error.log"

# 9.2 WARNING-only result allows commit but prints finding
r="$(create_repo)"
cat > "$TEST_DIR/semgrep_canned_json" << 'EOF'
{
  "version": "1.183.0",
  "results": [
    {
      "check_id": "ai-python-pickle-load",
      "path": "TARGET_DIR/utils.py",
      "start": {"line": 42, "col": 5},
      "extra": {
        "severity": "WARNING",
        "message": "Insecure pickle deserialization"
      }
    }
  ],
  "errors": []
}
EOF
echo "pickle.load(f)" > "$r/utils.py"
(cd "$r" && git add utils.py)
status=0
(cd "$r" && git commit -m "warning commit" >/dev/null 2>"$TEST_DIR/err_semgrep_warn.log") || status=$?
rm -f "$TEST_DIR/semgrep_canned_json"
check "commit allowed with semgrep WARNING findings" [ "$status" -eq 0 ]
check "warning finding printed to output" \
  grep -q "WARNING utils.py:42 ai-python-pickle-load: Insecure pickle deserialization" "$TEST_DIR/err_semgrep_warn.log"

# 9.3 semgrep absent from PATH blocks commit
r="$(create_repo)"
mv "$MOCK_BIN/semgrep" "$MOCK_BIN/semgrep.bak"
echo "clean" > "$r/clean.py"
(cd "$r" && git add clean.py)
status=0
(cd "$r" && git commit -m "absent semgrep commit" >/dev/null 2>"$TEST_DIR/err_semgrep_absent.log") || status=$?
mv "$MOCK_BIN/semgrep.bak" "$MOCK_BIN/semgrep"
check "commit blocked when semgrep absent from PATH" [ "$status" -ne 0 ]
check "semgrep absent directs user to make install" \
  grep -q "semgrep is not installed or not on PATH; run 'make install' in the dotfiles repo" "$TEST_DIR/err_semgrep_absent.log"
check "summary mentions semgrep failed when absent" \
  grep -q "commit blocked: semgrep" "$TEST_DIR/err_semgrep_absent.log"

# 9.3b jq absent from PATH blocks commit
r="$(create_repo)"
mv "$MOCK_BIN/jq" "$MOCK_BIN/jq.bak"
echo "clean" > "$r/clean.py"
(cd "$r" && git add clean.py)
status=0
(cd "$r" && git commit -m "absent jq commit" >/dev/null 2>"$TEST_DIR/err_jq_absent.log") || status=$?
mv "$MOCK_BIN/jq.bak" "$MOCK_BIN/jq"
check "commit blocked when jq absent from PATH" [ "$status" -ne 0 ]
check "jq absent directs user to make install" \
  grep -q "jq is not installed or not on PATH; run 'make install' in the dotfiles repo" "$TEST_DIR/err_jq_absent.log"
check "summary mentions semgrep failed when jq absent" \
  grep -q "commit blocked: semgrep" "$TEST_DIR/err_jq_absent.log"

# 9.4 semgrep exits non-zero with unparseable output blocks commit
r="$(create_repo)"
echo "2" > "$TEST_DIR/semgrep_exit"
echo "Fatal: syntax error in config" > "$TEST_DIR/semgrep_output"
echo "clean" > "$r/clean.py"
(cd "$r" && git add clean.py)
status=0
(cd "$r" && git commit -m "broken semgrep commit" >/dev/null 2>"$TEST_DIR/err_semgrep_broken.log") || status=$?
rm -f "$TEST_DIR/semgrep_exit" "$TEST_DIR/semgrep_output"
check "commit blocked when semgrep exits non-zero with unparseable output" [ "$status" -ne 0 ]
check "error message reports semgrep failure code" \
  grep -q "semgrep failed with exit code 2" "$TEST_DIR/err_semgrep_broken.log"
check "summary mentions semgrep failed on error" \
  grep -q "commit blocked: semgrep" "$TEST_DIR/err_semgrep_broken.log"

# 9.5 JSON with only errors entries allows commit and prints note
r="$(create_repo)"
cat > "$TEST_DIR/semgrep_canned_json" << 'EOF'
{
  "version": "1.183.0",
  "results": [],
  "errors": [
    {
      "message": "Syntax error parsing file",
      "path": "TARGET_DIR/syntax_error.py"
    }
  ]
}
EOF
echo "def bad_syntax(" > "$r/syntax_error.py"
(cd "$r" && git add syntax_error.py)
status=0
(cd "$r" && git commit -m "parse error commit" >/dev/null 2>"$TEST_DIR/err_semgrep_parse_err.log") || status=$?
rm -f "$TEST_DIR/semgrep_canned_json"
check "commit allowed when semgrep reports file parse errors" [ "$status" -eq 0 ]
check "parse error note emitted" \
  grep -q "semgrep reported parse errors on some files" "$TEST_DIR/err_semgrep_parse_err.log"

# 9.6 semgrep invoked with offline args, never auto or p/
r="$(create_repo)"
rm -f "$TEST_DIR/semgrep.log"
echo "clean" > "$r/clean.py"
(cd "$r" && git add clean.py && git commit -m "offline args test" >/dev/null 2>&1)
check "semgrep invoked with --metrics=off" \
  grep -q -- "--metrics=off" "$TEST_DIR/semgrep.log"
check "semgrep invoked with --disable-version-check" \
  grep -q -- "--disable-version-check" "$TEST_DIR/semgrep.log"
check "semgrep passed tracked ai-insecure.yml rules" \
  grep -q -- "bin/dotfiles/.git-hooks/semgrep/ai-insecure.yml" "$TEST_DIR/semgrep.log"
check "semgrep never uses --config auto" \
  not grep -q -- "--config auto" "$TEST_DIR/semgrep.log"
check "semgrep never uses p/ registry pack" \
  not grep -q -E '\bp/' "$TEST_DIR/semgrep.log"

# 9.7 registry pack used only when default.yml exists
r="$(create_repo)"
rm -f "$TEST_DIR/semgrep.log"
echo "clean" > "$r/clean.py"
(cd "$r" && git add clean.py && git commit -m "no default pack" >/dev/null 2>&1)
check "registry pack not passed when default.yml absent" \
  not grep -q "default.yml" "$TEST_DIR/semgrep.log"

pack_dir="$FAKE_HOME/.local/share/git-hooks/semgrep"
mkdir -p "$pack_dir"
touch "$pack_dir/default.yml"
rm -f "$TEST_DIR/semgrep.log"
(cd "$r" && echo "clean2" > clean.py && git add clean.py && git commit -m "with default pack" >/dev/null 2>&1)
check "registry pack passed when default.yml present" \
  grep -q -- "--config $pack_dir/default.yml" "$TEST_DIR/semgrep.log"
rm -rf "$pack_dir"

# 9.8 scanned file content is staged version, not unstaged working tree edit
r="$(create_repo)"
rm -f "$TEST_DIR/semgrep_target_contents.log"
echo "staged content alpha" > "$r/staged.py"
(cd "$r" && git add staged.py)
echo "unstaged working tree edit beta" > "$r/staged.py"
status=0
(cd "$r" && git commit -m "staged vs working tree" >/dev/null 2>&1) || status=$?
check "commit succeeds for staged index" [ "$status" -eq 0 ]
check "semgrep received staged content" \
  grep -q "staged content alpha" "$TEST_DIR/semgrep_target_contents.log"
check "semgrep did not receive unstaged working tree edit" \
  not grep -q "unstaged working tree edit beta" "$TEST_DIR/semgrep_target_contents.log"

# 9.9 deletion-only commit skips semgrep
r="$(create_repo)"
echo "initial" > "$r/initial.txt"
(cd "$r" && git add initial.txt && git commit -m "initial" >/dev/null 2>&1)
(cd "$r" && git rm initial.txt >/dev/null 2>&1)
rm -f "$TEST_DIR/semgrep.log"
status=0
(cd "$r" && git commit -m "deletion only" >/dev/null 2>&1) || status=$?
check "deletion-only commit succeeds" [ "$status" -eq 0 ]
check "semgrep not called on deletion-only commit" \
  not test -f "$TEST_DIR/semgrep.log"

# 9.10 Staged .semgrepignore files cannot exempt anything; defaults are off
r="$(create_repo)"
mkdir -p "$r/sub"
echo "*" > "$r/.semgrepignore"
echo "*" > "$r/sub/.semgrepignore"
echo "x = 1" > "$r/sub/code.py"
(cd "$r" && git add .semgrepignore sub)
(cd "$r" && git commit -m "semgrepignore commit" >/dev/null 2>&1) || true
check "only an empty root .semgrepignore reaches semgrep" \
  [ "$(cat "$TEST_DIR/semgrep_ignores.log")" = ".semgrepignore 0" ]

# 9.11 A staged .semgrepignore symlink cannot truncate the file it points to
r="$(create_repo)"
outside="$TEST_DIR/outside_target"
echo "keep me" > "$outside"
ln -s "$outside" "$r/.semgrepignore"
echo "x = 1" > "$r/code.py"
(cd "$r" && git add .semgrepignore code.py)
(cd "$r" && git commit -m "semgrepignore symlink" >/dev/null 2>&1) || true
check "symlink target outside the repo is untouched" \
  [ "$(cat "$outside")" = "keep me" ]
check "only an empty root .semgrepignore reaches semgrep with a staged symlink" \
  [ "$(cat "$TEST_DIR/semgrep_ignores.log")" = ".semgrepignore 0" ]
check "no symlink is exported to scanners" \
  [ ! -s "$TEST_DIR/semgrep_symlinks.log" ]

# 9.12 semgrep scans files over its default 1 MB limit
check "semgrep invoked with --max-target-bytes 0" \
  grep -q -- "--max-target-bytes 0" "$TEST_DIR/semgrep.log"

# 9.13 Replacing a symlink with a regular file (type change) is scanned
r="$(create_repo)"
ln -s code.py "$r/linked.py"
echo "x = 1" > "$r/code.py"
(cd "$r" && git add linked.py code.py && git commit -m "add symlink" >/dev/null 2>&1)
rm "$r/linked.py"
echo "typechange_marker = 1" > "$r/linked.py"
(cd "$r" && git add linked.py)
check "type change is staged as T" \
  sh -c "cd '$r' && git diff --cached --name-status | grep -q '^T'"
(cd "$r" && git commit -m "replace symlink with file" >/dev/null 2>&1) || true
check "type-changed file content reaches semgrep" \
  grep -q "typechange_marker" "$TEST_DIR/semgrep_target_contents.log"

echo "==> Testing shellcheck execution (non-blocking)"
# 10.1 shellcheck called for .sh and extensionless bash shebang, not zsh shebang
r="$(create_repo)"
echo "echo hello" > "$r/test.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$r/exec_bash"
chmod +x "$r/exec_bash"
printf '#!/bin/zsh\necho hello\n' > "$r/exec_zsh"
chmod +x "$r/exec_zsh"
echo "echo plain text" > "$r/plain.txt"
(cd "$r" && git add test.sh exec_bash exec_zsh plain.txt)

echo "1" > "$TEST_DIR/shellcheck_exit"
echo "test.sh:1:1: note: Sample warning [SC2086]" > "$TEST_DIR/shellcheck_output"
rm -f "$TEST_DIR/shellcheck.log"

status=0
(cd "$r" && git commit -m "shellcheck test" >/dev/null 2>"$TEST_DIR/err_shellcheck.log") || status=$?
rm -f "$TEST_DIR/shellcheck_exit" "$TEST_DIR/shellcheck_output"

check "shellcheck non-zero exit does not block commit" [ "$status" -eq 0 ]
check "shellcheck targeted .sh file" \
  grep -q -- "-f gcc.*test.sh" "$TEST_DIR/shellcheck.log"
check "shellcheck targeted extensionless file with bash shebang" \
  grep -q -- "exec_bash" "$TEST_DIR/shellcheck.log"
check "shellcheck ignored file with zsh shebang" \
  not grep -q "exec_zsh" "$TEST_DIR/shellcheck.log"
check "shellcheck ignored plain text file" \
  not grep -q "plain.txt" "$TEST_DIR/shellcheck.log"
check "shellcheck non-blocking header printed" \
  grep -q "git-hooks: shellcheck warnings (not blocking):" "$TEST_DIR/err_shellcheck.log"
check "shellcheck warning output printed" \
  grep -q "test.sh:1:1: note: Sample warning" "$TEST_DIR/err_shellcheck.log"

echo "==> Testing osv-scanner lockfile dependency check"
# 11.1 Non-lockfile commit does not invoke osv-scanner
r="$(create_repo)"
rm -f "$TEST_DIR/osv_scanner.log"
echo "# Project" > "$r/README.md"
(cd "$r" && git add README.md && git commit -m "readme commit" >/dev/null 2>&1)
check "osv-scanner not called on non-lockfile commit" \
  not test -f "$TEST_DIR/osv_scanner.log"

# 11.2 Lockfile commit invokes osv-scanner with scan source, --format json, and -L
r="$(create_repo)"
rm -f "$TEST_DIR/osv_scanner.log"
echo "requests==2.28.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
status=0
(cd "$r" && git commit -m "add requirements" >/dev/null 2>&1) || status=$?
check "clean lockfile commit succeeds on exit 0" [ "$status" -eq 0 ]
check "osv-scanner invoked with scan source" \
  grep -q "scan source" "$TEST_DIR/osv_scanner.log"
check "osv-scanner invoked with --format json" \
  grep -q -- "--format json" "$TEST_DIR/osv_scanner.log"
check "osv-scanner passed -L pointing to lockfile" \
  grep -q -E -- '-L .*/requirements\.txt' "$TEST_DIR/osv_scanner.log"

# 11.3 Nested lockfile and pattern-matched requirements file trigger scan
r="$(create_repo)"
rm -f "$TEST_DIR/osv_scanner.log"
mkdir -p "$r/web"
echo '{"name": "web"}' > "$r/web/package-lock.json"
echo "pytest==7.0.0" > "$r/requirements-dev.txt"
(cd "$r" && git add web/package-lock.json requirements-dev.txt)
status=0
(cd "$r" && git commit -m "nested and pattern lockfiles" >/dev/null 2>&1) || status=$?
check "nested lockfile and pattern requirements commit succeeds" [ "$status" -eq 0 ]
check "osv-scanner scanned nested web/package-lock.json" \
  grep -q -E -- '-L .*/web/package-lock\.json' "$TEST_DIR/osv_scanner.log"
check "osv-scanner scanned requirements-dev.txt" \
  grep -q -E -- '-L .*/requirements-dev\.txt' "$TEST_DIR/osv_scanner.log"

# 11.4 Single invocation for multiple staged lockfiles
check "single osv-scanner invocation for multiple lockfiles" \
  [ "$(wc -l < "$TEST_DIR/osv_scanner.log")" -eq 1 ]

# 11.5 Scans staged version, not unstaged working tree edit
r="$(create_repo)"
rm -f "$TEST_DIR/osv_scanner_files.log"
echo "staged_pkg==1.0.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
echo "unstaged_pkg==2.0.0" > "$r/requirements.txt"
status=0
(cd "$r" && git commit -m "staged vs working tree lockfile" >/dev/null 2>&1) || status=$?
check "commit succeeds for staged lockfile" [ "$status" -eq 0 ]
check "osv-scanner inspected staged lockfile content" \
  grep -q "staged_pkg==1.0.0" "$TEST_DIR/osv_scanner_files.log"
check "osv-scanner did not receive unstaged working tree edit" \
  not grep -q "unstaged_pkg==2.0.0" "$TEST_DIR/osv_scanner_files.log"

# 11.6 Exit 1 with canned JSON blocks commit and prints formatted finding
r="$(create_repo)"
echo "1" > "$TEST_DIR/osv_scanner_exit"
cat > "$TEST_DIR/osv_scanner_canned_json" << 'EOF'
{
  "results": [
    {
      "source": {
        "path": "TARGET_DIR/package-lock.json",
        "type": "lockfile"
      },
      "packages": [
        {
          "package": {
            "name": "lodash",
            "version": "4.17.15",
            "ecosystem": "npm"
          },
          "vulnerabilities": [
            {"id": "GHSA-p6mc-m468-83gw"},
            {"id": "GHSA-35jh-r3h4-6jhm"},
            {"id": "GHSA-29mw-wpgm-hmr9"},
            {"id": "GHSA-x5rq-j2xg-h6px"},
            {"id": "GHSA-jf85-cpcp-j695"},
            {"id": "GHSA-fvqr-27wr-82fm"},
            {"id": "GHSA-4xc9-xhrj-v574"}
          ]
        }
      ]
    }
  ]
}
EOF
echo '{"name": "test"}' > "$r/package-lock.json"
(cd "$r" && git add package-lock.json)
status=0
(cd "$r" && git commit -m "vulnerable package commit" >/dev/null 2>"$TEST_DIR/err_osv_vuln.log") || status=$?
rm -f "$TEST_DIR/osv_scanner_exit" "$TEST_DIR/osv_scanner_canned_json"
check "commit blocked when osv-scanner exits 1 with vulnerabilities" [ "$status" -ne 0 ]
check "summary mentions osv-scanner blocked commit" \
  grep -q "commit blocked: osv-scanner" "$TEST_DIR/err_osv_vuln.log"
check "vulnerable package line contains package name, version, and ecosystem" \
  grep -q "vulnerable dependency lodash@4.17.15 (npm)" "$TEST_DIR/err_osv_vuln.log"
check "vulnerable package line contains repo-relative lockfile path" \
  grep -q "in package-lock.json:" "$TEST_DIR/err_osv_vuln.log"
check "vulnerable package line does not leak temp directory" \
  not grep -q "git-hooks-staged" "$TEST_DIR/err_osv_vuln.log"
check "vulnerability IDs truncated at 5 with ellipsis" \
  grep -q "GHSA-jf85-cpcp-j695, …" "$TEST_DIR/err_osv_vuln.log"
check "sixth ID is not listed in findings" \
  not grep -q "GHSA-fvqr-27wr-82fm" "$TEST_DIR/err_osv_vuln.log"

# 11.7 Exit 1 with unparseable output blocks commit with generic message
r="$(create_repo)"
echo "1" > "$TEST_DIR/osv_scanner_exit"
echo "internal error: unexpected EOF" > "$TEST_DIR/osv_scanner_output"
echo "requests==2.19.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
status=0
(cd "$r" && git commit -m "unparseable osv output" >/dev/null 2>"$TEST_DIR/err_osv_unparseable.log") || status=$?
rm -f "$TEST_DIR/osv_scanner_exit" "$TEST_DIR/osv_scanner_output"
check "commit blocked when osv-scanner exit 1 has unparseable output" [ "$status" -ne 0 ]
check "generic vulnerability message emitted on unparseable output" \
  grep -q "git-hooks: osv-scanner reported vulnerabilities in dependencies" "$TEST_DIR/err_osv_unparseable.log"
check "summary mentions osv-scanner blocked commit on unparseable output" \
  grep -q "commit blocked: osv-scanner" "$TEST_DIR/err_osv_unparseable.log"

# 11.8 Exit 1 with jq absent blocks commit with generic message
r="$(create_repo)"
echo "1" > "$TEST_DIR/osv_scanner_exit"
echo '{"results":[]}' > "$TEST_DIR/osv_scanner_output"
echo "requests==2.19.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
rm -f "$MOCK_BIN/jq"
status=0
(cd "$r" && git commit -m "jq absent osv test" >/dev/null 2>"$TEST_DIR/err_osv_nojq.log") || status=$?
ln -s "$REAL_JQ" "$MOCK_BIN/jq"
rm -f "$TEST_DIR/osv_scanner_exit" "$TEST_DIR/osv_scanner_output"
check "commit blocked on osv exit 1 when jq is absent" [ "$status" -ne 0 ]
check "generic vulnerability message emitted when jq is absent" \
  grep -q "git-hooks: osv-scanner reported vulnerabilities in dependencies" "$TEST_DIR/err_osv_nojq.log"

# 11.9 Exit 128 (no packages found) allows commit silently
r="$(create_repo)"
echo "128" > "$TEST_DIR/osv_scanner_exit"
echo "# empty lockfile" > "$r/Cargo.lock"
(cd "$r" && git add Cargo.lock)
status=0
(cd "$r" && git commit -m "empty cargo lockfile" >/dev/null 2>"$TEST_DIR/err_osv_128.log") || status=$?
rm -f "$TEST_DIR/osv_scanner_exit"
check "commit allowed silently when osv-scanner exits 128" [ "$status" -eq 0 ]
check "no warning or error emitted on exit 128" \
  not grep -q "git-hooks:" "$TEST_DIR/err_osv_128.log"

# 11.10 Exit 127 (error / network failure) allows commit with warning
r="$(create_repo)"
echo "127" > "$TEST_DIR/osv_scanner_exit"
echo "requests==2.28.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
status=0
(cd "$r" && git commit -m "offline commit test" >/dev/null 2>"$TEST_DIR/err_osv_127.log") || status=$?
rm -f "$TEST_DIR/osv_scanner_exit"
check "commit allowed when osv-scanner exits 127" [ "$status" -eq 0 ]
check "warning emitted on exit 127 with exit code and offline hint" \
  grep -q "could not check dependencies with osv-scanner (exit 127; offline?) — not blocking" "$TEST_DIR/err_osv_127.log"

# 11.11 Exit 124 (timeout) allows commit with warning
r="$(create_repo)"
echo "124" > "$TEST_DIR/osv_scanner_exit"
echo "requests==2.28.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
status=0
(cd "$r" && git commit -m "timeout commit test" >/dev/null 2>"$TEST_DIR/err_osv_124.log") || status=$?
rm -f "$TEST_DIR/osv_scanner_exit"
check "commit allowed when osv-scanner times out (exit 124)" [ "$status" -eq 0 ]
check "warning emitted on exit 124 with exit code and offline hint" \
  grep -q "could not check dependencies with osv-scanner (exit 124; offline?) — not blocking" "$TEST_DIR/err_osv_124.log"

# 11.12 osv-scanner not installed allows commit with warning
r="$(create_repo)"
mv "$MOCK_BIN/osv-scanner" "$MOCK_BIN/osv-scanner.bak"
echo "requests==2.28.0" > "$r/requirements.txt"
(cd "$r" && git add requirements.txt)
status=0
(cd "$r" && git commit -m "absent osv-scanner commit" >/dev/null 2>"$TEST_DIR/err_osv_absent.log") || status=$?
mv "$MOCK_BIN/osv-scanner.bak" "$MOCK_BIN/osv-scanner"
check "commit allowed when osv-scanner is absent" [ "$status" -eq 0 ]
check "osv-scanner absent directs user to make install" \
  grep -q "osv-scanner not installed; run 'make install' in the dotfiles repo — not blocking" "$TEST_DIR/err_osv_absent.log"

# 11.13 A staged osv-scanner.toml is overridden by an empty --config
r="$(create_repo)"
rm -f "$TEST_DIR/osv_scanner.log" "$TEST_DIR/osv_scanner_config_size"
echo "requests==2.28.0" > "$r/requirements.txt"
printf '[[IgnoredVulns]]\nid = "GHSA-test"\n' > "$r/osv-scanner.toml"
(cd "$r" && git add requirements.txt osv-scanner.toml && git commit -m "osv config" >/dev/null 2>&1)
check "osv-scanner invoked with --config" \
  grep -q -- "--config " "$TEST_DIR/osv_scanner.log"
check "osv-scanner config override is empty" \
  [ "$(cat "$TEST_DIR/osv_scanner_config_size" 2>/dev/null)" = "0" ]
check "osv-scanner config is not the staged osv-scanner.toml" \
  not grep -q -- "--config [^ ]*osv-scanner.toml" "$TEST_DIR/osv_scanner.log"

echo
if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST PASSED"
