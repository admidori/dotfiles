#!/usr/bin/env bash
set -euo pipefail

# Shared dangerous-command rules (single source of truth). guard-rules.sh here
# is a symlink to ../../.claude/hooks/guard-rules.sh, reached via the symlinked
# ~/.codex/hooks directory.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/guard-rules.sh"

input="$(cat)"
# Locate the command via an ordered list of explicit paths (matching Codex's own
# shipped hook example), so a benign `command` field elsewhere in the payload
# can't be picked ahead of the real tool command.
if command -v jq >/dev/null 2>&1; then
  command="$(
    printf '%s' "$input" \
    | jq -r '.tool_input.command // .tool_input.args.command // .command // .cmd // .args.command // ""'
  )"
elif command -v node >/dev/null 2>&1; then
  command="$(
    printf '%s' "$input" \
    | node -e '
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(0, "utf8"));
const ti = d.tool_input || {};
process.stdout.write(
  ti.command || (ti.args && ti.args.command) || d.command || d.cmd || (d.args && d.args.command) || ""
);
'
  )"
else
  exit 0
fi

if ! reason="$(guard_check_command "$command")"; then
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
fi

exit 0
