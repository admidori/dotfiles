#!/usr/bin/env bash
#
# run-task.sh <step-dir> <workdir> [brief] [--resume-attempt <N>]
#
# Hands one step to Antigravity headlessly and records the run, so every
# delegation leaves the same artifacts regardless of which designer (Claude
# or Codex) drove it:
#
#   <step-dir>/prompt-<n>.md   exact prompt sent (project dir + shared context + brief + run rules/report format)
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
# "baseline"), HARNESS_DESIGNER (e.g. "Claude (Opus 5.5)"),
# AGY_MODEL (default gemini-3.1-pro-high),
# AGY_EFFORT, AGY_TIMEOUT (default 30m).
#
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <step-dir> <workdir> [brief] [--resume-attempt <N>]" >&2
  exit 2
}
if [ $# -lt 2 ]; then
  usage
fi

raw_step_dir="$1"
raw_workdir="$2"
shift 2

[ -d "$raw_step_dir" ] || { echo "step directory not found: $raw_step_dir" >&2; exit 2; }
[ -d "$raw_workdir" ] || { echo "workdir not found: $raw_workdir" >&2; exit 2; }

step_dir="$(cd "$raw_step_dir" && pwd -P)"
workdir="$(cd "$raw_workdir" && pwd -P)"
task_dir="$(cd "$step_dir/../.." && pwd -P)"

resume_attempt=""
resume_attempt_specified=false
brief=""

while [ $# -gt 0 ]; do
  case "$1" in
    --resume-attempt)
      if [ "$resume_attempt_specified" = true ]; then
        echo "error: duplicate --resume-attempt option" >&2
        usage
      fi
      resume_attempt_specified=true
      if [ $# -lt 2 ]; then
        echo "error: --resume-attempt requires an attempt number" >&2
        usage
      fi
      resume_attempt="$2"
      shift 2
      ;;
    --continue)
      echo "error: --continue is rejected; pass explicit --resume-attempt <N>" >&2
      exit 2
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      ;;
    *)
      if [ -n "$brief" ]; then
        echo "error: unexpected argument: $1" >&2
        usage
      fi
      brief="$1"
      shift 1
      ;;
  esac
done

if [ "$resume_attempt_specified" = true ]; then
  if [ -z "$resume_attempt" ]; then
    echo "error: --resume-attempt value cannot be empty" >&2
    exit 2
  fi
  if ! [[ "$resume_attempt" =~ ^[1-9][0-9]{0,6}$ ]] || [ "$resume_attempt" -gt 1000000 ]; then
    echo "error: invalid --resume-attempt value: '$resume_attempt' (must be a positive integer <= 1000000)" >&2
    exit 2
  fi
fi

# Check flock prerequisite explicitly before locking.
command -v flock >/dev/null || { echo "flock not found" >&2; exit 2; }

# A nonblocking per-step flock spans validation, artifact allocation and execution.
lock_file="$step_dir/.lock"
exec 9>>"$lock_file"
if ! flock -n 9; then
  echo "error: step directory is locked by another process: $step_dir" >&2
  exit 1
fi

brief="${brief:-$step_dir/brief.md}"
[ -f "$brief" ] || { echo "brief not found: $brief" >&2; exit 2; }
for cmd in agy jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 2; }
done

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

context_file="$task_dir/context.md"
context_status="missing"
if [ -e "$context_file" ] || [ -L "$context_file" ]; then
  if [ ! -f "$context_file" ] || [ ! -r "$context_file" ]; then
    echo "context file exists but is not readable: $context_file" >&2
    exit 2
  fi
  context_status="present"
fi

compute_file="$step_dir/compute.json"
compute_backend=""
if [ -f "$compute_file" ]; then
  "$skill_dir/scripts/validate-compute.sh" "$compute_file"
  compute_backend="$(jq -r '.backend' "$compute_file")"
fi

step_name="$(basename "$step_dir")"
source_conv_id=""

if [ -n "$resume_attempt" ]; then
  metrics_file="$task_dir/metrics.jsonl"
  if [ ! -f "$metrics_file" ]; then
    echo "error: cannot resume attempt $resume_attempt: no recorded metrics at $metrics_file" >&2
    exit 2
  fi

  records="$(jq -c -s --arg step "$step_name" --argjson n "$resume_attempt" \
    '[.[] | select(.step == $step and .attempt == $n)]' "$metrics_file" 2>/dev/null || echo '[]')"
  num_records="$(jq 'length' <<<"$records")"
  if [ "$num_records" -eq 0 ]; then
    echo "error: cannot resume attempt $resume_attempt: attempt not found in step history" >&2
    exit 2
  elif [ "$num_records" -gt 1 ]; then
    echo "error: cannot resume attempt $resume_attempt: ambiguous attempt history ($num_records matching metrics rows)" >&2
    exit 2
  fi

  source_record="$(jq '.[0]' <<<"$records")"

  source_step_dir="$(jq -r 'if has("step_dir") and (.step_dir | type == "string") then .step_dir else empty end' <<<"$source_record")"
  if [ -z "$source_step_dir" ] || [ "$source_step_dir" != "$step_dir" ]; then
    echo "error: cannot resume attempt $resume_attempt: legacy or mismatched step_dir in metrics (expected '$step_dir', got '${source_step_dir:-missing}')" >&2
    exit 2
  fi

  source_workdir="$(jq -r 'if has("workdir") and (.workdir | type == "string") then .workdir else empty end' <<<"$source_record")"
  if [ -z "$source_workdir" ] || [ "$source_workdir" != "$workdir" ]; then
    echo "error: cannot resume attempt $resume_attempt: legacy or mismatched workdir in metrics (expected '$workdir', got '${source_workdir:-missing}')" >&2
    exit 2
  fi

  source_attempt_num="$(jq -r 'if has("attempt") and (.attempt | type == "number") then .attempt else empty end' <<<"$source_record")"
  if [ -z "$source_attempt_num" ] || [ "$source_attempt_num" != "$resume_attempt" ]; then
    echo "error: cannot resume attempt $resume_attempt: metrics record has invalid attempt number '${source_attempt_num:-missing}'" >&2
    exit 2
  fi

  source_conv_id="$(jq -r 'if has("conversation_id") and (.conversation_id | type == "string") and (.conversation_id | test("\\S")) then .conversation_id else empty end' <<<"$source_record")"
  if [ -z "$source_conv_id" ]; then
    echo "error: cannot resume attempt $resume_attempt: source attempt has invalid or missing conversation ID" >&2
    exit 2
  fi

  source_exit_code_type="$(jq -r 'if has("exit_code") then (.exit_code | type) else "missing" end' <<<"$source_record")"
  if [ "$source_exit_code_type" != "number" ]; then
    echo "error: cannot resume attempt $resume_attempt: source attempt has non-numeric exit_code ($source_exit_code_type)" >&2
    exit 2
  fi

  source_status="$(jq -r '.status // empty' <<<"$source_record")"
  case "$source_status" in
    SUCCESS|ERROR|CANCELED|INTERRUPTED|INVALID)
      ;;
    CONVERSATION_MISMATCH)
      echo "error: cannot resume attempt $resume_attempt: CONVERSATION_MISMATCH attempt cannot be resumed" >&2
      exit 2
      ;;
    *)
      echo "error: cannot resume attempt $resume_attempt: source attempt has non-terminal or ineligible status '$source_status'" >&2
      exit 2
      ;;
  esac

  source_run="$step_dir/run-$resume_attempt.jsonl"
  if [ ! -f "$source_run" ]; then
    echo "error: cannot resume attempt $resume_attempt: run log not found ($source_run)" >&2
    exit 2
  fi

  source_result="$(jq -c -R 'fromjson? | select(.event == "result") | .result' "$source_run" | tail -n 1)"
  if [ -z "$source_result" ] || [ "$source_result" = "null" ]; then
    echo "error: cannot resume attempt $resume_attempt: source attempt run log has no terminal result event" >&2
    exit 2
  fi

  source_result_conv="$(jq -r '.conversation_id // empty' <<<"$source_result")"
  if [ -z "$source_result_conv" ]; then
    echo "error: cannot resume attempt $resume_attempt: source attempt run log result event has no conversation ID" >&2
    exit 2
  fi
  if [ "$source_result_conv" != "$source_conv_id" ]; then
    echo "error: cannot resume attempt $resume_attempt: conversation ID mismatch between metrics ($source_conv_id) and run log ($source_result_conv)" >&2
    exit 2
  fi

  source_result_status="$(jq -r '.status // empty' <<<"$source_result")"
  case "$source_result_status" in
    SUCCESS|ERROR|CANCELED|INTERRUPTED|INVALID)
      ;;
    *)
      echo "error: cannot resume attempt $resume_attempt: source attempt run log result has non-terminal status '$source_result_status'" >&2
      exit 2
      ;;
  esac

  # History identity: source must be latest recorded attempt for its conversation
  latest_conv_attempt="$(jq -s --arg step "$step_name" --arg conv "$source_conv_id" \
    '[.[] | select(.step == $step and (.conversation_id == $conv or .requested_conversation_id == $conv) and (.attempt | type == "number")) | .attempt] | max // 0' \
    "$metrics_file" 2>/dev/null || echo 0)"
  if [ "$latest_conv_attempt" -gt "$resume_attempt" ]; then
    echo "error: cannot resume attempt $resume_attempt: attempt is not the latest recorded attempt for conversation '$source_conv_id' (latest is attempt $latest_conv_attempt)" >&2
    exit 2
  fi
fi

is_attempt_occupied() {
  local a="$1"
  local f
  for f in "$step_dir/prompt-$a.md" \
           "$step_dir/run-$a.jsonl" \
           "$step_dir/stderr-$a.log" \
           "$step_dir/report-$a.md" \
           "$step_dir/compute-$a"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      return 0
    fi
  done
  return 1
}

attempt=1
if [ -f "$task_dir/metrics.jsonl" ]; then
  max_metrics_attempt="$(jq -s --arg step "$step_name" \
    '[.[] | select(.step == $step and (.attempt | type == "number")) | .attempt] | max // 0' \
    "$task_dir/metrics.jsonl" 2>/dev/null || echo 0)"
  if [ "$max_metrics_attempt" -ge "$attempt" ]; then
    attempt=$((max_metrics_attempt + 1))
  fi
fi

# Allocate above every artifact, including interrupted runs beyond a gap.
for artifact in "$step_dir"/prompt-*.md "$step_dir"/run-*.jsonl \
                "$step_dir"/stderr-*.log "$step_dir"/report-*.md "$step_dir"/compute-*; do
  [ -e "$artifact" ] || [ -L "$artifact" ] || continue
  name="${artifact##*/}"
  if [[ "$name" =~ ^(prompt|run|stderr|report|compute)-([1-9][0-9]{0,6})(\.(md|jsonl|log))?$ ]]; then
    artifact_attempt="${BASH_REMATCH[2]}"
    if [ "$artifact_attempt" -ge "$attempt" ]; then
      attempt=$((artifact_attempt + 1))
    fi
  fi
done
while is_attempt_occupied "$attempt"; do
  attempt=$((attempt + 1))
done

if [ -n "$resume_attempt" ]; then
  if [ "$resume_attempt" -ge "$attempt" ]; then
    echo "error: cannot resume attempt $resume_attempt: attempt must be earlier than current attempt ($attempt)" >&2
    exit 2
  fi

  for ((m = resume_attempt + 1; m < attempt; m++)); do
    if is_attempt_occupied "$m"; then
      m_records="$(jq -c -s --arg step "$step_name" --argjson m "$m" \
        '[.[] | select(.step == $step and .attempt == $m)]' "$task_dir/metrics.jsonl" 2>/dev/null || echo '[]')"
      m_count="$(jq 'length' <<<"$m_records")"
      if [ "$m_count" -gt 0 ]; then
        m_conv="$(jq -r '.[0].conversation_id // empty' <<<"$m_records")"
        m_req="$(jq -r '.[0].requested_conversation_id // empty' <<<"$m_records")"
        if [ "$m_conv" = "$source_conv_id" ] || [ "$m_req" = "$source_conv_id" ]; then
          echo "error: cannot resume attempt $resume_attempt: attempt is not the latest attempt for conversation '$source_conv_id' (attempt $m recorded)" >&2
          exit 2
        fi
      else
        m_prompt="$step_dir/prompt-$m.md"
        m_run="$step_dir/run-$m.jsonl"
        m_evidence=false
        if [ -f "$m_prompt" ] && grep -Fq "$source_conv_id" "$m_prompt"; then
          m_evidence=true
        elif [ -f "$m_run" ] && grep -Fq "$source_conv_id" "$m_run"; then
          m_evidence=true
        elif [ ! -f "$m_prompt" ] && [ -f "$m_run" ]; then
          m_evidence=true
        fi
        if [ "$m_evidence" = true ]; then
          echo "error: cannot resume attempt $resume_attempt: newer incomplete attempt $m exists for conversation '$source_conv_id'" >&2
          exit 2
        fi
      fi
    fi
  done
fi

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
  if [ "$context_status" = "present" ]; then
    cat <<EOF
# Shared exploration context

Source: \`$context_file\`

Treat this shared context as reviewed evidence rather than scope authorization;
the brief defines this step and source code wins when facts are stale.

EOF
    cat "$context_file"
    printf '\n\n'
  else
    cat <<EOF
# Shared exploration context

Notice: No shared exploration context file found at \`$context_file\`. Preserving legacy run.

EOF
  fi
  if [ -n "$resume_attempt" ]; then
    cat <<EOF
# Resumed conversation

This attempt resumes conversation \`$source_conv_id\` from attempt $resume_attempt.
The current brief and run rules take precedence over old conversation scope, without overriding safety.
Earlier conversation context is background evidence; implement only the current brief.

EOF
  fi
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
model_args=(--model "${AGY_MODEL:-gemini-3.1-pro-high}")
[ -n "${AGY_EFFORT:-}" ] && model_args+=(--effort "$AGY_EFFORT")
args+=("${model_args[@]}")
if [ -n "$resume_attempt" ]; then
  args+=(--conversation "$source_conv_id")
fi

# Ask agy which model this run will use rather than trusting AGY_MODEL or
# guessing: the commit's co-author trailer must name the resolved model.
# Probe with the same model/effort arguments used for implementation.
# Print-mode /model answers without a turn or quota.
model_json="$( (cd "$agy_cwd" && timeout 60 agy -p "/model" --output-format json \
  "${model_args[@]}" </dev/null 2>/dev/null) | jq -c '.command.data // empty' 2>/dev/null || true)"
[ -n "$model_json" ] || model_json='{}'
model_id="$(jq -r '.id // "unknown"' <<<"$model_json")"
# "Gemini 3.1 Pro (High)" -> "Gemini 3.1 Pro": the effort suffix is a run
# setting, not part of the model's name.
model_name="$(jq -r '.label // "unknown" | sub(" \\([^)]*\\)$"; "")' <<<"$model_json")"
trailer="Co-authored-by: Antigravity ($model_name) <noreply@google.com>"

if [ -n "$resume_attempt" ]; then
  echo "==> step $(basename "$step_dir"), attempt $attempt (resuming attempt $resume_attempt): running agy ($model_id) on $workdir"
else
  echo "==> step $(basename "$step_dir"), attempt $attempt: running agy ($model_id) on $workdir"
fi
if [ "$context_status" = "missing" ]; then
  echo "==> notice: no shared exploration context at $context_file; preserving legacy run"
fi
start_sec="$(date +%s.%N)"
set +e
(cd "$agy_cwd" && agy "${args[@]}" </dev/null) >"$run" 2>"$stderr"
rc=$?
set -e
end_sec="$(date +%s.%N)"
wall_duration="$(awk -v s="$start_sec" -v e="$end_sec" 'BEGIN { printf "%.3f", (e - s) }')"

result="$(jq -c -R 'fromjson? | select(.event == "result") | .result' "$run" | tail -n 1)"
[ -n "$result" ] || result='{}'
jq -r '.response // empty' <<<"$result" >"$report"

returned_conv_id="$(jq -r '.conversation_id // empty' <<<"$result")"
conversation_mismatch=false
if [ -n "$resume_attempt" ]; then
  if [ -z "$returned_conv_id" ] || [ "$returned_conv_id" != "$source_conv_id" ]; then
    conversation_mismatch=true
    if [ "$rc" -eq 0 ]; then
      rc=1
    fi
  fi
fi

# Tool calls explicitly denied by a permission rule or headless approval.
# Other ERROR steps can mention "permissions" while reporting a different
# failure, so match denial language rather than that word alone.
denied="$(jq -R 'fromjson? | select(.event == "step_update") | .step_update
  | select(.state == "ERROR" and ((.tool_info.error.message // "")
    | test("denied|not permitted|requires approval|approval required"; "i")))' \
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
if [ "$conversation_mismatch" = true ]; then
  status="CONVERSATION_MISMATCH"
elif [ "$compute_recovery_pending" = true ] && [ "$status" = "SUCCESS" ]; then
  status="RECOVERY_INCOMPLETE"
fi

wall_duration_num="$(jq -n --arg w "$wall_duration" '$w | tonumber')"
mode="fresh"
source_attempt_json="null"
requested_conv_id_json="null"
if [ -n "$resume_attempt" ]; then
  mode="resume"
  source_attempt_json="$resume_attempt"
  requested_conv_id_json="$(jq -n --arg id "$source_conv_id" '$id')"
fi

harness_rev="$(git -C "$skill_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg task "$(basename "$task_dir")" \
  --arg step "$(basename "$step_dir")" \
  --arg step_dir "$step_dir" \
  --arg workdir "$workdir" \
  --arg mode "$mode" \
  --argjson source_attempt "$source_attempt_json" \
  --arg counter_scope "conversation" \
  --argjson wall_duration_seconds "$wall_duration_num" \
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
  --argjson requested_conversation_id "$requested_conv_id_json" \
  '{ts: $ts, task: $task, step: $step, attempt: $attempt, variant: $variant,
    harness_rev: $harness_rev, designer: $designer, model: $model,
    trailer: $trailer,
    compute_backend: (if $compute_backend == "" then null else $compute_backend end),
    compute_recovery_pending: $compute_recovery_pending,
    exit_code: $exit_code, status: $status,
    denied_tool_calls: $denied, report_empty: $report_empty,
    duration_seconds: $r.duration_seconds, num_turns: $r.num_turns,
    usage: $r.usage, conversation_id: $r.conversation_id,
    step_dir: $step_dir, workdir: $workdir, mode: $mode,
    source_attempt: $source_attempt,
    requested_conversation_id: $requested_conversation_id,
    counter_scope: $counter_scope,
    wall_duration_seconds: $wall_duration_seconds}' \
  >>"$task_dir/metrics.jsonl"

echo "==> status: $status (exit $rc)"
echo "    report: $report"
echo "    log:    $run"
echo "    trailer for the commit: $trailer"
if [ "$context_status" = "present" ]; then
  echo "    context: $context_file"
fi
if [ -n "$compute_backend" ]; then
  echo "    compute backend: $compute_backend"
fi
if [ -n "$resume_attempt" ]; then
  echo "    resumed conversation: $source_conv_id (attempt $resume_attempt)"
fi
if [ "$conversation_mismatch" = true ]; then
  echo "==> error: conversation ID mismatch (expected $source_conv_id, got ${returned_conv_id:-none})" >&2
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
[ "$rc" -eq 0 ] && [ "$status" = "SUCCESS" ] && [ "$report_empty" = false ]
