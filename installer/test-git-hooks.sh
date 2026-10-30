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

export PATH="$MOCK_BIN:$SYSTEM_BIN"

# Set up mock tool stubs in MOCK_BIN
cat > "$MOCK_BIN/gitleaks" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/gitleaks.log"

if [ "${1:-}" = "git" ] && [ "${2:-}" = "--help" ]; then
  if [ -f "$TEST_DIR/gitleaks_flavor_legacy" ]; then
    exit 1
  fi
  exit 0
fi

if [ -f "$TEST_DIR/gitleaks_exit" ]; then
  exit "$(cat "$TEST_DIR/gitleaks_exit")"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/gitleaks"

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
check "gitleaks passed --staged flag" grep -q -- "--staged" "$TEST_DIR/gitleaks.log"
check "gitleaks passed --redact flag" grep -q -- "--redact" "$TEST_DIR/gitleaks.log"

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

echo "==> Testing gitleaks CLI flavour detection"
# 4.1 Modern flavour (gitleaks git --help succeeds)
r="$(create_repo)"
rm -f "$TEST_DIR/gitleaks_flavor_legacy" "$TEST_DIR/gitleaks.log"
(cd "$r" && echo "content modern" > file.txt && git add file.txt && git commit -m "test modern" >/dev/null 2>&1)
check "modern gitleaks flavour uses 'git --pre-commit --staged --redact'" \
  grep -q -- "git --pre-commit --staged --redact" "$TEST_DIR/gitleaks.log"

# 4.2 Legacy flavour (gitleaks git --help fails)
r="$(create_repo)"
touch "$TEST_DIR/gitleaks_flavor_legacy"
rm -f "$TEST_DIR/gitleaks.log"
(cd "$r" && echo "content legacy" > file.txt && git add file.txt && git commit -m "test legacy" >/dev/null 2>&1)
rm -f "$TEST_DIR/gitleaks_flavor_legacy"
check "legacy gitleaks flavour uses 'protect --staged --redact'" \
  grep -q -- "protect --staged --redact" "$TEST_DIR/gitleaks.log"

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

echo
if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST PASSED"
