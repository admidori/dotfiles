#!/usr/bin/env bash
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

echo "==> Running 'make install'"
make -C "$REPO_ROOT" install

echo "==> Verifying dotfile symlinks"
for f in .zshrc .zprofile .tmux.conf .tmux.d .vimrc .gitconfig .latexmkrc; do
  check "~/$f is a symlink" test -L "$HOME/$f"
done
check "~/.tmux.d/agy_usage.sh is executable" test -x "$HOME/.tmux.d/agy_usage.sh"
check "~/.claude/settings.json is a symlink" test -L "$HOME/.claude/settings.json"
check "~/.claude/hooks is a symlink" test -L "$HOME/.claude/hooks"
check "~/.claude/CLAUDE.md is a symlink" test -L "$HOME/.claude/CLAUDE.md"
check "~/.codex/config.toml is a symlink" test -L "$HOME/.codex/config.toml"
check "~/.codex/hooks is a symlink" test -L "$HOME/.codex/hooks"
check "~/.codex/AGENTS.md is a symlink" test -L "$HOME/.codex/AGENTS.md"
check "~/.gemini/AGENTS.md is a symlink" test -L "$HOME/.gemini/AGENTS.md"
check "~/.gemini/AGENTS.md resolves to a file" test -f "$HOME/.gemini/AGENTS.md"
check "~/.gemini/GEMINI.md is a symlink" test -L "$HOME/.gemini/GEMINI.md"

echo "==> Verifying oh-my-zsh was installed fresh (not vendored)"
check "~/.oh-my-zsh exists"            test -d "$HOME/.oh-my-zsh"
check "~/.oh-my-zsh is NOT a symlink"  test ! -L "$HOME/.oh-my-zsh"
check "zsh-autosuggestions installed"  test -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

echo "==> Verifying AI-native CLI tools"
for cmd in jq rg fd fzf gh shellcheck direnv node npm npx python3 pipx; do
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
