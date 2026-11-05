#!/usr/bin/env bash
#
# Helpers for installing standalone uv and uv-managed Python tools.
# Sourced by install.sh; has no side effects when sourced.
#
set -euo pipefail

UV_INSTALL_URL="${UV_INSTALL_URL:-https://astral.sh/uv/install.sh}"

# install_uv [install_dir]
# Installs standalone uv via the official installer if not already working.
# Reuses existing working uv when available.
# Uses UV_INSTALL_DIR and UV_NO_MODIFY_PATH=1 to prevent modifying shell profiles.
install_uv() {
  local install_dir="${1:-$HOME/.local/bin}"

  if command -v uv >/dev/null 2>&1 && uv --version >/dev/null 2>&1; then
    echo "uv already present at $(command -v uv) (skipping)."
    return 0
  fi

  echo "Installing standalone uv into $install_dir ..."
  mkdir -p "$install_dir"

  local tmp_installer
  tmp_installer="$(mktemp "${TMPDIR:-/tmp}/uv-install.XXXXXX")"
  if ! curl -fsSL --retry 3 "$UV_INSTALL_URL" -o "$tmp_installer"; then
    rm -f "$tmp_installer"
    echo "ERROR: failed to download uv installer from $UV_INSTALL_URL." >&2
    return 1
  fi

  local status=0
  UV_INSTALL_DIR="$install_dir" UV_NO_MODIFY_PATH=1 sh "$tmp_installer" || status=$?
  rm -f "$tmp_installer"

  if [ "$status" -ne 0 ]; then
    echo "ERROR: uv installer failed with exit status $status." >&2
    return "$status"
  fi

  export PATH="$install_dir:$PATH"
  if ! command -v uv >/dev/null 2>&1 || ! uv --version >/dev/null 2>&1; then
    echo "ERROR: uv installed but uv executable is not functional." >&2
    return 1
  fi
}

# is_uv_managed_tool <tool> [bin_dir] [tools_dir]
# Checks if <tool> is managed by uv and its binary resolves into uv tool storage.
is_uv_managed_tool() {
  local tool="$1"
  local bin_dir="${2:-$HOME/.local/bin}"
  local tools_dir="${3:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"
  local target_bin="$bin_dir/$tool"

  if ! command -v uv >/dev/null 2>&1; then
    return 1
  fi

  if ! UV_TOOL_DIR="$tools_dir" uv tool list 2>/dev/null | grep -Eq "^${tool}( |$)"; then
    return 1
  fi

  if [ ! -e "$target_bin" ] && [ ! -L "$target_bin" ]; then
    return 1
  fi

  local resolved
  resolved="$(readlink -f "$target_bin" 2>/dev/null || true)"
  case "$resolved" in
    "$tools_dir/$tool"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# install_uv_tool <tool> [bin_dir] [tools_dir]
# Installs a tool in an isolated environment via `uv tool install`.
# Skips if already managed by uv. Fails closed with an error on unmanaged collisions.
install_uv_tool() {
  local tool="$1"
  local bin_dir="${2:-$HOME/.local/bin}"
  local tools_dir="${3:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"
  local target_bin="$bin_dir/$tool"

  if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required to install $tool." >&2
    return 1
  fi

  if is_uv_managed_tool "$tool" "$bin_dir" "$tools_dir"; then
    echo "$tool already installed via uv (skipping)."
    return 0
  fi

  if [ -e "$target_bin" ] || [ -L "$target_bin" ]; then
    echo "ERROR: Collision detected: $target_bin already exists and is not managed by uv." >&2
    echo "Please migrate or remove existing unmanaged $tool before running the installer." >&2
    return 1
  fi

  if command -v "$tool" >/dev/null 2>&1; then
    local existing_path
    existing_path="$(command -v "$tool")"
    echo "ERROR: Collision detected: $tool exists at $existing_path and is not managed by uv." >&2
    echo "Please migrate or remove existing unmanaged $tool before running the installer." >&2
    return 1
  fi

  echo "Installing $tool via uv ..."
  UV_TOOL_DIR="$tools_dir" UV_TOOL_BIN_DIR="$bin_dir" uv tool install "$tool"
}
