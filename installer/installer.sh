#!/usr/bin/env bash
#
# Remote bootstrap: ensure git/make exist, clone the repo, then `make install`.
# This is the target of the one-line installer in the README:
#   sh -c "$(curl -fsSL .../installer/installer.sh)"
#
set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/admidori/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

# --- ensure prerequisites (git, make) ----------------------------------------
if ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends git make ca-certificates
  else
    echo "ERROR: git and make are required but apt-get is unavailable." >&2
    exit 1
  fi
fi

# --- clone or update ----------------------------------------------------------
if [ -d "$DOTFILES_DIR/.git" ]; then
  echo "Updating existing clone at $DOTFILES_DIR ..."
  git -C "$DOTFILES_DIR" pull --ff-only
else
  echo "Cloning $DOTFILES_REPO into $DOTFILES_DIR ..."
  git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

# --- install ------------------------------------------------------------------
cd "$DOTFILES_DIR"
make install
