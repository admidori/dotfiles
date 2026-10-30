#!/usr/bin/env bash
#
# File size check for staged files.
# Blocks commits if any staged file exceeds 5 MiB (5,242,880 bytes).
#
set -euo pipefail

MAX_FILE_SIZE=5242880

check_large_files() {
  local file size failed=0
  for file in "$@"; do
    size="$(git cat-file -s ":$file" 2>/dev/null)" || continue
    if [ "$size" -gt "$MAX_FILE_SIZE" ]; then
      echo "git-hooks: file exceeds 5 MiB limit ($size bytes > $MAX_FILE_SIZE bytes): $file" >&2
      failed=1
    fi
  done
  return $failed
}
