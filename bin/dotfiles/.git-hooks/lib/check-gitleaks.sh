#!/usr/bin/env bash
#
# Secret detection check using gitleaks.
# Fail-closed: blocks commit if gitleaks is missing, if leaks are found,
# or if gitleaks encounters an error.
#
set -euo pipefail

check_gitleaks() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "git-hooks: gitleaks is not installed or not on PATH; run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  local gitleaks_cmd=()
  # Detect CLI flavour: newer versions have 'gitleaks git --pre-commit --staged',
  # older versions (e.g. 8.16) have 'gitleaks protect --staged'.
  if gitleaks git --help >/dev/null 2>&1; then
    gitleaks_cmd=(gitleaks git --pre-commit --staged --redact)
  else
    gitleaks_cmd=(gitleaks protect --staged --redact)
  fi

  local status=0
  "${gitleaks_cmd[@]}" >&2 || status=$?

  if [ "$status" -eq 0 ]; then
    return 0
  elif [ "$status" -eq 1 ]; then
    echo "git-hooks: gitleaks found secrets in staged changes" >&2
    return 1
  else
    echo "git-hooks: gitleaks failed with exit code $status" >&2
    return 1
  fi
}
