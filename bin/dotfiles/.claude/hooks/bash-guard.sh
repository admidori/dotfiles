#!/usr/bin/env bash
set -euo pipefail

# Shared dangerous-command rules (single source of truth). Reached via the
# symlinked ~/.claude/hooks directory.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/guard-rules.sh"

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
elif command -v node >/dev/null 2>&1; then
  command="$(printf '%s' "$input" | node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(0,"utf8")); process.stdout.write(data.tool_input?.command || "");')"
else
  exit 0
fi

if ! reason="$(guard_check_command "$command")"; then
  printf 'Blocked by Claude bash guard: %s\n' "$reason" >&2
  exit 2
fi

exit 0
