#!/usr/bin/env bash
#
# Conflict marker check for staged files.
# Blocks commits when added lines in the staged diff start with '<<<<<<< '
# or '>>>>>>> ' (marker plus space) or are exactly '<<<<<<<' / '>>>>>>>'.
# Does not flag lone '=======' lines (valid heading underlines).
#
set -euo pipefail

check_conflict_markers() {
  local file failed=0
  for file in "$@"; do
    # Scan index diff additions for conflict markers. Not `grep -q`: it exits on
    # the first match, git diff then dies of SIGPIPE on a large diff, and under
    # pipefail the whole pipeline reads as "no match".
    if git --literal-pathspecs diff --cached -U0 -- "$file" \
        | grep -E '^\+(<<<<<<< |<<<<<<<$|>>>>>>> |>>>>>>>$)' >/dev/null; then
      echo "git-hooks: conflict markers found in: $file" >&2
      failed=1
    fi
  done
  return $failed
}
