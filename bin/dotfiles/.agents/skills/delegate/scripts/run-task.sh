#!/usr/bin/env bash
#
# run-task.sh <step-dir> <workdir> [brief]
#
# Hands one step to Antigravity headlessly and records the run, so every
# delegation leaves the same artifacts regardless of which designer (Claude
# or Codex) drove it:
#
#   <step-dir>/prompt-<n>.md   exact prompt sent (project dir + brief + run rules/report format)
#   <step-dir>/run-<n>.jsonl   agy stream-json event log
#   <step-dir>/stderr-<n>.log  agy diagnostics
#   <step-dir>/report-<n>.md   Antigravity's final response (the report)
#   <task-dir>/metrics.jsonl   one row per run, including the actual model
#                              and the co-author trailer to commit with
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

{
  cat <<EOF
# Project directory

The project for this step is \`$workdir\`. It is not your current
directory, so use absolute paths with your file tools and run shell
commands as \`cd $workdir && <command>\`. Read its AGENTS.md first, if
there is one.

EOF
  cat "$brief"
  printf '\n'
  cat "$skill_dir/templates/report.md"
} >"$prompt"

# agy mounts every workspace folder (its cwd and any --add-dir) read-only
# inside the terminal sandbox in headless runs, whatever settings.json
# allows. So run it from an empty scratch dir and leave the project out of
# the workspace: file edits then go through the write_file permissions, and
# sandboxed commands (formatters, builds, tests) can write to the project.
# Commands run only inside the sandbox (settings.json: proceed-in-sandbox),
# so the run never needs a blanket permission bypass.
agy_cwd="$(mktemp -d "${TMPDIR:-/tmp}/agy-cwd.XXXXXX")"
trap 'rmdir "$agy_cwd" 2>/dev/null || true' EXIT
args=(-p "$(cat "$prompt")" --output-format stream-json --mode accept-edits
  --disable-slash-commands --print-timeout "${AGY_TIMEOUT:-30m}")
model_args=()
[ -n "${AGY_MODEL:-}" ] && model_args+=(--model "$AGY_MODEL")
[ -n "${AGY_EFFORT:-}" ] && model_args+=(--effort "$AGY_EFFORT")
args+=("${model_args[@]}")

# Ask agy which model this run will use rather than trusting AGY_MODEL or
# guessing: the commit's co-author trailer must name the actual model, and
# an unset AGY_MODEL means whatever settings.json selects. Print-mode
# /model answers without a turn or quota.
model_json="$( (cd "$agy_cwd" && timeout 60 agy -p "/model" --output-format json \
  "${model_args[@]}" </dev/null 2>/dev/null) | jq -c '.command.data // empty' 2>/dev/null || true)"
[ -n "$model_json" ] || model_json='{}'
model_id="$(jq -r '.id // "unknown"' <<<"$model_json")"
# "Gemini 3.1 Pro (High)" -> "Gemini 3.1 Pro": the effort suffix is a run
# setting, not part of the model's name.
model_name="$(jq -r '.label // "unknown" | sub(" \\([^)]*\\)$"; "")' <<<"$model_json")"
trailer="Co-authored-by: Antigravity ($model_name) <noreply@google.com>"

echo "==> step $(basename "$step_dir"), attempt $attempt: running agy ($model_id) on $workdir"
set +e
(cd "$agy_cwd" && agy "${args[@]}" </dev/null) >"$run" 2>"$stderr"
rc=$?
set -e

result="$(jq -c -R 'fromjson? | select(.event == "result") | .result' "$run" | tail -n 1)"
[ -n "$result" ] || result='{}'
jq -r '.response // empty' <<<"$result" >"$report"

# Tool calls explicitly denied by a permission rule or headless approval.
# Other ERROR steps can mention "permissions" while reporting a different
# failure, so match denial language rather than that word alone.
denied="$(jq -R 'fromjson? | select(.event == "step_update") | .step_update
  | select(.state == "ERROR" and ((.tool_info.error.message // "")
    | test("denied|not permitted|requires approval|approval required"; "i")))' \
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
  --arg model "$model_id" \
  --arg trailer "$trailer" \
  --argjson exit_code "$rc" \
  --argjson denied "$denied" \
  --argjson report_empty "$report_empty" \
  --argjson r "$result" \
  '{ts: $ts, task: $task, step: $step, attempt: $attempt, variant: $variant,
    harness_rev: $harness_rev, designer: $designer, model: $model,
    trailer: $trailer,
    exit_code: $exit_code, status: ($r.status // "NO_RESULT"),
    denied_tool_calls: $denied, report_empty: $report_empty,
    duration_seconds: $r.duration_seconds, num_turns: $r.num_turns,
    usage: $r.usage, conversation_id: $r.conversation_id}' \
  >>"$task_dir/metrics.jsonl"

status="$(jq -r '.status // "NO_RESULT"' <<<"$result")"
echo "==> status: $status (exit $rc)"
echo "    report: $report"
echo "    log:    $run"
echo "    trailer for the commit: $trailer"
if [ "$denied" -gt 0 ]; then
  echo "==> warning: $denied tool call(s) denied; the report's verification may be incomplete"
fi
if [ "$report_empty" = true ]; then
  echo "==> warning: no report was returned; see $stderr"
fi
echo "==> working tree:"
git -C "$workdir" status --short || true
[ "$status" = "SUCCESS" ] && [ "$report_empty" = false ]
