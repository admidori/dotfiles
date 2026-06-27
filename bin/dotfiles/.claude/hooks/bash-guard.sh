#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
elif command -v node >/dev/null 2>&1; then
  command="$(printf '%s' "$input" | node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(0,"utf8")); process.stdout.write(data.tool_input?.command || "");')"
else
  exit 0
fi

deny() {
  printf 'Blocked by Claude bash guard: %s\n' "$1" >&2
  exit 2
}

case "$command" in
  *"git reset --hard"*|*"git clean -f"*|*"git clean -d"*|*"git push --force"*|*"git push -f"*)
    deny "destructive git command"
    ;;
  *"rm -rf "*|*"rm -fr "*|*"sudo rm "*|*"chmod -R 777"*)
    deny "destructive filesystem command"
    ;;
esac

if printf '%s' "$command" | grep -Eq '(curl|wget)[^|;&]*(\||;|&&)[[:space:]]*(sh|bash)\b'; then
  deny "remote script execution"
fi

exit 0
