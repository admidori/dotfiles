#!/usr/bin/env bash
#
# Secret detection check using gitleaks.
# Fail-closed: blocks commit if gitleaks is missing or too old, if leaks are
# found, or if gitleaks encounters an error.
#
# Scans the exported staged files with `gitleaks dir` rather than the staged
# diff with `gitleaks git --pre-commit`: git mode always honours the
# repository's own .gitleaksignore, which a change could use to silence its
# findings. In dir mode the scan root is the export directory, so the hook
# controls every file gitleaks reads. The whole content of each staged file
# is scanned, not only the added lines.
#
set -euo pipefail

check_gitleaks() {
  local target_dir="$1"

  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "git-hooks: gitleaks is not installed or not on PATH; run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  # `dir` and --ignore-gitleaks-allow need gitleaks 8.19 or later.
  if ! gitleaks dir --help >/dev/null 2>&1; then
    echo "git-hooks: gitleaks is too old (no 'dir' command); run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  # Neutralise every way a staged change could silence findings:
  # - .gitleaksignore in the scan root (removed, whatever its type),
  # - .gitleaks.toml / GITLEAKS_CONFIG* (overridden by --config with defaults),
  # - inline gitleaks:allow comments (--ignore-gitleaks-allow).
  find "$target_dir" -name .gitleaksignore -prune -exec rm -rf -- {} +

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-hooks-gitleaks.XXXXXX")"
  mkdir "$work_dir/ignore"
  printf '[extend]\nuseDefault = true\n' > "$work_dir/config.toml"

  local status=0
  (
    cd "$target_dir"
    env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML \
      gitleaks dir . --redact --no-banner --verbose \
        --config "$work_dir/config.toml" \
        --gitleaks-ignore-path "$work_dir/ignore" \
        --ignore-gitleaks-allow
  ) >&2 || status=$?
  rm -rf "$work_dir"

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
