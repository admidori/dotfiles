#!/usr/bin/env bash
#
# run-task.sh <step-dir> <workdir> [brief]
#
# Hands one step to Antigravity headlessly and records the run, so every
# delegation leaves the same artifacts regardless of which designer (Claude
# or Codex) drove it:
#
#   <step-dir>/prompt-<n>.md   exact prompt sent (brief + run rules/report format)
#   <step-dir>/run-<n>.jsonl   agy stream-json event log
#   <step-dir>/stderr-<n>.log  agy diagnostics
#   <step-dir>/report-<n>.md   Antigravity's final response (the report)
#   <task-dir>/metrics.jsonl   one row per run
#
# <step-dir> is <task-dir>/steps/<NN>-<slug>. <n> counts attempts, so a
# rework run keeps the earlier attempt's record. [brief] defaults to
# <step-dir>/brief.md; pass a rework brief for later attempts.
#
# Env: HARNESS_VARIANT (label for comparing harness changes, default
# "baseline"), HARNESS_DESIGNER (e.g. "Claude (Opus 5.5)"), AGY_MODEL,
# AGY_EFFORT, AGY_TIMEOUT (default 30m).
#
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <step-dir> <workdir> [brief]" >&2
  exit 2
}
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  usage
fi

step_dir="$(cd "$1" && pwd)"
workdir="$(cd "$2" && pwd)"
brief="${3:-$step_dir/brief.md}"
[ -f "$brief" ] || { echo "brief not found: $brief" >&2; exit 2; }
for cmd in agy jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 2; }
done

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_dir="$(cd "$step_dir/../.." && pwd)"

attempt=1
while [ -e "$step_dir/run-$attempt.jsonl" ]; do
  attempt=$((attempt + 1))
done
prompt="$step_dir/prompt-$attempt.md"
run="$step_dir/run-$attempt.jsonl"
stderr="$step_dir/stderr-$attempt.log"
report="$step_dir/report-$attempt.md"

{ cat "$brief"; printf '\n'; cat "$skill_dir/templates/report.md"; } >"$prompt"

# accept-edits lets Antigravity write files in the workspace without a
# prompt nobody could answer. Commands, including its own verification, run
# only inside agy's terminal sandbox (settings.json: proceed-in-sandbox), so
# the run never needs a blanket permission bypass.
args=(-p "$(cat "$prompt")" --output-format stream-json --mode accept-edits
  --disable-slash-commands --print-timeout "${AGY_TIMEOUT:-30m}")
[ -n "${AGY_MODEL:-}" ] && args+=(--model "$AGY_MODEL")
[ -n "${AGY_EFFORT:-}" ] && args+=(--effort "$AGY_EFFORT")

echo "==> step $(basename "$step_dir"), attempt $attempt: running agy in $workdir"
set +e
(cd "$workdir" && agy "${args[@]}" </dev/null) >"$run" 2>"$stderr"
rc=$?
set -e

result="$(jq -c -R 'fromjson? | select(.event == "result") | .result' "$run" | tail -n 1)"
[ -n "$result" ] || result='{}'
jq -r '.response // empty' <<<"$result" >"$report"

# Tool calls refused by a permission rule, or auto-denied because a headless
# run can't prompt. They show up only as ERROR steps in the event log, and a
# denied run can end with an empty response, so count them explicitly.
denied="$(jq -R 'fromjson? | select(.event == "step_update") | .step_update
  | select(.state == "ERROR" and ((.tool_info.error.message // "") | test("[Pp]ermission")))' \
  "$run" | jq -s 'length')"
report_empty=false
[ -s "$report" ] || report_empty=true

harness_rev="$(git -C "$skill_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg task "$(basename "$task_dir")" \
  --arg step "$(basename "$step_dir")" \
  --argjson attempt "$attempt" \
  --arg variant "${HARNESS_VARIANT:-baseline}" \
  --arg harness_rev "$harness_rev" \
  --arg designer "${HARNESS_DESIGNER:-unknown}" \
  --arg model "${AGY_MODEL:-default}" \
  --argjson exit_code "$rc" \
  --argjson denied "$denied" \
  --argjson report_empty "$report_empty" \
  --argjson r "$result" \
  '{ts: $ts, task: $task, step: $step, attempt: $attempt, variant: $variant,
    harness_rev: $harness_rev, designer: $designer, model: $model,
    exit_code: $exit_code, status: ($r.status // "NO_RESULT"),
    denied_tool_calls: $denied, report_empty: $report_empty,
    duration_seconds: $r.duration_seconds, num_turns: $r.num_turns,
    usage: $r.usage, conversation_id: $r.conversation_id}' \
  >>"$task_dir/metrics.jsonl"

status="$(jq -r '.status // "NO_RESULT"' <<<"$result")"
echo "==> status: $status (exit $rc)"
echo "    report: $report"
echo "    log:    $run"
if [ "$denied" -gt 0 ]; then
  echo "==> warning: $denied tool call(s) denied; the report's verification may be incomplete"
fi
if [ "$report_empty" = true ]; then
  echo "==> warning: no report was returned; see $stderr"
fi
echo "==> working tree:"
git -C "$workdir" status --short || true
[ "$status" = "SUCCESS" ] && [ "$report_empty" = false ]
