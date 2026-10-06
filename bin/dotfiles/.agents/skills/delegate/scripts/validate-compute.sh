#!/usr/bin/env bash
#
# validate-compute.sh <compute.json>
#
# Validates a delegate step's compute.json manifest before launching Antigravity.
# Enforces a strict, documented schema:
#   - backend: "coder" | "colab" string
#   - target: non-empty remote workspace/notebook identifier string
#             (do not treat as a local filesystem path)
#   - command: non-empty argv array of non-empty strings (no shell string)
#   - timeout_seconds: positive integer capped at 86400
#   - max_attempts: positive integer capped at 10
#   - inputs, scripts, artifacts (optional): arrays of non-empty relative paths
#     without absolute or ".." traversal components
#   - datasets (optional): array of objects, each containing a valid
#     URI with scheme (^[A-Za-z][A-Za-z0-9+.-]*://) and a 64-hex-character sha256
#
# Rejects invalid field types, legacy aliases, empty values, and invalid paths.
#
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <compute.json>" >&2
  exit 2
}

if [ $# -ne 1 ]; then
  usage
fi

compute_file="$1"

if [ ! -f "$compute_file" ]; then
  echo "error: compute manifest file not found: $compute_file" >&2
  exit 2
fi

if ! jq empty "$compute_file" >/dev/null 2>&1; then
  echo "error: compute manifest is not valid JSON: $compute_file" >&2
  exit 2
fi

root_type="$(jq -r 'type' "$compute_file")"
if [ "$root_type" != "object" ]; then
  echo "validation error: compute manifest root must be a JSON object" >&2
  exit 2
fi

# Reject legacy aliases explicitly
if jq -e 'has("timeout")' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: 'timeout' alias rejected; use 'timeout_seconds'" >&2
  exit 2
fi
if jq -e 'has("attempts")' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: 'attempts' alias rejected; use 'max_attempts'" >&2
  exit 2
fi
if jq -e 'has("commands")' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: 'commands' alias rejected; use 'command' as an argv array" >&2
  exit 2
fi

# Required: backend ('coder' or 'colab')
backend_type="$(jq -r 'if has("backend") then (.backend | type) else "missing" end' "$compute_file")"
if [ "$backend_type" = "missing" ] || [ "$backend_type" = "null" ]; then
  echo "validation error: missing required field 'backend'" >&2
  exit 2
fi
if [ "$backend_type" != "string" ]; then
  echo "validation error: 'backend' must be a string (got $backend_type)" >&2
  exit 2
fi
backend="$(jq -r '.backend' "$compute_file")"
if [ "$backend" != "coder" ] && [ "$backend" != "colab" ]; then
  echo "validation error: unknown backend '$backend' (must be 'coder' or 'colab')" >&2
  exit 2
fi

# Required: target (non-empty identifier string, remote workspace/notebook identifier)
target_type="$(jq -r 'if has("target") then (.target | type) else "missing" end' "$compute_file")"
if [ "$target_type" = "missing" ] || [ "$target_type" = "null" ]; then
  echo "validation error: missing required field 'target'" >&2
  exit 2
fi
if [ "$target_type" != "string" ]; then
  echo "validation error: 'target' must be a string (got $target_type)" >&2
  exit 2
fi
target_str="$(jq -r '.target' "$compute_file")"
trimmed_target="$(echo "$target_str" | tr -d '[:space:]')"
if [ -z "$trimmed_target" ]; then
  echo "validation error: empty target identifier" >&2
  exit 2
fi

# Required: command (non-empty argv array of non-empty strings)
cmd_type="$(jq -r 'if has("command") then (.command | type) else "missing" end' "$compute_file")"
if [ "$cmd_type" = "missing" ] || [ "$cmd_type" = "null" ]; then
  echo "validation error: missing required field 'command'" >&2
  exit 2
fi
if [ "$cmd_type" != "array" ]; then
  echo "validation error: 'command' must be an argv array of strings (no shell string)" >&2
  exit 2
fi
cmd_len="$(jq -r '.command | length' "$compute_file")"
if [ "$cmd_len" -eq 0 ]; then
  echo "validation error: empty command array" >&2
  exit 2
fi
non_string_count="$(jq -r '[.command[] | if type != "string" then "bad" else empty end] | length' "$compute_file")"
if [ "$non_string_count" -gt 0 ]; then
  echo "validation error: all elements in 'command' array must be strings" >&2
  exit 2
fi
empty_elem_count="$(jq -r '[.command[] | if test("^\\s*$") then "empty" else empty end] | length' "$compute_file")"
if [ "$empty_elem_count" -gt 0 ]; then
  echo "validation error: empty element in 'command' array" >&2
  exit 2
fi

# Required: timeout_seconds (positive integer capped at 86400)
timeout_type="$(jq -r 'if has("timeout_seconds") then (.timeout_seconds | type) else "missing" end' "$compute_file")"
if [ "$timeout_type" = "missing" ] || [ "$timeout_type" = "null" ]; then
  echo "validation error: missing required field 'timeout_seconds'" >&2
  exit 2
fi
if [ "$timeout_type" != "number" ]; then
  echo "validation error: 'timeout_seconds' must be a number (got $timeout_type)" >&2
  exit 2
fi
if ! jq -e '(.timeout_seconds | floor) == .timeout_seconds' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: 'timeout_seconds' must be an integer" >&2
  exit 2
fi
timeout_val="$(jq -r '.timeout_seconds' "$compute_file")"
if ! jq -e '.timeout_seconds > 0' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: non-positive timeout_seconds '$timeout_val' (must be a positive integer)" >&2
  exit 2
fi
if ! jq -e '.timeout_seconds <= 86400' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: timeout_seconds '$timeout_val' exceeds maximum limit (86400s)" >&2
  exit 2
fi

# Required: max_attempts (positive integer capped at 10)
attempts_type="$(jq -r 'if has("max_attempts") then (.max_attempts | type) else "missing" end' "$compute_file")"
if [ "$attempts_type" = "missing" ] || [ "$attempts_type" = "null" ]; then
  echo "validation error: missing required field 'max_attempts'" >&2
  exit 2
fi
if [ "$attempts_type" != "number" ]; then
  echo "validation error: 'max_attempts' must be a number (got $attempts_type)" >&2
  exit 2
fi
if ! jq -e '(.max_attempts | floor) == .max_attempts' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: 'max_attempts' must be an integer" >&2
  exit 2
fi
attempts_val="$(jq -r '.max_attempts' "$compute_file")"
if ! jq -e '.max_attempts > 0' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: non-positive max_attempts '$attempts_val' (must be a positive integer)" >&2
  exit 2
fi
if ! jq -e '.max_attempts <= 10' "$compute_file" >/dev/null 2>&1; then
  echo "validation error: max_attempts '$attempts_val' exceeds maximum limit (10)" >&2
  exit 2
fi

# Optional path array fields: inputs, scripts, artifacts
validate_path_array() {
  local field="$1"
  if ! jq -e --arg f "$field" 'has($f)' "$compute_file" >/dev/null 2>&1; then
    return 0
  fi
  local f_type
  f_type="$(jq -r --arg f "$field" '.[$f] | type' "$compute_file")"
  if [ "$f_type" != "array" ]; then
    echo "validation error: '$field' must be an array of relative paths (got $f_type)" >&2
    exit 2
  fi

  local bad_type_count
  bad_type_count="$(jq -r --arg f "$field" '[.[$f][] | if type != "string" then "bad" else empty end] | length' "$compute_file")"
  if [ "$bad_type_count" -gt 0 ]; then
    echo "validation error: elements of '$field' must be strings" >&2
    exit 2
  fi

  local entries
  entries="$(jq -r --arg f "$field" '.[$f][]' "$compute_file")"
  if [ -n "$entries" ]; then
    while IFS= read -r p; do
      local trimmed
      trimmed="$(echo "$p" | tr -d '[:space:]')"
      if [ -z "$trimmed" ]; then
        echo "validation error: empty path entry in '$field'" >&2
        exit 2
      fi
      # Reject absolute paths
      if [[ "$p" =~ ^/ ]]; then
        echo "validation error: absolute path not allowed in '$field': $p" >&2
        exit 2
      fi
      # Reject path traversal components (.. alone, or as a path segment)
      if [[ "$p" == ".." ]] || [[ "$p" =~ (^|/)\.\.(/|$) ]]; then
        echo "validation error: traversing path not allowed in '$field': $p" >&2
        exit 2
      fi
      # Colab does not support directory staging for scripts or directory sync for artifacts
      if [ "$backend" = "colab" ] && { [ "$field" = "scripts" ] || [ "$field" = "artifacts" ]; }; then
        if [[ "$p" =~ /$ ]]; then
          echo "validation error: colab backend does not support directory staging or collection: $p" >&2
          exit 2
        fi
      fi
    done <<< "$entries"
  fi
}

validate_path_array "inputs"
validate_path_array "scripts"
validate_path_array "artifacts"

# Optional datasets field: array of objects with valid URI scheme and 64-hex sha256
if jq -e 'has("datasets")' "$compute_file" >/dev/null 2>&1; then
  ds_type="$(jq -r '.datasets | type' "$compute_file")"
  if [ "$ds_type" != "array" ]; then
    echo "validation error: 'datasets' must be an array of dataset objects (got $ds_type)" >&2
    exit 2
  fi
  while IFS= read -r ds; do
    [ -n "$ds" ] || continue
    item_type="$(jq -r 'type' <<<"$ds")"
    if [ "$item_type" != "object" ]; then
      echo "validation error: dataset entries must be objects containing 'uri' and 'sha256' (got $item_type)" >&2
      exit 2
    fi
    if ! jq -e 'has("uri") and (.uri | type == "string")' <<<"$ds" >/dev/null 2>&1; then
      echo "validation error: dataset entry missing non-empty string 'uri'" >&2
      exit 2
    fi
    uri_val="$(jq -r '.uri' <<<"$ds")"
    trimmed_uri="$(echo "$uri_val" | tr -d '[:space:]')"
    if [ -z "$trimmed_uri" ]; then
      echo "validation error: dataset entry missing non-empty 'uri'" >&2
      exit 2
    fi
    if [[ ! "$uri_val" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
      echo "validation error: dataset uri must be a valid URI with scheme (got '$uri_val')" >&2
      exit 2
    fi
    if ! jq -e 'has("sha256") and (.sha256 | type == "string")' <<<"$ds" >/dev/null 2>&1; then
      echo "validation error: dataset entry missing non-empty string 'sha256'" >&2
      exit 2
    fi
    sha_val="$(jq -r '.sha256' <<<"$ds")"
    trimmed_sha="$(echo "$sha_val" | tr -d '[:space:]')"
    if [ -z "$trimmed_sha" ]; then
      echo "validation error: dataset entry missing non-empty 'sha256'" >&2
      exit 2
    fi
    if [[ ! "$sha_val" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "validation error: dataset sha256 must be exactly 64 hexadecimal characters (got '$sha_val')" >&2
      exit 2
    fi
  done < <(jq -c '.datasets[]' "$compute_file")
fi
