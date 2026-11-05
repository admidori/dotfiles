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
# Env: HARNESS_EXECUTION_MODE (host|docker-sandbox, default host),
# HARNESS_VARIANT (label for comparing harness changes, default
# "baseline"), HARNESS_DESIGNER (e.g. "Claude (Opus 5.5)"),
# AGY_MODEL (default gemini-3.8-flash-high),
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

# Validate AGY_TIMEOUT before locking or allocating artifacts
agy_timeout_raw="${AGY_TIMEOUT:-}"
if [ -z "$agy_timeout_raw" ]; then
  agy_timeout_str="30m"
  agy_timeout_seconds=1800
elif [[ "$agy_timeout_raw" =~ ^[0-9]+$ ]]; then
  minutes="$((10#$agy_timeout_raw))"
  if [ "$minutes" -le 0 ]; then
    echo "error: invalid AGY_TIMEOUT '$agy_timeout_raw' (use e.g. 40m, 1h30m, 90s, or minutes as a bare number)" >&2
    exit 2
  fi
  agy_timeout_str="${agy_timeout_raw}m"
  agy_timeout_seconds=$((minutes * 60))
elif [[ "$agy_timeout_raw" =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ ]]; then
  h_part="${BASH_REMATCH[2]:-}"
  m_part="${BASH_REMATCH[4]:-}"
  s_part="${BASH_REMATCH[6]:-}"
  if [ -z "$h_part" ] && [ -z "$m_part" ] && [ -z "$s_part" ]; then
    echo "error: invalid AGY_TIMEOUT '$agy_timeout_raw' (use e.g. 40m, 1h30m, 90s, or minutes as a bare number)" >&2
    exit 2
  fi
  h_sec=0
  m_sec=0
  s_sec=0
  [ -n "$h_part" ] && h_sec=$((10#$h_part * 3600))
  [ -n "$m_part" ] && m_sec=$((10#$m_part * 60))
  [ -n "$s_part" ] && s_sec=$((10#$s_part))
  agy_timeout_seconds=$((h_sec + m_sec + s_sec))
  if [ "$agy_timeout_seconds" -le 0 ]; then
    echo "error: invalid AGY_TIMEOUT '$agy_timeout_raw' (use e.g. 40m, 1h30m, 90s, or minutes as a bare number)" >&2
    exit 2
  fi
  agy_timeout_str="$agy_timeout_raw"
else
  echo "error: invalid AGY_TIMEOUT '$agy_timeout_raw' (use e.g. 40m, 1h30m, 90s, or minutes as a bare number)" >&2
  exit 2
fi

# The watch loop compares these numerically; a non-number would make the
# grace check never fire and leave the runner waiting forever.
grace_seconds="${AGY_RESULT_GRACE_SECONDS:-30}"
timeout_margin_seconds="${AGY_TIMEOUT_MARGIN_SECONDS:-300}"
for knob in AGY_RESULT_GRACE_SECONDS:"$grace_seconds" AGY_TIMEOUT_MARGIN_SECONDS:"$timeout_margin_seconds"; do
  if ! [[ "${knob#*:}" =~ ^[0-9]{1,6}$ ]]; then
    echo "error: invalid ${knob%%:*} '${knob#*:}' (whole seconds expected)" >&2
    exit 2
  fi
done
grace_seconds=$((10#$grace_seconds))
timeout_margin_seconds=$((10#$timeout_margin_seconds))

# Validate execution mode before locking or allocating artifacts
execution_mode="${HARNESS_EXECUTION_MODE:-host}"
case "$execution_mode" in
  host)
    ;;
  docker-sandbox)
    if [ -z "${SANDBOX_ID:-}" ] || [ -z "${SANDBOX_VM_ID:-}" ] || [ -z "${SBX_AGENT:-}" ]; then
      echo "error: docker-sandbox execution mode requires nonempty SANDBOX_ID, SANDBOX_VM_ID, and SBX_AGENT" >&2
      exit 2
    fi
    marker_file="/etc/agent-harness/docker-sandbox"
    if [ ! -e "$marker_file" ] || [ -L "$marker_file" ] || [ ! -f "$marker_file" ]; then
      echo "error: docker-sandbox marker file missing or invalid ($marker_file)" >&2
      exit 2
    fi
    marker_uid="$(stat -c '%u' "$marker_file" 2>/dev/null || echo "unknown")"
    if [ "$marker_uid" != "0" ]; then
      echo "error: docker-sandbox marker file must be owned by root (uid 0), got uid $marker_uid" >&2
      exit 2
    fi
    ;;
  *)
    echo "error: invalid HARNESS_EXECUTION_MODE '$execution_mode' (expected 'host' or 'docker-sandbox')" >&2
    exit 2
    ;;
esac

# Validate git policy before locking or allocating artifacts
git_policy="${HARNESS_GIT_POLICY:-strict}"
case "$git_policy" in
  strict)
    ;;
  task-commits)
    if [ "$execution_mode" != "docker-sandbox" ]; then
      echo "error: HARNESS_GIT_POLICY=task-commits is only supported in docker-sandbox execution mode" >&2
      exit 2
    fi
    ;;
  *)
    echo "error: invalid HARNESS_GIT_POLICY '$git_policy' (expected 'strict' or 'task-commits')" >&2
    exit 2
    ;;
esac

# Check flock prerequisite explicitly before locking.
command -v flock >/dev/null || { echo "flock not found" >&2; exit 2; }

# A nonblocking per-step flock spans validation, artifact allocation and execution.
lock_file="$step_dir/.lock"
exec 9>>"$lock_file"
if ! flock -n 9; then
  echo "error: step directory is locked by another process: $step_dir" >&2
  exit 1
fi

# A nonblocking workdir-level flock prevents concurrent runs against the same workdir.
# Advisory locks can be defeated in full-access environments, but prevent concurrent runner collisions.
workdir_lock_file=""
git_lock_rel="$(git -C "$workdir" rev-parse --git-path harness.lock 2>/dev/null || true)"
if [ -n "$git_lock_rel" ]; then
  if [[ "$git_lock_rel" = /* ]]; then
    workdir_lock_file="$git_lock_rel"
  else
    workdir_lock_file="$workdir/$git_lock_rel"
  fi
else
  harness_state_dir="${AGENT_HARNESS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness}"
  lock_hash="$(printf '%s' "$workdir" | sha256sum | cut -d' ' -f1)"
  workdir_lock_file="$harness_state_dir/locks/${lock_hash}.lock"
fi
mkdir -p "$(dirname "$workdir_lock_file")" 2>/dev/null || true
if ! touch "$workdir_lock_file" 2>/dev/null; then
  harness_state_dir="${AGENT_HARNESS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness}"
  lock_hash="$(printf '%s' "$workdir" | sha256sum | cut -d' ' -f1)"
  workdir_lock_file="$harness_state_dir/locks/${lock_hash}.lock"
  mkdir -p "$(dirname "$workdir_lock_file")" 2>/dev/null || true
  touch "$workdir_lock_file" 2>/dev/null || true
fi
exec 8>>"$workdir_lock_file"
if ! flock -n 8; then
  echo "error: workdir is locked by another process: $workdir" >&2
  exit 1
fi

brief="${brief:-$step_dir/brief.md}"
[ -f "$brief" ] || { echo "brief not found: $brief" >&2; exit 2; }
for cmd in agy jq setsid; do
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

owned_scratch_dir=""
run_cwd=""
mode_flags=()

if [ "$execution_mode" = "host" ]; then
  # agy mounts every workspace folder (its cwd and any --add-dir) read-only
  # inside the terminal sandbox in headless runs, whatever settings.json
  # allows. So run it from an empty scratch dir and leave the project out of
  # the workspace: file edits then go through the write_file permissions, and
  # sandboxed commands (formatters, builds, tests) can write to the project.
  # Commands run only inside the sandbox (settings.json: proceed-in-sandbox),
  # so the run never needs a blanket permission bypass.
  owned_scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/agy-cwd.XXXXXX")"
  run_cwd="$owned_scratch_dir"
  mode_flags=()
else
  # docker-sandbox mode runs directly in the actual workdir with full access bypass flags.
  owned_scratch_dir=""
  run_cwd="$workdir"
  if [ "$git_policy" = "task-commits" ]; then
    settings_json="$(jq -n -c '{
      enableTerminalSandbox: false,
      permissions: {
        deny: ["command(git push)", "command(git merge)"]
      }
    }')"
    mode_flags=(--dangerously-skip-permissions --settings "$settings_json")
  else
    mode_flags=(--dangerously-skip-permissions --settings '{"enableTerminalSandbox":false}')
  fi
fi
agy_pid=""

# Invoked indirectly via traps.
# shellcheck disable=SC2317,SC2329
cleanup_scratch() {
  [ "$$" -eq "$BASHPID" ] || return 0
  if [ -n "${git_snapshot_file:-}" ] && [ -f "${git_snapshot_file:-}" ]; then
    rm -f "$git_snapshot_file" 2>/dev/null || true
  fi
  if [ -n "$owned_scratch_dir" ] && [ -d "$owned_scratch_dir" ] && [ "$owned_scratch_dir" != "$workdir" ]; then
    rmdir "$owned_scratch_dir" 2>/dev/null || rm -rf "$owned_scratch_dir" 2>/dev/null || true
  fi
}

# Check whether any non-zombie process remains in process group <pid>.
# Reads /proc directly: minimal images (e.g. debian:bookworm-slim) ship
# without procps, and a missing `ps` would make every group look gone.
# Zombies are skipped because they linger until reaped (by init in a
# container) yet can no longer do anything.
is_group_active() {
  local pid="$1" f stat rest state pgrp
  for f in /proc/[0-9]*/stat; do
    { read -r stat <"$f"; } 2>/dev/null || continue
    # Fields after the command name, which may itself contain ") ".
    rest="${stat##*) }"
    read -r state _ pgrp _ <<<"$rest"
    [ "$pgrp" = "$pid" ] || continue
    case "$state" in
      Z | X) continue ;;
    esac
    return 0
  done
  return 1
}

terminate_agy_group() {
  local pid="$1"
  [ -z "$pid" ] && return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local i
  for ((i = 0; i < 50; i++)); do
    if ! is_group_active "$pid"; then
      break
    fi
    sleep 0.1
  done
  if is_group_active "$pid" || kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

interrupted_signal=""
runner_interrupted=false
probe_pid=""

# Invoked indirectly via signal traps.
# shellcheck disable=SC2317,SC2329
on_signal() {
  local sig="$1"
  interrupted_signal="$sig"
  if [ -n "${probe_pid:-}" ]; then
    terminate_agy_group "$probe_pid" || true
  fi
  if [ -n "${agy_pid:-}" ]; then
    terminate_agy_group "$agy_pid" || true
  elif [ -z "${attempt:-}" ] && [ -z "${probe_pid:-}" ]; then
    trap - INT TERM EXIT
    cleanup_scratch
    case "$sig" in
      INT) exit 130 ;;
      TERM) exit 143 ;;
      *) exit 1 ;;
    esac
  fi
}

trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'cleanup_scratch' EXIT

effective_model="${AGY_MODEL:-gemini-3.8-flash-high}"
model_args=(--model "$effective_model")
[ -n "${AGY_EFFORT:-}" ] && model_args+=(--effort "$AGY_EFFORT")

git_policy_helper="$skill_dir/scripts/git-task-policy.py"
git_snapshot_file=""

if [ "$execution_mode" = "docker-sandbox" ]; then
  git_snapshot_file="$(mktemp "${TMPDIR:-/tmp}/harness-git-snapshot.XXXXXX")"
  pre_check_cmd=(
    python3 "$git_policy_helper" pre-check
    --workdir "$workdir"
    --policy "$git_policy"
    --snapshot-out "$git_snapshot_file"
  )
  if [ "$git_policy" = "task-commits" ]; then
    pre_check_cmd+=(
      --branch "${HARNESS_TASK_BRANCH:-}"
      --base "${HARNESS_TASK_BASE:-}"
    )
  fi
  if ! "${pre_check_cmd[@]}"; then
    rm -f "$git_snapshot_file"
    git_snapshot_file=""
    exit 2
  fi
fi

# Derive designer label and provenance before agy model probe and attempt allocation.
designer=""
designer_source="unknown"
designer_session_id=""

is_codex_designer_label() {
  local label="$1"
  [ -z "$label" ] || [ "$label" = "unknown" ] || [ "$label" = "Codex" ] || [[ "$label" =~ ^Codex\ \(.*\) ]]
}

if [ -n "${CODEX_THREAD_ID:-}" ] && is_codex_designer_label "${HARNESS_DESIGNER:-}"; then
  resolver_bin="$skill_dir/scripts/resolve-codex-model.py"
  if [ ! -f "$resolver_bin" ]; then
    echo "error: resolver script not found: $resolver_bin" >&2
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 required to resolve Codex model" >&2
    exit 2
  fi

  resolver_err_file="$(mktemp "${TMPDIR:-/tmp}/codex-resolver-err.XXXXXX")"
  if ! resolver_json="$(python3 "$resolver_bin" --json 2>"$resolver_err_file")"; then
    cat "$resolver_err_file" >&2
    rm -f "$resolver_err_file"
    echo "error: failed to resolve Codex model for session ${CODEX_THREAD_ID}" >&2
    exit 2
  fi
  rm -f "$resolver_err_file"

  resolved_model="$(jq -r '.model // empty' <<<"$resolver_json" 2>/dev/null || true)"
  resolved_session="$(jq -r '.session_id // empty' <<<"$resolver_json" 2>/dev/null || true)"
  if [ -z "$resolved_model" ]; then
    echo "error: resolver did not return a valid model" >&2
    exit 2
  fi

  designer="Codex ($resolved_model)"
  designer_source="codex-session"
  designer_session_id="$resolved_session"
elif [ -n "${HARNESS_DESIGNER:-}" ] && [ "${HARNESS_DESIGNER}" != "unknown" ]; then
  designer="$HARNESS_DESIGNER"
  designer_source="provided"
  designer_session_id=""
else
  designer="unknown"
  designer_source="unknown"
  designer_session_id=""
fi

# Ask agy which model this run will use rather than trusting AGY_MODEL or
# guessing: the commit's co-author trailer must name the resolved model.
# Probe with the same model/effort arguments used for implementation.
# Print-mode /model answers without a turn or quota.
probe_out="$(mktemp "${TMPDIR:-/tmp}/harness-model-probe.XXXXXX")"
orig_pwd="$PWD"
cd "$run_cwd"
setsid agy -p "/model" --output-format json "${model_args[@]}" "${mode_flags[@]}" </dev/null >"$probe_out" 2>/dev/null &
probe_pid=$!
cd "$orig_pwd"

probe_rc=0
probe_start="$(date +%s)"
while kill -0 "$probe_pid" 2>/dev/null; do
  if [ -n "$interrupted_signal" ]; then
    terminate_agy_group "$probe_pid" || true
    probe_rc=130
    [ "$interrupted_signal" = "TERM" ] && probe_rc=143
    break
  fi
  now="$(date +%s)"
  if [ $((now - probe_start)) -ge 60 ]; then
    terminate_agy_group "$probe_pid" || true
    probe_rc=124
    break
  fi
  sleep 0.1
done
if [ "$probe_rc" -eq 0 ]; then
  wait "$probe_pid" 2>/dev/null || probe_rc=$?
fi
probe_pid=""

model_json="$(jq -c '.command.data // empty' "$probe_out" 2>/dev/null || true)"
rm -f "$probe_out"
[ -n "$model_json" ] || model_json='{}'
model_id="$(jq -r 'if has("id") and (.id | type == "string") and (.id | test("\\S")) then .id else "unknown" end' <<<"$model_json" 2>/dev/null || echo "unknown")"

if [ -n "$interrupted_signal" ] || [ "$probe_rc" -ne 0 ] || [ -z "$model_id" ] || [ "$model_id" = "unknown" ]; then
  if [ -n "$interrupted_signal" ]; then
    probe_status="INTERRUPTED"
    case "$interrupted_signal" in
      INT) default_runner_rc=130 ;;
      TERM) default_runner_rc=143 ;;
      *) default_runner_rc=1 ;;
    esac
  elif [ "$probe_rc" -eq 124 ]; then
    probe_status="TIMEOUT"
    default_runner_rc=124
  else
    probe_status="MODEL_PROBE_FAILED"
    default_runner_rc=2
  fi

  if [ "$execution_mode" = "docker-sandbox" ]; then
    probe_post_file="$(mktemp "${TMPDIR:-/tmp}/harness-probe-post.XXXXXX")"
    probe_post_rc=0
    python3 "$git_policy_helper" post-check \
      --workdir "$workdir" \
      --policy "$git_policy" \
      --snapshot-in "${git_snapshot_file:-/nonexistent}" \
      --status "$probe_status" \
      --exit-code "$probe_rc" \
      --output-json "$probe_post_file" 2>/dev/null || probe_post_rc=$?

    probe_audit_file="$task_dir/probe-audit.jsonl"
    probe_audit_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "$probe_post_rc" -ne 0 ] || [ ! -s "$probe_post_file" ] || ! jq -e . "$probe_post_file" >/dev/null 2>&1; then
      probe_mutated=true
      probe_outcome="rejected"
      probe_reason="post_check_helper_failed"
      runner_probe_rc=1

      jq -c -n \
        --arg ts "$probe_audit_ts" \
        --arg phase "model_probe" \
        --argjson exit_code "$runner_probe_rc" \
        --argjson probe_exit_code "$probe_rc" \
        --arg status "$probe_status" \
        --arg git_policy "$git_policy" \
        --arg git_policy_outcome "$probe_outcome" \
        --arg git_policy_reason "$probe_reason" \
        --argjson git_state_changed "$probe_mutated" \
        '{ts: $ts, phase: $phase, exit_code: $exit_code, probe_exit_code: $probe_exit_code,
          status: $status, git_policy: $git_policy, git_policy_outcome: $git_policy_outcome,
          git_policy_reason: $git_policy_reason, git_state_changed: $git_state_changed,
          git_start_sha: null, git_end_sha: null, git_task_base: null, git_task_branch: null,
          git_created_commits: [], git_dirty: null, git_dirty_state: null}' \
        >> "$probe_audit_file"
    else
      probe_mutated="$(jq -r 'if .git_state_changed == null then true else .git_state_changed end' "$probe_post_file")"
      probe_outcome="$(jq -r '.git_policy_outcome // "rejected"' "$probe_post_file")"
      probe_reason="$(jq -r '.git_policy_reason // "unknown"' "$probe_post_file")"

      if [ "$probe_mutated" = "true" ] || [ "$probe_outcome" = "rejected" ]; then
        runner_probe_rc=1
      else
        runner_probe_rc="$default_runner_rc"
      fi

      jq -c \
        --arg ts "$probe_audit_ts" \
        --arg phase "model_probe" \
        --argjson exit_code "$runner_probe_rc" \
        --argjson probe_exit_code "$probe_rc" \
        --arg status "$probe_status" \
        '. + {ts: $ts, phase: $phase, exit_code: $exit_code, probe_exit_code: $probe_exit_code, status: $status}' \
        "$probe_post_file" >> "$probe_audit_file"
    fi
    rm -f "$probe_post_file"
    if [ -n "${git_snapshot_file:-}" ] && [ -f "$git_snapshot_file" ]; then
      rm -f "$git_snapshot_file"
    fi
    git_snapshot_file=""

    if [ "$probe_mutated" = "true" ] || [ "$probe_outcome" = "rejected" ]; then
      echo "error: git state changed during model probe ($probe_reason)" >&2
      cleanup_scratch
      exit 1
    fi
  else
    runner_probe_rc="$default_runner_rc"
  fi

  if [ -n "$interrupted_signal" ]; then
    trap - INT TERM EXIT
    cleanup_scratch
    exit "$runner_probe_rc"
  fi

  if [ "$probe_rc" -eq 124 ]; then
    echo "error: model probe timed out (60s); check AGY_MODEL" >&2
    cleanup_scratch
    exit 124
  fi

  echo "error: could not resolve model '$effective_model' via 'agy -p /model'; check AGY_MODEL (available models: agy -p /model)" >&2
  cleanup_scratch
  exit 2
fi
# "Gemini 3.8 Flash (High)" -> "Gemini 3.8 Flash": the effort suffix is a run
# setting, not part of the model's name.
model_name="$(jq -r '.label // "unknown" | sub(" \\([^)]*\\)$"; "")' <<<"$model_json")"
trailer="Co-authored-by: Antigravity ($model_name) <noreply@google.com>"

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
  if [ "$execution_mode" = "docker-sandbox" ]; then
    cat <<EOF
# Project directory

The project for this step is \`$workdir\`.
Read its AGENTS.md first, if there is one.

EOF
  else
    cat <<EOF
# Project directory

The project for this step is \`$workdir\`. It is not your current
directory, so use absolute paths with your file tools and run shell
commands as \`cd $workdir && <command>\`. Read its AGENTS.md first, if
there is one.

EOF
  fi
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
  if [ "$execution_mode" = "docker-sandbox" ] && [ "$git_policy" = "task-commits" ]; then
    awk -v branch="$HARNESS_TASK_BRANCH" -v base="$HARNESS_TASK_BASE" -v trailer="$trailer" '
      /^- Environment & boundaries:/ {
        print "- Environment & boundaries: Running in Docker Sandbox mode with guarded container access and external network policy."
        print "  This task run is explicitly opted into task checkpoint commits (`HARNESS_GIT_POLICY=task-commits`)"
        print "  on branch `" branch "` from base `" base "`."
        print "  You are authorized to make linear checkpoint commits on `" branch "` only."
        print "  Checkpoint commits are unreviewed, not accepted submissions; full-access checks detect mistakes"
        print "  rather than enforce confinement."
        print "  Every checkpoint commit MUST use Conventional Commits and carry this exact trailer:"
        print "    " trailer
        print "  Do not branch, switch branches, create or modify other refs, merge, or push."
        print "  All work must be committed before completion; successful completed task runs require"
        print "  no tracked or untracked dirty files. On failure or interruption, dirty work is preserved"
        print "  and reported. The designer reviews your work and makes the accepted submission with all"
        print "  contributor trailers."
        skip = 1
        next
      }
      /^- Report discoveries and corrections/ { skip = 0 }
      !skip { print }
    ' "$skill_dir/templates/report.md"
  else
    cat "$skill_dir/templates/report.md"
  fi
} >"$prompt"

args=(-p "$(cat "$prompt")" --output-format stream-json --mode accept-edits
  --disable-slash-commands --print-timeout "$agy_timeout_str")
args+=("${model_args[@]}")
args+=("${mode_flags[@]}")
if [ -n "$resume_attempt" ]; then
  args+=(--conversation "$source_conv_id")
fi

if [ -n "$resume_attempt" ]; then
  echo "==> step $(basename "$step_dir"), attempt $attempt (resuming attempt $resume_attempt): running agy ($model_id) on $workdir"
else
  echo "==> step $(basename "$step_dir"), attempt $attempt: running agy ($model_id) on $workdir"
fi
if [ "$context_status" = "missing" ]; then
  echo "==> notice: no shared exploration context at $context_file; preserving legacy run"
fi
start_sec="$(date +%s.%N)"
start_epoch="$(date +%s)"
deadline_seconds=$((agy_timeout_seconds + timeout_margin_seconds))

terminated_after_result=false
runner_timeout=false
result_seen_epoch=""
rc=0

orig_pwd="$PWD"
cd "$run_cwd"
setsid agy "${args[@]}" </dev/null >"$run" 2>"$stderr" &
agy_pid=$!
cd "$orig_pwd"

while true; do
  if [ -n "$interrupted_signal" ]; then
    runner_interrupted=true
    if [ "$interrupted_signal" = "INT" ]; then
      rc=130
    else
      rc=143
    fi
    break
  fi

  if ! kill -0 "$agy_pid" 2>/dev/null; then
    set +e
    wait "$agy_pid"
    rc=$?
    set -e
    break
  fi

  now_epoch="$(date +%s)"

  if [ -z "$result_seen_epoch" ]; then
    if grep -E '"event"[[:space:]]*:[[:space:]]*"result"' "$run" >/dev/null 2>&1; then
      result_seen_epoch="$now_epoch"
    fi
  fi

  if [ -n "$result_seen_epoch" ]; then
    if [ $((now_epoch - result_seen_epoch)) -ge "$grace_seconds" ]; then
      set +e
      terminate_agy_group "$agy_pid"
      rc=$?
      set -e
      terminated_after_result=true
      break
    fi
  else
    if [ $((now_epoch - start_epoch)) -ge "$deadline_seconds" ]; then
      set +e
      terminate_agy_group "$agy_pid"
      set -e
      runner_timeout=true
      rc=124
      break
    fi
  fi

  sleep 1
done

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
if [ ! -f "$report" ] || ! grep -q '[^[:space:]]' "$report"; then
  report_empty=true
fi

compute_recovery_pending=false
for previous_state in "${compute_recovery_files[@]}"; do
  if ! compute_state_resolved "$previous_state"; then
    compute_recovery_pending=true
  fi
done

status="$(jq -r '.status // "NO_RESULT"' <<<"$result")"
if [ "$runner_interrupted" = true ]; then
  status="INTERRUPTED"
elif [ "$runner_timeout" = true ]; then
  status="TIMEOUT"
  rc=124
elif [ "$conversation_mismatch" = true ]; then
  status="CONVERSATION_MISMATCH"
elif [ "$compute_recovery_pending" = true ] && [ "$status" = "SUCCESS" ]; then
  status="RECOVERY_INCOMPLETE"
fi

if [ "$terminated_after_result" = true ] && [ "$status" = "SUCCESS" ]; then
  rc=0
fi

git_state_changed=false
git_policy_outcome="passed"
git_policy_reason="unmodified"
git_start_sha=""
git_end_sha=""
git_task_base=""
git_task_branch=""
git_created_commits='[]'
git_dirty=false
git_dirty_state='{"dirty":false,"tracked":false,"untracked":false,"staged":false}'

if [ "$execution_mode" = "docker-sandbox" ]; then
  post_check_file="$(mktemp "${TMPDIR:-/tmp}/harness-post-check.XXXXXX")"
  post_check_rc=0
  python3 "$git_policy_helper" post-check \
    --workdir "$workdir" \
    --policy "$git_policy" \
    --snapshot-in "${git_snapshot_file:-/nonexistent}" \
    --status "$status" \
    --exit-code "$rc" \
    --output-json "$post_check_file" 2>/dev/null || post_check_rc=$?

  if [ "$post_check_rc" -ne 0 ] || [ ! -s "$post_check_file" ] || ! jq -e . "$post_check_file" >/dev/null 2>&1; then
    git_state_changed=true
    git_policy_outcome="rejected"
    git_policy_reason="post_check_helper_failed"
    git_start_sha=""
    git_end_sha=""
    git_task_base=""
    git_task_branch=""
    git_created_commits='[]'
    git_dirty="null"
    git_dirty_state="null"
  else
    git_state_changed="$(jq -r 'if .git_state_changed == null then true else .git_state_changed end' "$post_check_file")"
    git_policy_outcome="$(jq -r '.git_policy_outcome // "rejected"' "$post_check_file")"
    git_policy_reason="$(jq -r '.git_policy_reason // "post_check_failed"' "$post_check_file")"
    git_start_sha="$(jq -r '.git_start_sha // empty' "$post_check_file")"
    git_end_sha="$(jq -r '.git_end_sha // empty' "$post_check_file")"
    git_task_base="$(jq -r '.git_task_base // empty' "$post_check_file")"
    git_task_branch="$(jq -r '.git_task_branch // empty' "$post_check_file")"
    git_created_commits="$(jq -c '.git_created_commits // []' "$post_check_file")"
    git_dirty="$(jq -c 'if .git_dirty == null then null else .git_dirty end' "$post_check_file")"
    git_dirty_state="$(jq -c 'if .git_dirty_state == null then null else .git_dirty_state end' "$post_check_file")"
  fi
  rm -f "$post_check_file"
  if [ -n "${git_snapshot_file:-}" ] && [ -f "$git_snapshot_file" ]; then
    rm -f "$git_snapshot_file"
  fi
  git_snapshot_file=""

  if [ "$git_policy" = "strict" ]; then
    if [ "$git_state_changed" = "true" ] || [ "$git_policy_outcome" = "rejected" ]; then
      status="GIT_STATE_MUTATED"
      if [ "$rc" -eq 0 ]; then
        rc=1
      fi
    fi
  elif [ "$git_policy" = "task-commits" ]; then
    if [ "$git_policy_outcome" = "rejected" ]; then
      status="GIT_STATE_MUTATED"
      if [ "$rc" -eq 0 ]; then
        rc=1
      fi
    fi
  fi
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
  --arg execution_mode "$execution_mode" \
  --arg git_policy "$git_policy" \
  --arg git_policy_outcome "$git_policy_outcome" \
  --arg git_policy_reason "$git_policy_reason" \
  --arg git_start_sha "$git_start_sha" \
  --arg git_end_sha "$git_end_sha" \
  --arg git_task_base "$git_task_base" \
  --arg git_task_branch "$git_task_branch" \
  --argjson git_created_commits "$git_created_commits" \
  --argjson git_dirty "$git_dirty" \
  --argjson git_dirty_state "$git_dirty_state" \
  --argjson git_state_changed "$git_state_changed" \
  --arg mode "$mode" \
  --argjson source_attempt "$source_attempt_json" \
  --arg counter_scope "conversation" \
  --argjson wall_duration_seconds "$wall_duration_num" \
  --argjson attempt "$attempt" \
  --arg variant "${HARNESS_VARIANT:-baseline}" \
  --arg harness_rev "$harness_rev" \
  --arg designer "$designer" \
  --arg designer_source "$designer_source" \
  --arg designer_session_id "$designer_session_id" \
  --arg model "$model_id" \
  --arg trailer "$trailer" \
  --arg compute_backend "$compute_backend" \
  --arg status "$status" \
  --argjson compute_recovery_pending "$compute_recovery_pending" \
  --argjson exit_code "$rc" \
  --argjson terminated_after_result "$terminated_after_result" \
  --argjson runner_timeout "$runner_timeout" \
  --argjson denied "$denied" \
  --argjson report_empty "$report_empty" \
  --argjson r "$result" \
  --argjson requested_conversation_id "$requested_conv_id_json" \
  '{ts: $ts, task: $task, step: $step, attempt: $attempt, variant: $variant,
    harness_rev: $harness_rev, designer: $designer,
    designer_source: $designer_source,
    designer_session_id: (if $designer_session_id == "" then null else $designer_session_id end),
    model: $model,
    trailer: $trailer,
    compute_backend: (if $compute_backend == "" then null else $compute_backend end),
    compute_recovery_pending: $compute_recovery_pending,
    exit_code: $exit_code, status: $status,
    execution_mode: $execution_mode,
    git_policy: $git_policy,
    git_policy_outcome: $git_policy_outcome,
    git_policy_reason: $git_policy_reason,
    git_start_sha: (if $git_start_sha == "" then null else $git_start_sha end),
    git_end_sha: (if $git_end_sha == "" then null else $git_end_sha end),
    git_task_base: (if $git_task_base == "" then null else $git_task_base end),
    git_task_branch: (if $git_task_branch == "" then null else $git_task_branch end),
    git_created_commits: $git_created_commits,
    git_dirty: $git_dirty,
    git_dirty_state: $git_dirty_state,
    git_state_changed: $git_state_changed,
    terminated_after_result: $terminated_after_result,
    runner_timeout: $runner_timeout,
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
if [ "$runner_timeout" = true ]; then
  echo "==> error: runner deadline reached (${deadline_seconds}s); agy terminated" >&2
fi
if [ "$terminated_after_result" = true ]; then
  echo "==> warning: agy did not exit after its result; terminated after ${grace_seconds}s grace"
fi
if [ "$conversation_mismatch" = true ]; then
  echo "==> error: conversation ID mismatch (expected $source_conv_id, got ${returned_conv_id:-none})" >&2
fi
if [ "$denied" -gt 0 ]; then
  echo "==> warning: $denied tool call(s) denied; the report's verification may be incomplete"
fi
if [ "$git_policy" = "strict" ]; then
  if [ "$git_state_changed" = true ]; then
    echo "==> error: git state changed during docker-sandbox execution (HEAD, branch, or index modified)" >&2
  fi
elif [ "$git_policy" = "task-commits" ]; then
  if [ "$git_policy_outcome" = "rejected" ]; then
    echo "==> error: git policy violation during task-commits execution ($git_policy_reason)" >&2
  fi
fi
if [ "$report_empty" = true ]; then
  echo "==> warning: no report was returned; see $stderr"
fi
if [ "$compute_recovery_pending" = true ]; then
  echo "==> warning: prior compute attempts remain unresolved; see $prompt"
fi
echo "==> working tree:"
git -C "$workdir" status --short || true
if [ "$rc" -eq 0 ] && [ "$status" = "SUCCESS" ] && [ "$report_empty" = false ]; then
  exit 0
fi
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
exit 1
