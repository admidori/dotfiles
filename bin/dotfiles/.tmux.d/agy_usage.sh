#!/usr/bin/env bash
set -euo pipefail

tmux_option() {
  local name="$1"
  command -v tmux >/dev/null 2>&1 || return 0
  tmux show-option -gqv "$name" 2>/dev/null || true
}

expand_home() {
  local value="$1"
  value="${value/#\~/$HOME}"
  value="${value//\$HOME/$HOME}"
  printf '%s' "$value"
}

normalize_percent() {
  local value="$1"
  value="${value//$'\n'/}"
  value="${value//[[:space:]]/}"
  value="${value%\%}"

  if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    return 1
  fi

  awk -v value="$value" 'BEGIN {
    if (value < 0) value = 0
    if (value > 100) value = 100
    printf "%d", value + 0.5
  }'
}

json_first_value() {
  local payload="$1"
  shift
  command -v python3 >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for key in sys.argv[1:]:
    current = data
    found = True
    for part in key.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            found = False
            break
    if found and current is not None:
        print(current)
        sys.exit(0)

sys.exit(1)
' "$@"
}

read_usage_payload() {
  local usage_cmd
  usage_cmd="$(tmux_option "@agy_usage_cmd")"
  if [ -n "$usage_cmd" ]; then
    sh -c "$usage_cmd" 2>/dev/null || true
    return 0
  fi

  if [ -n "${AGY_USAGE_PERCENT:-}" ]; then
    printf '%s' "$AGY_USAGE_PERCENT"
    return 0
  fi

  local cache_file
  cache_file="${AGY_USAGE_CACHE:-$(tmux_option "@agy_usage_cache")}"
  cache_file="${cache_file:-$HOME/.cache/antigravity-usage/status.json}"
  cache_file="$(expand_home "$cache_file")"
  if [ -r "$cache_file" ]; then
    cat "$cache_file"
  fi
}

extract_usage_percent() {
  local payload="$1"
  local value

  if value="$(normalize_percent "$payload")"; then
    printf '%s' "$value"
    return 0
  fi

  value="$(json_first_value "$payload" percent usage_percent usagePercent used_percent usedPercent)" || true
  if [ -n "$value" ] && value="$(normalize_percent "$value")"; then
    printf '%s' "$value"
    return 0
  fi

  value="$(json_first_value "$payload" remaining_percent remainingPercent remaining_pct remainingPct)" || true
  if [ -n "$value" ] && value="$(normalize_percent "$value")"; then
    printf '%d' $((100 - value))
    return 0
  fi

  return 1
}

read_reset_seconds() {
  local payload="$1"
  local reset_cmd
  local value

  reset_cmd="$(tmux_option "@agy_usage_reset_cmd")"
  if [ -n "$reset_cmd" ]; then
    sh -c "$reset_cmd" 2>/dev/null || true
    return 0
  fi

  if [ -n "${AGY_USAGE_RESET_IN:-}" ]; then
    printf '%s' "$AGY_USAGE_RESET_IN"
    return 0
  fi

  value="$(json_first_value "$payload" reset_in resetIn resets_in_seconds resetsInSeconds)" || true
  if [ -n "$value" ]; then
    printf '%s' "$value"
  fi
}

format_reset() {
  local value="$1"
  value="${value//$'\n'/}"
  value="${value//[[:space:]]/}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local days hours minutes
  days=$((value / 86400))
  hours=$(((value % 86400) / 3600))
  minutes=$(((value % 3600) / 60))

  if [ "$days" -gt 0 ]; then
    printf '%dd%02d:%02d' "$days" "$hours" "$minutes"
  else
    printf '%02d:%02d' "$hours" "$minutes"
  fi
}

render_usage() {
  local percent="$1"
  local reset_label="${2:-}"
  local width=6
  local filled empty bar_on="" bar_off="" i

  filled=$((percent * width / 100))
  empty=$((width - filled))
  for ((i = 0; i < filled; i++)); do
    bar_on+="#"
  done
  for ((i = 0; i < empty; i++)); do
    bar_off+="-"
  done

  printf '%d%% [%s%s]' "$percent" "$bar_on" "$bar_off"
  if [ -n "$reset_label" ]; then
    printf ' %s' "$reset_label"
  fi
}

payload="$(read_usage_payload)"
if [ -z "$payload" ]; then
  printf 'n/a'
  exit 0
fi

if ! percent="$(extract_usage_percent "$payload")"; then
  printf 'n/a'
  exit 0
fi

reset_seconds="$(read_reset_seconds "$payload")"
reset_label=""
if [ -n "$reset_seconds" ]; then
  reset_label="$(format_reset "$reset_seconds" || true)"
fi

render_usage "$percent" "$reset_label"
