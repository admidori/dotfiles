#!/usr/bin/env bash
#
# Test suite for uv and uv tool installation helpers (installer/uv-tools.sh).
# Tests failure modes, tempfile cleanup, collision detection, and uv tool resolution.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=installer/uv-tools.sh
. "$REPO_ROOT/installer/uv-tools.sh"

fail=0
check() {
  local desc="$1"; shift
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

echo "==> Testing install_uv"

# Test 1: existing working uv is skipped
test_uv_existing() {
  local tmp_env
  tmp_env="$(mktemp -d)"
  trap 'rm -rf "$tmp_env"' RETURN
  mkdir -p "$tmp_env/bin"
  cat <<'EOF' > "$tmp_env/bin/uv"
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "uv 9.9.9"
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp_env/bin/uv"

  local out
  out="$(PATH="$tmp_env/bin:/usr/bin:/bin" install_uv "$tmp_env/dest")"
  check "install_uv skips existing working uv" grep -q "already present" <<< "$out"
  check "install_uv did not create dest bin" test ! -f "$tmp_env/dest/uv"
}
test_uv_existing

# Test 2: download failure cleans up tempfile and returns 1
test_uv_download_fail() {
  local tmp_env
  tmp_env="$(mktemp -d)"
  trap 'rm -rf "$tmp_env"' RETURN
  local tmpdir="$tmp_env/tmp"
  mkdir -p "$tmpdir"

  local status=0 out=""
  out="$(TMPDIR="$tmpdir" UV_INSTALL_URL="file:///nonexistent-path-to-uv" PATH="/usr/bin:/bin" install_uv "$tmp_env/dest" 2>&1)" || status=$?
  check "install_uv fails on download failure" test "$status" -ne 0
  check "install_uv error message on download failure" grep -q "failed to download uv installer" <<< "$out"
  check "install_uv cleaned up temp files on download error" test "$(find "$tmpdir" -type f | wc -l)" -eq 0
}
test_uv_download_fail

# Test 3: installer script failure cleans up tempfile and propagates exit code
test_uv_installer_fail() {
  local tmp_env
  tmp_env="$(mktemp -d)"
  trap 'rm -rf "$tmp_env"' RETURN
  local tmpdir="$tmp_env/tmp"
  mkdir -p "$tmpdir"

  local mock_installer="$tmp_env/mock-installer.sh"
  cat <<'EOF' > "$mock_installer"
#!/usr/bin/env sh
exit 42
EOF

  local status=0 out=""
  out="$(TMPDIR="$tmpdir" UV_INSTALL_URL="file://$mock_installer" PATH="/usr/bin:/bin" install_uv "$tmp_env/dest" 2>&1)" || status=$?
  check "install_uv propagates installer script exit status" test "$status" -eq 42
  check "install_uv error message on installer failure" grep -q "uv installer failed with exit status 42" <<< "$out"
  check "install_uv cleaned up temp files on installer failure" test "$(find "$tmpdir" -type f | wc -l)" -eq 0
}
test_uv_installer_fail

# Test 4: successful installation respects UV_INSTALL_DIR and UV_NO_MODIFY_PATH=1
test_uv_install_success() {
  local tmp_env
  tmp_env="$(mktemp -d)"
  trap 'rm -rf "$tmp_env"' RETURN
  local tmpdir="$tmp_env/tmp"
  mkdir -p "$tmpdir"

  local mock_installer="$tmp_env/mock-installer.sh"
  cat <<'EOF' > "$mock_installer"
#!/usr/bin/env sh
if [ "${UV_NO_MODIFY_PATH:-0}" != "1" ]; then
  echo "ERROR: UV_NO_MODIFY_PATH was not 1" >&2
  exit 1
fi
if [ -z "${UV_INSTALL_DIR:-}" ]; then
  echo "ERROR: UV_INSTALL_DIR not set" >&2
  exit 1
fi
mkdir -p "$UV_INSTALL_DIR"
cat <<'SH' > "$UV_INSTALL_DIR/uv"
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "uv 0.13.5 (test)"
  exit 0
fi
exit 0
SH
chmod +x "$UV_INSTALL_DIR/uv"
EOF

  out="$(TMPDIR="$tmpdir" UV_INSTALL_URL="file://$mock_installer" PATH="/usr/bin:/bin" install_uv "$tmp_env/dest")"
  check "install_uv succeeded with mock installer" test -x "$tmp_env/dest/uv"
  check "installed uv reports version" "$tmp_env/dest/uv" --version
  check "install_uv cleaned up temp files on success" test "$(find "$tmpdir" -type f | wc -l)" -eq 0
}
test_uv_install_success

echo "==> Testing is_uv_managed_tool"
test_is_uv_managed() {
  local tmp_env
  tmp_env="$(mktemp -d)"
  trap 'rm -rf "$tmp_env"' RETURN
  local bin_dir="$tmp_env/bin"
  local tools_dir="$tmp_env/share/uv/tools"
  mkdir -p "$bin_dir" "$tools_dir/mocktool/bin"

  # Create mock uv command
  cat <<'EOF' > "$bin_dir/uv"
#!/usr/bin/env bash
if [ "${1:-}" = "tool" ] && [ "${2:-}" = "list" ]; then
  echo "mocktool v1.0.0"
  echo "- mocktool"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin_dir/uv"

  # Case A: target binary does not exist
  check "is_uv_managed_tool returns 1 when target bin missing" \
    not env PATH="$bin_dir:/usr/bin:/bin" bash -c ". '$REPO_ROOT/installer/uv-tools.sh'; is_uv_managed_tool 'mocktool' '$bin_dir' '$tools_dir'"

  # Case B: target binary exists but points to unmanaged path (pipx)
  local pipx_dir="$tmp_env/share/pipx/venvs/mocktool/bin"
  mkdir -p "$pipx_dir"
  touch "$pipx_dir/mocktool" && chmod +x "$pipx_dir/mocktool"
  ln -s "$pipx_dir/mocktool" "$bin_dir/mocktool"
  check "is_uv_managed_tool returns 1 when target resolves to pipx" \
    not env PATH="$bin_dir:/usr/bin:/bin" bash -c ". '$REPO_ROOT/installer/uv-tools.sh'; is_uv_managed_tool 'mocktool' '$bin_dir' '$tools_dir'"

  # Case C: target binary points to uv tools dir
  touch "$tools_dir/mocktool/bin/mocktool" && chmod +x "$tools_dir/mocktool/bin/mocktool"
  ln -snf "$tools_dir/mocktool/bin/mocktool" "$bin_dir/mocktool"
  check "is_uv_managed_tool returns 0 when target resolves to uv tool storage" \
    env PATH="$bin_dir:/usr/bin:/bin" bash -c ". '$REPO_ROOT/installer/uv-tools.sh'; is_uv_managed_tool 'mocktool' '$bin_dir' '$tools_dir'"

  # Case D: tool not in uv tool list
  check "is_uv_managed_tool returns 1 for unlisted tool" \
    not env PATH="$bin_dir:/usr/bin:/bin" bash -c ". '$REPO_ROOT/installer/uv-tools.sh'; is_uv_managed_tool 'other' '$bin_dir' '$tools_dir'"
}
test_is_uv_managed

echo "==> Testing install_uv_tool collision detection and idempotency"
test_install_uv_tool() {
  local tmp_env
  tmp_env="$(mktemp -d)"
  trap 'rm -rf "$tmp_env"' RETURN
  local bin_dir="$tmp_env/bin"
  local tools_dir="$tmp_env/share/uv/tools"
  mkdir -p "$bin_dir" "$tools_dir/managed/bin"

  # Mock uv
  cat <<'EOF' > "$bin_dir/uv"
#!/usr/bin/env bash
if [ "${1:-}" = "tool" ] && [ "${2:-}" = "list" ]; then
  echo "managed v1.0.0"
  echo "- managed"
  exit 0
fi
if [ "${1:-}" = "tool" ] && [ "${2:-}" = "install" ]; then
  shift 2
  for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
      echo "ERROR: --force was passed to uv tool install" >&2
      exit 99
    fi
  done
  target_tool="$1"
  td="${UV_TOOL_DIR:?missing UV_TOOL_DIR}"
  bd="${UV_TOOL_BIN_DIR:?missing UV_TOOL_BIN_DIR}"
  mkdir -p "$td/$target_tool/bin"
  touch "$td/$target_tool/bin/$target_tool" && chmod +x "$td/$target_tool/bin/$target_tool"
  ln -sf "$td/$target_tool/bin/$target_tool" "$bd/$target_tool"
  echo "Installed $target_tool"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin_dir/uv"

  # 1. Idempotency: tool already managed by uv
  touch "$tools_dir/managed/bin/managed" && chmod +x "$tools_dir/managed/bin/managed"
  ln -s "$tools_dir/managed/bin/managed" "$bin_dir/managed"
  local out
  out="$(PATH="$bin_dir:/usr/bin:/bin" install_uv_tool "managed" "$bin_dir" "$tools_dir")"
  check "install_uv_tool skips already-managed tool" grep -q "already installed via uv" <<< "$out"

  # 2. Collision with unmanaged target bin
  echo "unmanaged" > "$bin_dir/unmanaged"
  chmod +x "$bin_dir/unmanaged"
  local status=0
  out="$(PATH="$bin_dir:/usr/bin:/bin" install_uv_tool "unmanaged" "$bin_dir" "$tools_dir" 2>&1)" || status=$?
  check "install_uv_tool fails on unmanaged target collision" test "$status" -ne 0
  check "collision error mentions target collision and migration" grep -q "Collision detected.*unmanaged" <<< "$out"
  check "unmanaged target was not overwritten" test "$(cat "$bin_dir/unmanaged")" = "unmanaged"

  # 3. Collision with command elsewhere on PATH
  local other_bin="$tmp_env/other_bin"
  mkdir -p "$other_bin"
  echo "path_tool" > "$other_bin/from_path"
  chmod +x "$other_bin/from_path"
  status=0
  out="$(PATH="$bin_dir:$other_bin:/usr/bin:/bin" install_uv_tool "from_path" "$bin_dir" "$tools_dir" 2>&1)" || status=$?
  check "install_uv_tool fails on PATH collision outside bin_dir" test "$status" -ne 0
  check "collision error mentions PATH collision" grep -q "Collision detected: from_path exists at" <<< "$out"
  check "no target bin created on collision" test ! -e "$bin_dir/from_path"

  # 4. Clean install without collision
  out="$(PATH="$bin_dir:/usr/bin:/bin" install_uv_tool "newtool" "$bin_dir" "$tools_dir")"
  check "install_uv_tool succeeded on clean tool" test -L "$bin_dir/newtool"
  check "install_uv_tool linked to uv tool storage" test -f "$tools_dir/newtool/bin/newtool"
}
test_install_uv_tool

echo
if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST PASSED"
