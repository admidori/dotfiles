#!/usr/bin/env bash
#
# Main installer: system packages -> oh-my-zsh -> plugins -> symlinks.
# Invoked by `make install`. Safe to re-run (idempotent).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    jq ripgrep fd-find fzf gh shellcheck direnv \
    nodejs npm python3 python3-venv pipx
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
export PATH="$HOME/.local/bin:$PATH"
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  FDFIND_PATH="$(command -v fdfind)"
  ln -snf "$FDFIND_PATH" "$HOME/.local/bin/fd"
  $SUDO mkdir -p /usr/local/bin
  $SUDO ln -snf "$FDFIND_PATH" /usr/local/bin/fd
fi

# --- user-scoped developer CLIs ---------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    echo "Installing uv via pipx ..."
    pipx install uv
  else
    echo "WARN: pipx not found; skipping uv install." >&2
  fi
fi

# --- security scanners for the global git hooks -----------------------------
# shellcheck source=installer/pinned-tools.sh
. "$SCRIPT_DIR/pinned-tools.sh"

install_gitleaks "$HOME/.local/bin/gitleaks"
install_osv_scanner "$HOME/.local/bin/osv-scanner"

if ! command -v semgrep >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    echo "Installing semgrep via pipx ..."
    pipx install semgrep
  else
    echo "WARN: pipx not found; skipping semgrep install." >&2
  fi
fi

if ! command -v pre-commit >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    echo "Installing pre-commit via pipx ..."
    pipx install pre-commit
  else
    echo "WARN: pipx not found; skipping pre-commit install." >&2
  fi
fi

echo "Updating semgrep registry pack ..."
SEMGREP_PACK_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/git-hooks/semgrep"
SEMGREP_PACK_FILE="$SEMGREP_PACK_DIR/default.yml"
tmp_pack="$(mktemp "${TMPDIR:-/tmp}/semgrep-pack.XXXXXX")"
if curl -fsSL --retry 3 "https://semgrep.dev/c/p/security-audit" -o "$tmp_pack"; then
  first_line="$(head -n 1 "$tmp_pack" 2>/dev/null || true)"
  case "$first_line" in
    rules:*)
      mkdir -p "$SEMGREP_PACK_DIR"
      mv -f "$tmp_pack" "$SEMGREP_PACK_FILE"
      echo "Installed semgrep registry pack to $SEMGREP_PACK_FILE."
      ;;
    *)
      echo "WARN: semgrep registry pack first line did not start with 'rules:'; keeping existing pack." >&2
      rm -f "$tmp_pack"
      ;;
  esac
else
  echo "WARN: failed to download semgrep registry pack; keeping existing pack." >&2
  rm -f "$tmp_pack"
fi

# --- symlink the dotfiles -----------------------------------------------------
"$SCRIPT_DIR/link.sh"

echo "Done. Run 'exec zsh' (or restart your shell) to apply."
