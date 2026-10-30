#!/usr/bin/env bash
#
# Dependency vulnerability scanner using osv-scanner.
# Scans staged package lockfiles for known vulnerabilities against osv.dev.
# Policy:
# - Known vulnerabilities block the commit (exit 1).
# - Missing scanner, network failure, timeout, unparseable output or errors
#   only warn and let the commit pass, keeping offline commits possible.
# - Exit 128 (no packages found) passes silently.
#
set -euo pipefail

check_osv() {
  local target_dir="$1"
  shift

  local lockfiles=()
  local file bname
  for file in "$@"; do
    bname="${file##*/}"
    case "$bname" in
      package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-lock.yaml | bun.lock | \
      requirements.txt | requirements*.txt | Pipfile.lock | poetry.lock | uv.lock | \
      pdm.lock | go.mod | Cargo.lock | Gemfile.lock | composer.lock | mix.lock | \
      pubspec.lock | gradle.lockfile | packages.lock.json | conan.lock)
        if [ -f "$target_dir/$file" ]; then
          lockfiles+=("$file")
        fi
        ;;
    esac
  done

  [ "${#lockfiles[@]}" -gt 0 ] || return 0

  if ! command -v osv-scanner >/dev/null 2>&1; then
    echo "git-hooks: warning: osv-scanner not installed; run 'make install' in the dotfiles repo — not blocking" >&2
    return 0
  fi

  # An empty --config overrides any staged osv-scanner.toml, whose
  # [[IgnoredVulns]] entries would otherwise let a commit silence findings.
  local empty_config
  empty_config="$(mktemp "${TMPDIR:-/tmp}/git-hooks-osv.XXXXXX")"

  local cmd=(osv-scanner scan source --format json --config "$empty_config")
  local relpath
  for relpath in "${lockfiles[@]}"; do
    cmd+=(-L "$target_dir/$relpath")
  done

  local json_out="" status=0
  if command -v timeout >/dev/null 2>&1; then
    json_out="$(timeout 60 "${cmd[@]}" 2>/dev/null)" || status=$?
  else
    json_out="$("${cmd[@]}" 2>/dev/null)" || status=$?
  fi
  rm -f "$empty_config"

  # Exit 0: clean pass
  # Exit 128: no packages found (e.g. empty lockfile) -> clean pass
  if [ "$status" -eq 0 ] || [ "$status" -eq 128 ]; then
    return 0
  fi

  # Exit 1: vulnerabilities found -> block
  if [ "$status" -eq 1 ]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "git-hooks: osv-scanner reported vulnerabilities in dependencies" >&2
      return 1
    fi

    if ! echo "$json_out" | jq empty >/dev/null 2>&1; then
      echo "git-hooks: osv-scanner reported vulnerabilities in dependencies" >&2
      return 1
    fi

    local prefix="${target_dir%/}/"
    local real_target
    real_target="$(cd "$target_dir" && pwd -P 2>/dev/null || realpath "$target_dir" 2>/dev/null || echo "$target_dir")"
    local real_prefix="${real_target%/}/"

    local findings=""
    findings="$(echo "$json_out" | jq -r --arg prefix "$prefix" --arg real_prefix "$real_prefix" '
      .results[]? as $res |
      ($res.source.path // "" | ltrimstr($real_prefix) | ltrimstr($prefix) | ltrimstr("./")) as $file |
      $res.packages[]? |
      select((.vulnerabilities // []) | length > 0) |
      .package as $pkg |
      [.vulnerabilities[].id // empty] as $ids |
      ($ids[0:5] | join(", ")) as $shown_ids |
      (if ($ids | length) > 5 then "\($shown_ids), …" else $shown_ids end) as $ids_str |
      "git-hooks: vulnerable dependency \($pkg.name // "unknown")@\($pkg.version // "unknown") (\($pkg.ecosystem // "unknown")) in \($file): \($ids_str)"
    ' 2>/dev/null)" || findings=""

    if [ -n "$findings" ]; then
      printf '%s\n' "$findings" >&2
    else
      echo "git-hooks: osv-scanner reported vulnerabilities in dependencies" >&2
    fi
    return 1
  fi

  # Any other exit code (124 timeout, 127 error / offline, etc.) -> warn only
  echo "git-hooks: warning: could not check dependencies with osv-scanner (exit $status; offline?) — not blocking" >&2
  return 0
}
