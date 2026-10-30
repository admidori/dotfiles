#!/usr/bin/env bash
#
# Code security scanner using semgrep.
# Fail-closed: blocks commit if semgrep is missing, if jq is missing,
# if semgrep crashes/fails, or if any finding of severity ERROR is detected.
# Non-blocking for WARNING/INFO findings or per-file parse errors.
#
set -euo pipefail

check_semgrep() {
  local target_dir="$1"

  if ! command -v semgrep >/dev/null 2>&1; then
    echo "git-hooks: semgrep is not installed or not on PATH; run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "git-hooks: jq is not installed or not on PATH; run 'make install' in the dotfiles repo" >&2
    return 1
  fi

  local lib_dir rules_file registry_pack
  lib_dir="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  rules_file="$(cd "$lib_dir/.." && pwd)/semgrep/ai-insecure.yml"
  registry_pack="${XDG_DATA_HOME:-$HOME/.local/share}/git-hooks/semgrep/default.yml"

  local semgrep_cmd=(
    semgrep scan
    --metrics=off
    --disable-version-check
    --json
    --config "$rules_file"
  )

  if [ -f "$registry_pack" ]; then
    semgrep_cmd+=(--config "$registry_pack")
  fi

  target_dir="$(cd "$target_dir" && pwd -P)"
  # Every staged file is in scope. Without a .semgrepignore semgrep applies
  # built-in defaults that skip tests/, node_modules/ and the like, and a
  # staged .semgrepignore would let a change exempt itself from the scan.
  find "$target_dir" -name .semgrepignore -type f -delete
  : > "$target_dir/.semgrepignore"

  local json_out="" status=0
  json_out="$(SEMGREP_ENABLE_VERSION_CHECK=0 "${semgrep_cmd[@]}" "$target_dir" 2>/dev/null)" || status=$?

  if ! echo "$json_out" | jq empty >/dev/null 2>&1; then
    if [ "$status" -ne 0 ]; then
      echo "git-hooks: semgrep failed with exit code $status" >&2
    else
      echo "git-hooks: semgrep failed with unparseable output" >&2
    fi
    return 1
  fi

  local error_count=0
  error_count="$(echo "$json_out" | jq '(.errors // []) | length' 2>/dev/null)" || error_count=0
  if [ "$error_count" -gt 0 ]; then
    echo "git-hooks: semgrep reported parse errors on some files (ignored)" >&2
  fi

  local prefix="$target_dir/"
  local findings=""
  findings="$(echo "$json_out" | jq -r --arg prefix "$prefix" '
    .results[]? | "\(.extra.severity // "INFO") \((.path // "") | ltrimstr($prefix) | ltrimstr("./")):\(.start.line // 1) \((.check_id // "unknown") | split(".") | last): \((.extra.message // "") | split("\n")[0])"
  ' 2>/dev/null)" || findings=""

  if [ -n "$findings" ]; then
    printf '%s\n' "$findings" >&2
  fi

  local blocking_count=0
  blocking_count="$(echo "$json_out" | jq '[.results[]? | select(.extra.severity == "ERROR")] | length' 2>/dev/null)" || blocking_count=0

  if [ "$blocking_count" -gt 0 ]; then
    return 1
  fi

  return 0
}
