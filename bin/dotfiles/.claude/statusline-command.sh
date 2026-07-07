#!/usr/bin/env bash
# Claude Code statusLine command.
#
# Mirrors the operator's zsh prompt (oh-my-zsh ZSH_THEME="eastwood"):
# git branch status in green (red "*" when dirty) followed by the
# home-relative working directory in cyan. No explicit PS1 was set in
# ~/.zshrc, so this reproduces the effective PROMPT from
# ~/.oh-my-zsh/themes/eastwood.zsh-theme instead.
#
# Beyond the eastwood prompt, a yellow "*|*" tree marker is appended
# inside the branch bracket when the cwd is a linked git worktree (i.e.
# git-dir != git-common-dir). This is intentional for the multi-pane
# workflow: each Claude works in its own task worktree, so the marker
# tells at a glance which panes are in a worktree versus the main repo.
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
		# Linked worktree marker: git-dir differs from git-common-dir only
		# in a linked worktree. Yellow "*|*" reopens green so the closing
		# bracket stays the branch color.
		wt=""
		gitdir="$(git -C "$cwd" --no-optional-locks rev-parse --git-dir 2>/dev/null || true)"
		commondir="$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null || true)"
		if [ -n "$gitdir" ] && [ "$gitdir" != "$commondir" ]; then
			wt="$(printf ' \033[33m*|*\033[0m\033[32m')"
		fi
		git_info="${dirty}$(printf '\033[32m[%s%s]\033[0m ' "$branch" "$wt")"
	fi
fi

display_path="${cwd/#$HOME/\~}"

printf '%s\033[36m[%s]\033[0m' "$git_info" "$display_path"
