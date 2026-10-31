#!/usr/bin/env bash
#
# Pinned external binary helpers for the installer.
# Downloads releases, verifies pinned SHA-256 checksums, and installs binaries.
# Sourced by install.sh; has no side effects when sourced.
#
set -euo pipefail

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256_X64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
GITLEAKS_SHA256_ARM64="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"

OSV_SCANNER_VERSION="2.7.0"
OSV_SCANNER_SHA256_AMD64="160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b"
OSV_SCANNER_SHA256_ARM64="4061ef4c021ed3c47f203b818f337e351336cc5cd67c0274fc36bd1dfc728dd7"

# get_pinned_arch <tool> — maps uname -m to tool-specific release arch names.
# Returns non-zero and prints WARN on unsupported architectures so caller skips.
get_pinned_arch() {
  local tool="$1"
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64)
      case "$tool" in
        gitleaks) echo "x64"; return 0 ;;
        osv-scanner|osv) echo "amd64"; return 0 ;;
      esac
      ;;
    aarch64|arm64)
      case "$tool" in
        gitleaks|osv-scanner|osv) echo "arm64"; return 0 ;;
      esac
      ;;
  esac
  echo "WARN: unsupported architecture '$m' for $tool; skipping." >&2
  return 1
}

# install_verified_binary <url> <sha256> <dest> [tar-member]
# Downloads <url> via curl into a temp directory, validates against <sha256>,
# optionally extracts [tar-member] from a .tar.gz archive, and installs to <dest>
# with mode 0755 atomically via <dest>.tmp.$$.
# Cleans up temp files on all paths; leaves <dest> untouched on failure.
install_verified_binary() {
  local url="$1"
  local expected_sha256="$2"
  local dest="$3"
  local tar_member="${4:-}"

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pinned-tools.XXXXXX")"

  local download_file="$tmp_dir/download"
  if ! curl -fsSL --retry 3 "$url" -o "$download_file"; then
    echo "ERROR: failed to download $url" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  local actual_sha256
  actual_sha256="$(sha256sum "$download_file" | cut -d ' ' -f 1)"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "ERROR: checksum mismatch for $url" >&2
    echo "  expected: $expected_sha256" >&2
    echo "  actual:   $actual_sha256" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  local binary_source="$download_file"
  if [ -n "$tar_member" ]; then
    local extract_dir="$tmp_dir/extracted"
    mkdir -p "$extract_dir"
    if ! tar -xzf "$download_file" -C "$extract_dir" "$tar_member" 2>/dev/null; then
      echo "ERROR: failed to extract '$tar_member' from $url" >&2
      rm -rf "$tmp_dir"
      return 1
    fi
    binary_source="$extract_dir/$tar_member"
    if [ ! -f "$binary_source" ]; then
      echo "ERROR: extracted member '$tar_member' not found" >&2
      rm -rf "$tmp_dir"
      return 1
    fi
  fi

  mkdir -p "$(dirname "$dest")"
  local tmp_dest="${dest}.tmp.$$"
  if ! install -m 0755 "$binary_source" "$tmp_dest"; then
    echo "ERROR: install failed for $dest" >&2
    rm -f "$tmp_dest"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! mv -f "$tmp_dest" "$dest"; then
    echo "ERROR: failed to move $tmp_dest to $dest" >&2
    rm -f "$tmp_dest"
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir"
  return 0
}

# install_gitleaks [dest] — installs pinned gitleaks binary if missing or different version.
install_gitleaks() {
  local dest="${1:-$HOME/.local/bin/gitleaks}"
  local arch
  if ! arch="$(get_pinned_arch gitleaks)"; then
    return 0
  fi

  if [ -x "$dest" ]; then
    local cur_ver
    cur_ver="$("$dest" version 2>/dev/null || true)"
    if [ "$cur_ver" = "$GITLEAKS_VERSION" ]; then
      echo "gitleaks $GITLEAKS_VERSION already installed at $dest (skipping)."
      return 0
    fi
  fi

  local sha256=""
  case "$arch" in
    x64) sha256="$GITLEAKS_SHA256_X64" ;;
    arm64) sha256="$GITLEAKS_SHA256_ARM64" ;;
  esac

  local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${arch}.tar.gz"
  echo "Installing gitleaks v${GITLEAKS_VERSION} to $dest ..."
  install_verified_binary "$url" "$sha256" "$dest" "gitleaks"
}

# install_osv_scanner [dest] — installs pinned osv-scanner binary if missing or different version.
install_osv_scanner() {
  local dest="${1:-$HOME/.local/bin/osv-scanner}"
  local arch
  if ! arch="$(get_pinned_arch osv-scanner)"; then
    return 0
  fi

  if [ -x "$dest" ]; then
    local cur_ver
    cur_ver="$("$dest" --version 2>/dev/null || true)"
    if grep -F "osv-scanner version: $OSV_SCANNER_VERSION" <<< "$cur_ver" >/dev/null; then
      echo "osv-scanner $OSV_SCANNER_VERSION already installed at $dest (skipping)."
      return 0
    fi
  fi

  local sha256=""
  case "$arch" in
    amd64) sha256="$OSV_SCANNER_SHA256_AMD64" ;;
    arm64) sha256="$OSV_SCANNER_SHA256_ARM64" ;;
  esac

  local url="https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_${arch}"
  echo "Installing osv-scanner v${OSV_SCANNER_VERSION} to $dest ..."
  install_verified_binary "$url" "$sha256" "$dest"
}
