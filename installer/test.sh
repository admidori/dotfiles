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
for f in .zshenv .zshrc .tmux.conf .tmux.d .vimrc .gitconfig .latexmkrc; do
  check "~/$f is a symlink" test -L "$HOME/$f"
done
check "~/.tmux.d/agent-usage is executable" test -x "$HOME/.tmux.d/agent-usage"
check "~/.claude/settings.json is a real file (copy-once, not synced)" test -f "$HOME/.claude/settings.json"
check "~/.claude/settings.json is NOT a symlink" test ! -L "$HOME/.claude/settings.json"
check "~/.claude/settings.json seeded from the tracked template" \
  cmp -s "$HOME/.claude/settings.json" "$REPO_ROOT/bin/dotfiles/.claude/settings.json"
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
check "~/.claude/skills/clean is a symlink" test -L "$HOME/.claude/skills/clean"
check "~/.claude/skills/clean/SKILL.md resolves to a file" test -f "$HOME/.claude/skills/clean/SKILL.md"
check "~/.agents/skills/clean is a symlink" test -L "$HOME/.agents/skills/clean"
check "~/.agents/skills/clean/SKILL.md resolves to a file" test -f "$HOME/.agents/skills/clean/SKILL.md"
check "pre-existing third-party skill survives untouched" test -f "$HOME/.claude/skills/third-party-skill/SKILL.md"

echo "==> Verifying shared skills dir (one delegate skill for Claude and Codex)"
check "~/.agents/skills is NOT a symlink (merged dir)" test ! -L "$HOME/.agents/skills"
check "~/.agents/skills/delegate is a symlink" test -L "$HOME/.agents/skills/delegate"
check "~/.agents/skills/delegate/SKILL.md resolves to a file" test -f "$HOME/.agents/skills/delegate/SKILL.md"
check "~/.claude/skills/delegate/SKILL.md resolves to a file" test -f "$HOME/.claude/skills/delegate/SKILL.md"
check "delegate runner is executable" test -x "$HOME/.agents/skills/delegate/scripts/run-task.sh"

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
