#!/usr/bin/env bash
#
# shellcheck disable=SC2088
#
# End-to-end test of the installer. Designed to run inside the Debian
# container built from ./Dockerfile (see `make test`), but also runnable
# on any throwaway Debian/Ubuntu box.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail=0
check() {
  # check <description> <test-expression...>
  desc="$1"; shift
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

check_json() {
  # check_json <file> <jq-filter>
  local file="$1"
  local filter="$2"
  jq -e "$filter" "$file" >/dev/null 2>&1
}

echo "==> Seeding pre-existing (non-dotfiles) Claude skill/hook and Gemini config"
mkdir -p "$HOME/.claude/skills/third-party-skill"
echo "not managed by dotfiles" > "$HOME/.claude/skills/third-party-skill/SKILL.md"
mkdir -p "$HOME/.claude/hooks"
echo "// not managed by dotfiles" > "$HOME/.claude/hooks/third-party-hook.js"
mkdir -p "$HOME/.gemini/config/projects"
echo "local project data" > "$HOME/.gemini/config/projects/local.txt"

echo "==> Running 'make install'"
make -C "$REPO_ROOT" install

echo "==> Verifying dotfile symlinks"
for f in .zshenv .zshrc .tmux.conf .tmux.d .vimrc .gitconfig .latexmkrc .git-hooks; do
  check "~/$f is a symlink" test -L "$HOME/$f"
done
check "~/.tmux.d/agent-usage is executable" test -x "$HOME/.tmux.d/agent-usage"
check "~/.claude/settings.json is a real file (copy-once, not synced)" test -f "$HOME/.claude/settings.json"
check "~/.claude/settings.json is NOT a symlink" test ! -L "$HOME/.claude/settings.json"
check "~/.claude/settings.json seeded from the tracked template" \
  cmp -s "$HOME/.claude/settings.json" "$REPO_ROOT/bin/dotfiles/.claude/settings.json"
check "security-guidance plugin is enabled in Claude settings" \
  check_json "$HOME/.claude/settings.json" '.enabledPlugins["security-guidance@claude-plugins-official"] == true'
check "~/.claude/CLAUDE.md is a symlink" test -L "$HOME/.claude/CLAUDE.md"
check "~/.codex/config.toml is a real file (copy-once, not synced)" test -f "$HOME/.codex/config.toml"
check "~/.codex/config.toml is NOT a symlink" test ! -L "$HOME/.codex/config.toml"
check "~/.codex/config.toml seeded from the tracked template" \
  cmp -s "$HOME/.codex/config.toml" "$REPO_ROOT/bin/dotfiles/.codex/config.toml"
check "~/.codex/hooks is a symlink" test -L "$HOME/.codex/hooks"
check "~/.codex/AGENTS.md is a symlink" test -L "$HOME/.codex/AGENTS.md"
check "~/.codex/hooks/guard-rules.sh resolves to a file" test -f "$HOME/.codex/hooks/guard-rules.sh"
check "~/.gemini/AGENTS.md is a symlink" test -L "$HOME/.gemini/AGENTS.md"
check "~/.gemini/AGENTS.md resolves to a file" test -f "$HOME/.gemini/AGENTS.md"
check "~/.gemini/GEMINI.md is a symlink" test -L "$HOME/.gemini/GEMINI.md"
check "~/.gemini/config is NOT a symlink (merged dir)" test ! -L "$HOME/.gemini/config"
check "~/.gemini/config/mcp_config.json is a real file (copy-once, not synced)" test -f "$HOME/.gemini/config/mcp_config.json"
check "~/.gemini/config/mcp_config.json is NOT a symlink" test ! -L "$HOME/.gemini/config/mcp_config.json"
check "~/.gemini/config/mcp_config.json seeded from the tracked template" \
  cmp -s "$HOME/.gemini/config/mcp_config.json" "$REPO_ROOT/bin/dotfiles/.gemini/config/mcp_config.json"
check "mcp_config.json contains coder server declaration" \
  check_json "$HOME/.gemini/config/mcp_config.json" '.mcpServers.coder.command == "coder" and .mcpServers.coder.args == ["exp", "mcp", "server"]'
check "mcp_config.json contains colab server declaration" \
  check_json "$HOME/.gemini/config/mcp_config.json" '.mcpServers.colab.command == "uvx" and .mcpServers.colab.args == ["git+https://github.com/googlecolab/colab-mcp"]'

echo "==> Verifying merged skills dir (dotfiles + third-party content coexist)"
check "~/.claude/skills is NOT a symlink (merged dir)" test ! -L "$HOME/.claude/skills"
check "~/.claude/skills/cleanup is a symlink" test -L "$HOME/.claude/skills/cleanup"
check "~/.claude/skills/cleanup/SKILL.md resolves to a file" test -f "$HOME/.claude/skills/cleanup/SKILL.md"
check "~/.agents/skills/cleanup is a symlink" test -L "$HOME/.agents/skills/cleanup"
check "~/.agents/skills/cleanup/SKILL.md resolves to a file" test -f "$HOME/.agents/skills/cleanup/SKILL.md"
check "pre-existing third-party skill survives untouched" test -f "$HOME/.claude/skills/third-party-skill/SKILL.md"

echo "==> Verifying shared skills dir (one delegate skill for Claude and Codex)"
check "~/.agents/skills is NOT a symlink (merged dir)" test ! -L "$HOME/.agents/skills"
check "~/.agents/skills/delegate is a symlink" test -L "$HOME/.agents/skills/delegate"
check "~/.agents/skills/delegate/SKILL.md resolves to a file" test -f "$HOME/.agents/skills/delegate/SKILL.md"
check "~/.claude/skills/delegate/SKILL.md resolves to a file" test -f "$HOME/.claude/skills/delegate/SKILL.md"
check "delegate runner is executable" test -x "$HOME/.agents/skills/delegate/scripts/run-task.sh"
check "delegate compute validator is executable" test -x "$HOME/.agents/skills/delegate/scripts/validate-compute.sh"
check "delegate compute test runner is executable" test -x "$HOME/.agents/skills/delegate/scripts/test-compute.sh"
check "delegate compute template exists" test -f "$HOME/.agents/skills/delegate/templates/compute.json"
check "delegate compute colab template exists" test -f "$HOME/.agents/skills/delegate/templates/compute-colab.json"
check "delegate compute test suite passes" "$HOME/.agents/skills/delegate/scripts/test-compute.sh"
check "delegate lifecycle test suite passes" "$HOME/.agents/skills/delegate/scripts/test-lifecycle.sh"

echo "==> Verifying merged hooks dir (dotfiles + third-party content coexist)"
check "~/.claude/hooks is NOT a symlink (merged dir)" test ! -L "$HOME/.claude/hooks"
check "~/.claude/hooks/bash-guard.sh is a symlink" test -L "$HOME/.claude/hooks/bash-guard.sh"
check "~/.claude/hooks/guard-rules.sh is a symlink" test -L "$HOME/.claude/hooks/guard-rules.sh"
check "pre-existing third-party hook survives untouched" test -f "$HOME/.claude/hooks/third-party-hook.js"

echo "==> Verifying merged Gemini config dir (dotfiles + machine-local content coexist)"
check "pre-existing Gemini config survives install" test -f "$HOME/.gemini/config/projects/local.txt"

echo "==> Verifying copy-once config survives a second install untouched"
printf '\n[projects."/fake/local/project"]\ntrust_level = "trusted"\n' >> "$HOME/.codex/config.toml"
jq '.mcpServers["local-custom"] = {"command": "custom-cmd"}' "$HOME/.gemini/config/mcp_config.json" > "$HOME/.gemini/config/mcp_config.json.tmp" && mv "$HOME/.gemini/config/mcp_config.json.tmp" "$HOME/.gemini/config/mcp_config.json"
make -C "$REPO_ROOT" link
check "locally-appended trust entry survives re-running the installer" \
  grep -q "fake/local/project" "$HOME/.codex/config.toml"
check "tracked config.toml itself was not touched" \
  not grep -q "fake/local/project" "$REPO_ROOT/bin/dotfiles/.codex/config.toml"
check "~/.claude/settings.json is still a real file after re-install" \
  test ! -L "$HOME/.claude/settings.json"
check "locally-modified mcp_config.json survives re-running the installer" \
  check_json "$HOME/.gemini/config/mcp_config.json" '.mcpServers["local-custom"].command == "custom-cmd"'
check "tracked mcp_config.json itself was not touched" \
  not check_json "$REPO_ROOT/bin/dotfiles/.gemini/config/mcp_config.json" '.mcpServers["local-custom"]'
check "~/.gemini/config/mcp_config.json is still a real file after re-install" \
  test ! -L "$HOME/.gemini/config/mcp_config.json"
check "pre-existing Gemini config survives re-linking" \
  test -f "$HOME/.gemini/config/projects/local.txt"

echo "==> Verifying oh-my-zsh was installed fresh (not vendored)"
check "~/.oh-my-zsh exists"            test -d "$HOME/.oh-my-zsh"
check "~/.oh-my-zsh is NOT a symlink"  test ! -L "$HOME/.oh-my-zsh"
check "zsh-autosuggestions installed"  test -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

echo "==> Verifying AI-native CLI tools"
export PATH="$HOME/.local/bin:$PATH"
for cmd in jq rg fd fzf gh shellcheck direnv node npm npx python3 pipx uv; do
  check "$cmd is available" command -v "$cmd"
done

echo "==> Verifying global git hooks"
check "pinned binary helper test suite passes" \
  bash "$REPO_ROOT/installer/test-pinned-tools.sh"
check "git-hooks test suite passes" \
  bash "$REPO_ROOT/installer/test-git-hooks.sh"
check "semgrep rules test suite passes" \
  bash "$REPO_ROOT/installer/test-semgrep-rules.sh"
check "guard rules test suite passes" \
  bash "$REPO_ROOT/installer/test-guard-rules.sh"

for cmd in gitleaks osv-scanner semgrep pre-commit; do
  check "$cmd is available" command -v "$cmd"
done

check_gitleaks_version() {
  test "$(gitleaks version 2>/dev/null || true)" = "8.30.1"
}
check "gitleaks version is 8.30.1" check_gitleaks_version

check_osv_version() {
  local ver
  ver="$(osv-scanner --version 2>&1 || true)"
  grep -F "2.7.0" <<< "$ver" >/dev/null
}
check "osv-scanner --version mentions 2.7.0" check_osv_version

check "global core.hooksPath is ~/.git-hooks" \
  test "$(git config --global --get core.hooksPath)" = "~/.git-hooks"
check "global core.hooksPath resolves to $HOME/.git-hooks" \
  test "$(git config --global --type=path --get core.hooksPath)" = "$HOME/.git-hooks"

pack_file="${XDG_DATA_HOME:-$HOME/.local/share}/git-hooks/semgrep/default.yml"
check "semgrep registry pack exists" test -f "$pack_file"
check_pack_first_line() {
  local first_line
  first_line="$(head -n 1 "$pack_file" 2>/dev/null || true)"
  case "$first_line" in
    rules:*) return 0 ;;
    *) return 1 ;;
  esac
}
check "semgrep registry pack starts with rules:" check_pack_first_line

check_commit_blocked() {
  local repo="$1"
  local label="$2"
  local stderr_file
  stderr_file="$(mktemp)"
  local status=0
  (
    cd "$repo"
    git commit -m "test commit"
  ) >/dev/null 2>"$stderr_file" || status=$?

  local blocked=1
  if [ "$status" -ne 0 ]; then
    local block_line
    block_line="$(grep -F "git-hooks: commit blocked:" "$stderr_file" || true)"
    if [ -n "$block_line" ] && grep -F "$label" <<< "$block_line" >/dev/null; then
      blocked=0
    fi
  fi
  if [ "$blocked" -ne 0 ]; then
    echo "Expected commit to be blocked for '$label', but status=$status and stderr:" >&2
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$blocked"
}

test_repo_clean="$(mktemp -d)"
git init -q "$test_repo_clean"
commit_clean() {
  local repo="$1"
  (
    cd "$repo"
    echo "x = 1" > a.py
    git add a.py
    git commit -m "clean commit"
  ) >/dev/null 2>&1
}
check "real hooks allow clean commit" commit_clean "$test_repo_clean"
rm -rf "$test_repo_clean"

test_repo_secret="$(mktemp -d)"
git init -q "$test_repo_secret"
token="ghp_$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 36)"
echo "token = '$token'" > "$test_repo_secret/secret.py"
(cd "$test_repo_secret" && git add secret.py)
check "real hooks block secret (gitleaks)" check_commit_blocked "$test_repo_secret" "gitleaks"
rm -rf "$test_repo_secret"

test_repo_code="$(mktemp -d)"
git init -q "$test_repo_code"
py_eval="ev""al"
printf '%s(input())\n' "$py_eval" > "$test_repo_code/insecure.py"
(cd "$test_repo_code" && git add insecure.py)
check "real hooks block insecure code (semgrep)" check_commit_blocked "$test_repo_code" "semgrep"
rm -rf "$test_repo_code"

test_repo_vuln="$(mktemp -d)"
git init -q "$test_repo_vuln"
req_pkg="req""uests"
echo "$req_pkg==2.19.0" > "$test_repo_vuln/requirements.txt"
(cd "$test_repo_vuln" && git add requirements.txt)
check "real hooks block vulnerable dependency (osv-scanner)" check_commit_blocked "$test_repo_vuln" "osv-scanner"
rm -rf "$test_repo_vuln"

echo "==> Verifying zsh starts and sources .zshrc cleanly"
# TERM_PROGRAM=vscode disables the tmux auto-start branch in .zshrc so the
# smoke test does not spawn an interactive tmux session.
check "zsh -i loads config" env TERM_PROGRAM=vscode zsh -ic 'exit 0'

echo
if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST PASSED"
