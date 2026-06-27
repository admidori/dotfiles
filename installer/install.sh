#!/usr/bin/env bash
#
# Main installer: system packages -> oh-my-zsh -> plugins -> symlinks.
# Invoked by `make install`. Safe to re-run (idempotent).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "########################"
echo "#   INSTALL DOTFILES   #"
echo "########################"

# --- privilege helper --------------------------------------------------------
# Run package commands as root directly, otherwise via sudo. Never require the
# whole script to run as root (that would install dotfiles into /root).
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "ERROR: need root privileges or sudo to install system packages." >&2
  exit 1
fi

# --- system packages (Debian/Ubuntu) -----------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends \
    zsh tmux git curl ca-certificates locales vim \
    jq ripgrep fd-find fzf gh shellcheck direnv nodejs npm
else
  echo "WARN: apt-get not found; skipping system package install." >&2
fi

# --- oh-my-zsh (installed fresh; no longer vendored in this repo) -------------
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
if [ ! -d "$ZSH" ]; then
  echo "Installing oh-my-zsh into $ZSH ..."
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  echo "oh-my-zsh already present at $ZSH (skipping)."
fi

# --- custom plugins referenced by .zshrc --------------------------------------
ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  echo "Installing zsh-autosuggestions ..."
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

# --- CLI compatibility shims -------------------------------------------------
mkdir -p "$HOME/.local/bin"
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  ln -snf "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

# --- symlink the dotfiles -----------------------------------------------------
"$SCRIPT_DIR/link.sh"

echo "Done. Run 'exec zsh' (or restart your shell) to apply."
