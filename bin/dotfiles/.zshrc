# If you come from bash you might have to change your $PATH.
# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time Oh My Zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="eastwood"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.

if [[ "$TERM_PROGRAM" != "vscode" ]]; then
	  ZSH_TMUX_AUTOSTART=true
else
			ZSH_TMUX_AUTOSTART=false
fi
export ZSH_TMUX_FIXTERM=true

plugins=(
git
tmux
zsh-autosuggestions
fzf
z
)

source $ZSH/oh-my-zsh.sh

# Keep $PATH entries unique no matter how many times they get appended below
# (also collapses any duplicates inherited from .zprofile).
typeset -U path PATH

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='nvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch $(uname -m)"

# Set personal aliases, overriding those provided by Oh My Zsh libs,
# plugins, and themes. Aliases can be placed here, though Oh My Zsh
# users are encouraged to define aliases within a top-level file in
# the $ZSH_CUSTOM folder, with .zsh extension. Examples:
# - $ZSH_CUSTOM/aliases.zsh
# - $ZSH_CUSTOM/macos.zsh
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"

# Golang
if [ -d "/usr/local/go/bin" ] ; then
	path=("/usr/local/go/bin" $path)
fi
[ -d "$HOME/.local/bin" ] && path=("$HOME/.local/bin" $path)
command -v uv >/dev/null 2>&1 && eval "$(uv generate-shell-completion zsh)"

# Key-agent
if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/ssh_auth_sock" ]; then
	ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/ssh_auth_sock"
	export SSH_AUTH_SOCK="$HOME/.ssh/ssh_auth_sock"
fi

alias tssh='eval $(tmux show-env -s SSH_AUTH_SOCK)'

_agy_required() {
	if command -v agy >/dev/null 2>&1; then
		return 0
	fi
	printf 'agy: command not found; ensure ~/.local/bin is in PATH\n' >&2
	return 127
}

agy-sandbox() {
	_agy_required || return
	command agy --sandbox "$@"
}

agy-print() {
	_agy_required || return
	command agy --print "$@"
}

agy-continue() {
	_agy_required || return
	command agy --continue "$@"
}

agy-models() {
	_agy_required || return
	command agy models "$@"
}

alias agys='agy-sandbox'
alias agyp='agy-print'
alias agyc='agy-continue'

[ -d "$HOME/bin" ] && path=("$HOME/bin" $path)

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# AI worktree helpers. Keep agent runs isolated by branch, directory, and tmux
# session so multiple CLI agents can work in parallel.
_ai_slug() {
	printf '%s' "$1" | sed -E 's#[^A-Za-z0-9._-]+#-#g; s#^-+##; s#-+$##'
}

aitmux() {
	if [ $# -lt 1 ]; then
		printf 'usage: aitmux <session-name> [directory]\n' >&2
		return 2
	fi
	local raw_name="$1"
	local dir="${2:-$PWD}"
	local session="ai-$(_ai_slug "$raw_name")"

	if ! command -v tmux >/dev/null 2>&1; then
		cd "$dir" || return
		return
	fi

	if tmux has-session -t "$session" 2>/dev/null; then
		tmux switch-client -t "$session" 2>/dev/null || tmux attach-session -t "$session"
		return
	fi

	tmux new-session -d -s "$session" -n agent -c "$dir"
	tmux new-window -t "$session:" -n shell -c "$dir"
	tmux select-window -t "$session:agent"
	tmux switch-client -t "$session" 2>/dev/null || tmux attach-session -t "$session"
}

aiwt() {
	if [ $# -lt 1 ]; then
		printf 'usage: aiwt <branch-name> [base-ref]\n' >&2
		return 2
	fi
	local branch="$1"
	local base="${2:-HEAD}"
	local repo_root repo_name parent slug worktree_dir

	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
		printf 'aiwt: not inside a git repository\n' >&2
		return 1
	}
	repo_name="$(basename "$repo_root")"
	parent="$(dirname "$repo_root")"
	slug="$(_ai_slug "$branch")"
	worktree_dir="$parent/${repo_name}-${slug}"

	if [ -e "$worktree_dir" ]; then
		# Distinct branches can slug to the same dir (e.g. feature/x and
		# feature-x). Refuse to reuse a worktree that is on a different branch
		# instead of silently opening a session on the wrong tree.
		local existing_branch
		existing_branch="$(git -C "$worktree_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
		if [ -n "$existing_branch" ] && [ "$existing_branch" != "$branch" ]; then
			printf 'aiwt: %s already exists on branch %s, not %s; refusing to reuse\n' \
				"$worktree_dir" "$existing_branch" "$branch" >&2
			return 1
		fi
		printf 'aiwt: using existing worktree path %s\n' "$worktree_dir" >&2
	else
		if git show-ref --verify --quiet "refs/heads/$branch"; then
			git worktree add "$worktree_dir" "$branch" || return
		else
			git worktree add -b "$branch" "$worktree_dir" "$base" || return
		fi
	fi

	aitmux "$branch" "$worktree_dir"
}

# >>> android-dev-env >>>
if [ -d "$HOME/Android/Sdk" ]; then
	export ANDROID_HOME="$HOME/Android/Sdk"
	export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
	export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$HOME/android-studio/bin"
fi
# <<< android-dev-env <<<

# n (Node.js version manager): install into a user-owned prefix so `n` works without sudo
export N_PREFIX="$HOME/.n"
export PATH="$N_PREFIX/bin:$PATH"

# === Open3D 3D window on WSLg (Wayland→X11/Xwayland fallback) ===
# Open3D legacy Visualizer は GLEW(=GLX前提) を使うため Wayland では落ちる。
# WAYLAND_DISPLAY を無効名にして libwayland 接続を失敗させ、GLFW を X11(Xwayland) へ
# fallback させると GLEW が通り 3D ウィンドウが出る。XDG_RUNTIME_DIR は本物のまま
# (音声/dbus 無傷)。MESA_LOADER_DRIVER_OVERRIDE=d3d12 で Ryzen 780M を使用。
# 注意: session 全体で Wayland 無効化 (全GUIは X11/Xwayland 経由になる)。
# WSL 環境でのみ適用し、非WSL環境の GUI には影響を与えない。
if [[ -n "$WSL_DISTRO_NAME" ]] || grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
	export WAYLAND_DISPLAY=invalid-force-x11
	export MESA_LOADER_DRIVER_OVERRIDE=d3d12
fi
# DISPLAY=:0 は WSLg が設定済。GPUで不具合時は `LIBGL_ALWAYS_SOFTWARE=1` を一時付与。
