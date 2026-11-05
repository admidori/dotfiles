#!/usr/bin/env bash
#
# Secret detection check using betterleaks.
# Fail-closed: blocks commit if betterleaks is missing or too old, if leaks are
# found, or if betterleaks encounters an error.
#
# Scans the exported staged files with `betterleaks dir` rather than the staged
# diff with `betterleaks git --pre-commit`: git mode always honours the
# repository's own .betterleaksignore / .gitleaksignore, which a change could
# use to silence its findings. In dir mode the scan root is the export directory,
# so the hook controls every file betterleaks reads. The whole content of each
# staged file is scanned, not only the added lines.
#
set -euo pipefail

check_betterleaks() {
  local target_dir="$1"

  if ! command -v betterleaks >/dev/null 2>&1; then
    echo "git-hooks: betterleaks is not installed or not on PATH; run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  # `dir` and --ignore-gitleaks-allow need betterleaks with 'dir' command.
  if ! betterleaks dir --help >/dev/null 2>&1; then
    echo "git-hooks: betterleaks is too old (no 'dir' command); run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  # Neutralise every way a staged change could silence findings:
  # - .betterleaksignore and .gitleaksignore in the scan root (removed, whatever its type),
  # - .betterleaks.toml / .gitleaks.toml / BETTERLEAKS_CONFIG* / GITLEAKS_CONFIG* (overridden by --config with defaults),
  # - inline betterleaks:allow and gitleaks:allow comments (--ignore-gitleaks-allow).
  find "$target_dir" \( -name .betterleaksignore -o -name .gitleaksignore \) -prune -exec rm -rf -- {} +

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-hooks-betterleaks.XXXXXX")"
  mkdir "$work_dir/ignore"
  printf '[extend]\nuseDefault = true\n' > "$work_dir/config.toml"

  # Match the previous scanner scope; Betterleaks otherwise expands archives.
  local status=0
  (
    cd "$target_dir"
    env -u BETTERLEAKS_CONFIG -u BETTERLEAKS_CONFIG_TOML \
        -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML \
      betterleaks dir . --redact --no-banner --verbose \
        --config "$work_dir/config.toml" \
        --gitleaks-ignore-path "$work_dir/ignore" \
        --ignore-gitleaks-allow \
        --max-archive-depth 0 \
        --validation=false
  ) >&2 || status=$?
  rm -rf "$work_dir"

  if [ "$status" -eq 0 ]; then
    return 0
  elif [ "$status" -eq 1 ]; then
    echo "git-hooks: betterleaks found secrets in staged changes" >&2
    return 1
  else
    echo "git-hooks: betterleaks failed with exit code $status" >&2
    return 1
  fi
}
