#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"

if command -v jq >/dev/null 2>&1; then
  command="$(
    printf '%s' "$input" \
    | jq -r 'first(.. | objects | (.command? // .cmd? // empty)) // ""'
  )"
elif command -v node >/dev/null 2>&1; then
  command="$(
    printf '%s' "$input" \
    | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
function findCommand(value) {
  if (!value || typeof value !== "object") return "";
  if (typeof value.command === "string") return value.command;
  if (typeof value.cmd === "string") return value.cmd;
  for (const child of Object.values(value)) {
    const found = findCommand(child);
    if (found) return found;
  }
  return "";
}
process.stdout.write(findCommand(data));
'
  )"
else
  exit 0
fi

block() {
  reason="$1"
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 0
}

case "$command" in
  *"git reset --hard"*|*"git clean -f"*|*"git clean -d"*|*"git push --force"*|*"git push -f"*)
    block "destructive git command"
    ;;
  *"rm -rf "*|*"rm -fr "*|*"sudo rm "*|*"chmod -R 777"*)
    block "destructive filesystem command"
    ;;
esac

if printf '%s' "$command" | grep -Eq '(curl|wget)[^|;&]*(\||;|&&)[[:space:]]*(sh|bash)\b'; then
  block "remote script execution"
fi

exit 0
