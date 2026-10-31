#!/usr/bin/env bash
#
# Unit tests for pinned-tools.sh helper functions.
# Tests verified binary installation, checksum validation, tar extraction,
# cleanup, and idempotency using file:// URLs in a temp directory.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=installer/pinned-tools.sh
. "$SCRIPT_DIR/pinned-tools.sh"

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

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-pinned-tools.XXXXXX")"
cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "==> Testing install_verified_binary with raw binary"
raw_src="$TEST_DIR/raw_source"
printf '#!/bin/sh\necho "raw-binary-ok"\n' > "$raw_src"
chmod 0644 "$raw_src"
raw_hash="$(sha256sum "$raw_src" | cut -d ' ' -f 1)"
dest_raw="$TEST_DIR/bin/raw_tool"

check "install_verified_binary installs raw binary" \
  install_verified_binary "file://$raw_src" "$raw_hash" "$dest_raw"
check "installed raw binary exists and is executable" test -x "$dest_raw"
check "installed raw binary runs successfully" test "$("$dest_raw")" = "raw-binary-ok"
check "installed raw binary has 0755 permissions" test "$(stat -c %a "$dest_raw")" = "755"

echo "==> Testing install_verified_binary with tarball member"
tar_src_dir="$TEST_DIR/tar_src"
mkdir -p "$tar_src_dir"
printf '#!/bin/sh\necho "tar-member-ok"\n' > "$tar_src_dir/my_tool"
echo "unrelated doc" > "$tar_src_dir/README"
tar_archive="$TEST_DIR/archive.tar.gz"
tar -czf "$tar_archive" -C "$tar_src_dir" my_tool README
tar_hash="$(sha256sum "$tar_archive" | cut -d ' ' -f 1)"
dest_tar="$TEST_DIR/bin/tar_tool"

check "install_verified_binary extracts tar member" \
  install_verified_binary "file://$tar_archive" "$tar_hash" "$dest_tar" "my_tool"
check "extracted tar binary exists and is executable" test -x "$dest_tar"
check "extracted tar binary runs successfully" test "$("$dest_tar")" = "tar-member-ok"
check "extracted tar binary has 0755 permissions" test "$(stat -c %a "$dest_tar")" = "755"

echo "==> Testing checksum mismatch handling and temp file cleanup"
dest_fail="$TEST_DIR/bin/existing_tool"
mkdir -p "$(dirname "$dest_fail")"
echo "pre-existing-content" > "$dest_fail"
chmod 0755 "$dest_fail"

custom_tmp="$TEST_DIR/tmp_mismatch"
mkdir -p "$custom_tmp"
bad_hash="0000000000000000000000000000000000000000000000000000000000000000"
mismatch_err="$TEST_DIR/mismatch.err"

status=0
TMPDIR="$custom_tmp" install_verified_binary "file://$raw_src" "$bad_hash" "$dest_fail" 2>"$mismatch_err" || status=$?

check_mismatch_msg() {
  grep -F "ERROR: checksum mismatch" "$mismatch_err" >/dev/null
}
check "checksum mismatch returns non-zero" test "$status" -ne 0
check "checksum mismatch prints error to stderr" check_mismatch_msg
check "pre-existing destination remains untouched" test "$(<"$dest_fail")" = "pre-existing-content"
check "checksum mismatch leaves no temp files" test -z "$(ls -A "$custom_tmp")"

echo "==> Testing missing tarball member handling and temp file cleanup"
custom_tmp2="$TEST_DIR/tmp_missing_member"
mkdir -p "$custom_tmp2"
dest_missing="$TEST_DIR/bin/missing_member_tool"
status=0
TMPDIR="$custom_tmp2" install_verified_binary "file://$tar_archive" "$tar_hash" "$dest_missing" "nonexistent_member" 2>/dev/null || status=$?

check "missing tar member returns non-zero" test "$status" -ne 0
check "missing tar member leaves no destination file" test ! -e "$dest_missing"
check "missing tar member leaves no temp files" test -z "$(ls -A "$custom_tmp2")"

echo "==> Testing architecture mapping"
current_m="$(uname -m)"
case "$current_m" in
  x86_64)
    check "x86_64 maps to gitleaks x64" test "$(get_pinned_arch gitleaks)" = "x64"
    check "x86_64 maps to osv-scanner amd64" test "$(get_pinned_arch osv-scanner)" = "amd64"
    ;;
  aarch64|arm64)
    check "aarch64 maps to gitleaks arm64" test "$(get_pinned_arch gitleaks)" = "arm64"
    check "aarch64 maps to osv-scanner arm64" test "$(get_pinned_arch osv-scanner)" = "arm64"
    ;;
esac

unsupported_arch_test() {
  local err_file="$TEST_DIR/unsupported_arch.err"
  local s=0
  (
    uname() { echo "mips64"; }
    get_pinned_arch gitleaks 2>"$err_file"
  ) || s=$?
  [ "$s" -ne 0 ] && grep -F "WARN: unsupported architecture" "$err_file" >/dev/null
}
check "unsupported arch warns and returns non-zero" unsupported_arch_test

echo "==> Testing version probe idempotency"
mock_bin_dir="$TEST_DIR/mock_bin"
mkdir -p "$mock_bin_dir"

printf '#!/bin/sh\necho "8.30.1"\n' > "$mock_bin_dir/gitleaks"
chmod 0755 "$mock_bin_dir/gitleaks"
check "gitleaks matching version skips install" \
  test "$(install_gitleaks "$mock_bin_dir/gitleaks")" = "gitleaks 8.30.1 already installed at $mock_bin_dir/gitleaks (skipping)."

printf '#!/bin/sh\necho "osv-scanner version: 2.7.0"\n' > "$mock_bin_dir/osv-scanner"
chmod 0755 "$mock_bin_dir/osv-scanner"
check "osv-scanner matching version skips install" \
  test "$(install_osv_scanner "$mock_bin_dir/osv-scanner")" = "osv-scanner 2.7.0 already installed at $mock_bin_dir/osv-scanner (skipping)."

echo
if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST PASSED"
