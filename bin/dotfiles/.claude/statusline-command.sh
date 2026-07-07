#!/usr/bin/env bash
# Claude Code statusLine command.
#
# Mirrors the operator's zsh prompt (oh-my-zsh ZSH_THEME="eastwood"):
# git branch status in green (red "*" when dirty) followed by the
# home-relative working directory in cyan. No explicit PS1 was set in
# ~/.zshrc, so this reproduces the effective PROMPT from
# ~/.oh-my-zsh/themes/eastwood.zsh-theme instead.
set -euo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.workspace.current_dir')"

git_info=""
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	branch="$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || \
		git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null || true)"
	if [ -n "$branch" ]; then
		dirty=""
		if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
			dirty="$(printf '\033[31m*\033[0m')"
		fi
		git_info="${dirty}$(printf '\033[32m[%s]\033[0m ' "$branch")"
	fi
fi

display_path="${cwd/#$HOME/\~}"

printf '%s\033[36m[%s]\033[0m' "$git_info" "$display_path"
