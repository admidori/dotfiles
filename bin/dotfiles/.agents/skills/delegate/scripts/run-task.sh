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

compute_file="$step_dir/compute.json"
compute_backend=""
if [ -f "$compute_file" ]; then
  "$skill_dir/scripts/validate-compute.sh" "$compute_file"
  compute_backend="$(jq -r '.backend' "$compute_file")"
fi

attempt=1
while [ -e "$step_dir/run-$attempt.jsonl" ]; do
  attempt=$((attempt + 1))
done
prompt="$step_dir/prompt-$attempt.md"
run="$step_dir/run-$attempt.jsonl"
stderr="$step_dir/stderr-$attempt.log"
report="$step_dir/report-$attempt.md"

compute_state_resolved() {
  jq -e 'type == "object" and (
    (.phase == "initialized" and .job_id == null) or
    .release_outcome == "released" or
    (.release_outcome == "preserved" and
      (.release_reason | type == "string" and test("\\S")))
  )' "$1" >/dev/null 2>&1
}

# Recovery also applies when this run changes or removes the compute manifest.
compute_recovery_files=()
for previous_state in "$step_dir"/compute-*/state.json; do
  [ -f "$previous_state" ] || continue
  if ! compute_state_resolved "$previous_state"; then
    compute_recovery_files+=("$previous_state")
  fi
done

if [ -n "$compute_backend" ]; then
  compute_dir="$step_dir/compute-$attempt"
  mkdir -p "$compute_dir/artifacts"
  compute_state_file="$compute_dir/state.json"
  compute_events_file="$compute_dir/events.jsonl"
  compute_artifacts_dir="$compute_dir/artifacts"
  compute_target="$(jq -r '.target' "$compute_file")"
  if [ ! -f "$compute_state_file" ]; then
    jq -n \
      --arg backend "$compute_backend" \
      --arg target "$compute_target" \
      --argjson attempt "$attempt" \
      '{backend: $backend, target: $target, job_id: null, phase: "initialized", attempt: $attempt, release_outcome: null}' \
      >"$compute_state_file"
  fi
  touch "$compute_events_file"
fi

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
  if [ -n "$compute_backend" ]; then
    compute_timeout="$(jq -r '.timeout_seconds' "$compute_file")"
    compute_attempts="$(jq -r '.max_attempts' "$compute_file")"
    cat <<EOF
# Remote GPU compute manifest

A compute manifest is configured for this step (\`compute.json\`):

\`\`\`json
$(cat "$compute_file")
\`\`\`

## Remote compute lifecycle & rules

Follow the bounded compute lifecycle: probe -> acquire -> stage -> execute -> observe -> diagnose -> collect -> release.

### Attempt audit paths
- Compute audit directory: \`$compute_dir\`
- Lifecycle state file: \`$compute_state_file\`
- Remote events log: \`$compute_events_file\`
- Artifacts directory: \`$compute_artifacts_dir\`

You MUST update the lifecycle state file (\`$compute_state_file\`) immediately after acquisition/job creation and on every lifecycle transition.
Neither \`state.json\` nor \`events.jsonl\` may contain credentials, tokens, dataset contents, or other secrets.
The state file must record:
- \`backend\`: "$compute_backend"
- \`target\`: remote target/session identifier
- \`job_id\`: remote job or kernel execution ID
- \`phase\`: current lifecycle phase (probe, acquire, stage, execute, observe, diagnose, collect, release, completed, failed)
- \`attempt\`: $attempt
- \`release_outcome\`: outcome of release ("released" or "preserved")
- \`release_reason\`: nonempty reason when release_outcome is "preserved"

Record remote execution lifecycle transitions and milestones to \`$compute_events_file\`. Neither \`state.json\` nor \`events.jsonl\` may contain credentials, tokens, dataset contents, or other secrets.
All collected output artifacts MUST be stored in \`$compute_artifacts_dir\`, NOT in the source worktree unless a later reviewed step explicitly promotes one.

### Backend-specific staging rules: $compute_backend
EOF
    if [ "$compute_backend" = "coder" ]; then
      cat <<EOF
- Use Coder MCP tools to interact with the remote Coder workspace.
- Upload/stage required local files and tarballs from the local worktree to the remote workspace.
- Remote edits are disposable: code fixes MUST be made in the local worktree and restaged. Never retain code changes only in the remote workspace.
- Execute remote commands and observe execution progress and logs.
- Collect output artifacts into \`$compute_artifacts_dir\`, not into the source worktree.
- Clean up remote workspace resources upon completion or failure, and record release outcome.
EOF
    elif [ "$compute_backend" = "colab" ]; then
      cat <<EOF
- Use official Google Colab MCP (\`colab-mcp\`) tools to interact with the notebook session.
- Google's official Colab MCP is notebook-oriented: inject listed scripts from the manifest (\`scripts\`) into notebook cells or execute cells.
- Scripts may be injected only from the manifest; datasets use the declared URIs (\`datasets\`). Never claim a general directory-sync capability or inline dataset contents.
- Remote edits are disposable: code fixes MUST be made in the local worktree and restaged. Never treat the remote notebook as the authoritative source tree.
- Colab artifact semantics: Official \`googlecolab/colab-mcp\` exposes notebook cells and outputs, not a general binary download/directory-sync API.
- Bounded text/JSON results may be emitted as cell output and written into \`$compute_artifacts_dir\`, not into the source worktree.
- Large or binary artifacts must be uploaded by notebook code to an operator-declared external destination, or reported as not collected. Never base64-inline them into prompts or cell output.
- Do not promise or expect that arbitrary Colab artifact paths will be downloaded to the local harness.
- Ephemeral release guarantee: Release and disconnect the Colab session and runtime upon completion or failure. If the connected client cannot release the runtime, record \`preserved\` with the reason instead of claiming it was released.
EOF
    fi
    cat <<EOF

### Retry and release requirements
- Maximum attempts: $compute_attempts. Bounded retries only: diagnose failures before retrying.
- Timeout limit: $compute_timeout seconds.
- Ephemeral release guarantee: Remote compute resources MUST be released/terminated upon step completion or failure (or record \`preserved\` with reason if unreleaseable). Do not leave running jobs or orphaned sessions.
- Local source of truth: The local worktree is the only source of truth. All fixes, edits, and commits remain local.
- Audit recording: Maintain \`$compute_state_file\` and \`$compute_events_file\`. Neither \`state.json\` nor \`events.jsonl\` may contain credentials, tokens, dataset contents, or other secrets. Include all compute audit fields in your implementation report.

EOF
  fi
  if [ "${#compute_recovery_files[@]}" -gt 0 ]; then
    cat <<'EOF'
# Recover unresolved compute attempts before acquiring new resources

Earlier attempts left remote resources unresolved. Read each state file and
its sibling events.jsonl, then use that state's backend, target, and job_id
to observe and stop/release the old job or session before any new acquire.
Do not assume the current manifest identifies the old backend or target.
Update the old state and event log with the recovery outcome. Record
release_outcome="released", or release_outcome="preserved" with a nonempty
release_reason if release is unavailable. Honor explicitly requested
preservation. If recovery cannot be established, report the blocker rather
than claiming success. Do not erase old state or overwrite it with a new job.
Include the recovery outcomes in your implementation report.

EOF
    for previous_state in "${compute_recovery_files[@]}"; do
      printf -- "- Previous state file: \`%s\`\n" "$previous_state"
      jq -c '{backend, target, job_id, phase, release_outcome, release_reason}' "$previous_state" \
        || printf '  State is unreadable; inspect and recover it explicitly.\n'
    done
    printf '\n'
  fi
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

# Tool calls refused by a permission rule, or auto-denied because a headless
# run can't prompt. They show up only as ERROR steps in the event log, and a
# denied run can end with an empty response, so count them explicitly.
denied="$(jq -R 'fromjson? | select(.event == "step_update") | .step_update
  | select(.state == "ERROR" and ((.tool_info.error.message // "") | test("[Pp]ermission")))' \
  "$run" | jq -s 'length')"
report_empty=false
[ -s "$report" ] || report_empty=true

compute_recovery_pending=false
for previous_state in "${compute_recovery_files[@]}"; do
  if ! compute_state_resolved "$previous_state"; then
    compute_recovery_pending=true
  fi
done
status="$(jq -r '.status // "NO_RESULT"' <<<"$result")"
if [ "$compute_recovery_pending" = true ] && [ "$status" = "SUCCESS" ]; then
  status="RECOVERY_INCOMPLETE"
fi

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
  --arg compute_backend "$compute_backend" \
  --arg status "$status" \
  --argjson compute_recovery_pending "$compute_recovery_pending" \
  --argjson exit_code "$rc" \
  --argjson denied "$denied" \
  --argjson report_empty "$report_empty" \
  --argjson r "$result" \
  '{ts: $ts, task: $task, step: $step, attempt: $attempt, variant: $variant,
    harness_rev: $harness_rev, designer: $designer, model: $model,
    trailer: $trailer,
    compute_backend: (if $compute_backend == "" then null else $compute_backend end),
    compute_recovery_pending: $compute_recovery_pending,
    exit_code: $exit_code, status: $status,
    denied_tool_calls: $denied, report_empty: $report_empty,
    duration_seconds: $r.duration_seconds, num_turns: $r.num_turns,
    usage: $r.usage, conversation_id: $r.conversation_id}' \
  >>"$task_dir/metrics.jsonl"

echo "==> status: $status (exit $rc)"
echo "    report: $report"
echo "    log:    $run"
echo "    trailer for the commit: $trailer"
if [ -n "$compute_backend" ]; then
  echo "    compute backend: $compute_backend"
fi
if [ "$denied" -gt 0 ]; then
  echo "==> warning: $denied tool call(s) denied; the report's verification may be incomplete"
fi
if [ "$report_empty" = true ]; then
  echo "==> warning: no report was returned; see $stderr"
fi
if [ "$compute_recovery_pending" = true ]; then
  echo "==> warning: prior compute attempts remain unresolved; see $prompt"
fi
echo "==> working tree:"
git -C "$workdir" status --short || true
[ "$status" = "SUCCESS" ] && [ "$report_empty" = false ]
