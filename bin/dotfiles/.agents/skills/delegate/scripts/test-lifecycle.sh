#!/usr/bin/env bash
#
# test-lifecycle.sh
#
# Focused offline test suite for runner lifecycle management:
# - process group termination on result or timeout
# - graceful termination after final result event
# - runner timeout enforcement and status override
# - signal handling on runner interruption (INT/TERM)
# - PID == PGID verification for setsid process group
# - AGY_TIMEOUT validation and normalization
#
# Does not require network, remote compute, or real Antigravity.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_TASK_BIN="$SCRIPT_DIR/run-task.sh"

PASSED=0
FAILED=0

assert_ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   : $desc"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL : $desc"
    FAILED=$((FAILED + 1))
  fi
}

assert_fail() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "  ok   : $desc (correctly failed)"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL : $desc (unexpectedly succeeded)"
    FAILED=$((FAILED + 1))
  fi
}

TMP_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-lifecycle-test.XXXXXX")"
cleanup() {
  # Clean up any lingering background jobs spawned during tests
  # shellcheck disable=SC2046
  kill $(jobs -p) 2>/dev/null || true
  rm -rf "$TMP_TEST_DIR"
}
trap cleanup EXIT

MOCK_LOG_DIR="$TMP_TEST_DIR/logs"
mkdir -p "$MOCK_LOG_DIR"
PROBE_LOG="$MOCK_LOG_DIR/agy_probe.log"
PROBE_JSONL="$MOCK_LOG_DIR/agy_probe.jsonl"
CALLS_LOG="$MOCK_LOG_DIR/agy_calls.log"
CALLS_JSONL="$MOCK_LOG_DIR/agy_calls.jsonl"

FAKE_BIN_DIR="$TMP_TEST_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"

cat <<'EOF' > "$FAKE_BIN_DIR/agy"
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "/model" ]; then
  echo "$*" >> "${MOCK_LOG_DIR}/agy_probe.log"
  jq -n -c '{argv: $ARGS.positional}' --args -- "$@" >> "${MOCK_LOG_DIR}/agy_probe.jsonl"
  if [ -n "${MOCK_PROBE_EMPTY:-}" ]; then
    echo '{}'
    exit 0
  fi
  if [ -n "${MOCK_PROBE_RESPONSE:-}" ]; then
    echo "$MOCK_PROBE_RESPONSE"
    exit 0
  fi
  echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
  exit 0
fi

echo "$*" >> "${MOCK_LOG_DIR}/agy_calls.log"
jq -n -c '{argv: $ARGS.positional}' --args -- "$@" >> "${MOCK_LOG_DIR}/agy_calls.jsonl"

if [ -n "${MOCK_RUN_SCRIPT:-}" ] && [ -f "$MOCK_RUN_SCRIPT" ]; then
  exec "$MOCK_RUN_SCRIPT" "$@"
fi

cat <<JSON
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":50},"conversation_id":"conv-default-1","response":"# Report: Step 01\n\n## Summary\nDone.\n"}}
JSON
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/agy"

MOCK_WORKDIR="$TMP_TEST_DIR/worktree"
mkdir -p "$MOCK_WORKDIR"
echo "# Mock Agent Instructions" > "$MOCK_WORKDIR/AGENTS.md"
git -C "$MOCK_WORKDIR" init -q

run_harness_task() {
  local step_dir="$1"
  shift
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="${MOCK_RUN_SCRIPT:-}" \
    MOCK_PROBE_EMPTY="${MOCK_PROBE_EMPTY:-}" \
    MOCK_PROBE_RESPONSE="${MOCK_PROBE_RESPONSE:-}" \
    "$RUN_TASK_BIN" "$step_dir" "$MOCK_WORKDIR" "$@"
}

run_with_timeout() {
  local to="$1"
  local step_dir="$2"
  shift 2
  AGY_TIMEOUT="$to" run_harness_task "$step_dir" "$@"
}

run_with_model() {
  local model="$1"
  local step_dir="$2"
  shift 2
  AGY_MODEL="$model" run_harness_task "$step_dir" "$@"
}

has_no_artifacts() {
  local dir="$1"
  ! ls "$dir"/prompt-* "$dir"/run-* "$dir"/report-* >/dev/null 2>&1
}

clear_logs() {
  : > "$PROBE_LOG"
  : > "$PROBE_JSONL"
  : > "$CALLS_LOG"
  : > "$CALLS_JSONL"
}

is_pid_alive() {
  local pid="$1"
  [ -z "$pid" ] && return 1
  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  # If process is in zombie state (Z), it is terminated
  if ps -o stat= -p "$pid" 2>/dev/null | grep -E "^[[:space:]]*[Zz]" >/dev/null; then
    return 1
  fi
  return 0
}

wait_for_pid_dead() {
  local pid="$1"
  local i
  for ((i = 0; i < 30; i++)); do
    if ! is_pid_alive "$pid"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# -----------------------------------------------------------------------------
# Case 1: Normal run (result, then exit 0)
# -----------------------------------------------------------------------------
echo "==> Case 1: Normal run (result, then exit 0)"

TASK_DIR_1="$TMP_TEST_DIR/task-1"
STEP_DIR_1="$TASK_DIR_1/steps/01-step"
mkdir -p "$STEP_DIR_1"
echo "# Brief 1" > "$STEP_DIR_1/brief.md"

clear_logs
assert_ok "normal run succeeds" \
  run_harness_task "$STEP_DIR_1"

assert_ok "normal run creates report-1.md" \
  test -s "$STEP_DIR_1/report-1.md"

assert_ok "normal run records terminated_after_result=false in metrics" \
  jq -e '.terminated_after_result == false' "$TASK_DIR_1/metrics.jsonl"

assert_ok "normal run records runner_timeout=false in metrics" \
  jq -e '.runner_timeout == false' "$TASK_DIR_1/metrics.jsonl"

assert_ok "normal run records exit_code=0 and status=SUCCESS in metrics" \
  jq -e '.exit_code == 0 and .status == "SUCCESS"' "$TASK_DIR_1/metrics.jsonl"

# -----------------------------------------------------------------------------
# Case 2: Result written, then mock sleeps and spawns child sleep
# -----------------------------------------------------------------------------
echo "==> Case 2: Result written, mock and child sleep hung after result"

TASK_DIR_2="$TMP_TEST_DIR/task-2"
STEP_DIR_2="$TASK_DIR_2/steps/01-step"
mkdir -p "$STEP_DIR_2"
echo "# Brief 2" > "$STEP_DIR_2/brief.md"

MOCK_PID_FILE_2="$TMP_TEST_DIR/mock_2.pid"
CHILD_PID_FILE_2="$TMP_TEST_DIR/child_2.pid"
MOCK_SCRIPT_2="$TMP_TEST_DIR/mock_script_2.sh"

cat <<EOF > "$MOCK_SCRIPT_2"
#!/usr/bin/env bash
echo \$\$ > "$MOCK_PID_FILE_2"
cat <<JSON
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":50},"conversation_id":"conv-hung-1","response":"# Report: Step 01\n\n## Summary\nHung after result.\n"}}
JSON
sleep 300 &
echo \$! > "$CHILD_PID_FILE_2"
sleep 300
EOF
chmod +x "$MOCK_SCRIPT_2"

clear_logs
t_start="$(date +%s)"
OUTPUT_2="$TMP_TEST_DIR/output_2.log"
set +e
MOCK_RUN_SCRIPT="$MOCK_SCRIPT_2" AGY_RESULT_GRACE_SECONDS=1 \
  run_harness_task "$STEP_DIR_2" >"$OUTPUT_2" 2>&1
rc_2=$?
set -e
t_end="$(date +%s)"
elapsed_2=$((t_end - t_start))

mock_pid_2="$(cat "$MOCK_PID_FILE_2" 2>/dev/null || echo "")"
child_pid_2="$(cat "$CHILD_PID_FILE_2" 2>/dev/null || echo "")"

assert_ok "runner returns within grace + ~10s ($elapsed_2 seconds)" \
  [ "$elapsed_2" -le 12 ]

assert_ok "runner exits 0 after terminating hung agy with SUCCESS status" \
  [ "$rc_2" -eq 0 ]

assert_ok "report file was saved" \
  test -s "$STEP_DIR_2/report-1.md"

assert_ok "metrics recorded terminated_after_result=true" \
  jq -e '.terminated_after_result == true' "$TASK_DIR_2/metrics.jsonl"

assert_ok "metrics recorded runner_timeout=false" \
  jq -e '.runner_timeout == false' "$TASK_DIR_2/metrics.jsonl"

assert_ok "metrics recorded status SUCCESS and exit_code 0" \
  jq -e '.status == "SUCCESS" and .exit_code == 0' "$TASK_DIR_2/metrics.jsonl"

assert_ok "runner printed warning for termination after grace" \
  grep -Fq "==> warning: agy did not exit after its result; terminated after 1s grace" "$OUTPUT_2"

assert_ok "mock process is no longer active" \
  wait_for_pid_dead "$mock_pid_2"

assert_ok "child process is no longer active" \
  wait_for_pid_dead "$child_pid_2"

# -----------------------------------------------------------------------------
# Case 3: No result, mock sleeps forever
# -----------------------------------------------------------------------------
echo "==> Case 3: No result, mock sleeps forever (runner deadline)"

TASK_DIR_3="$TMP_TEST_DIR/task-3"
STEP_DIR_3="$TASK_DIR_3/steps/01-step"
mkdir -p "$STEP_DIR_3"
echo "# Brief 3" > "$STEP_DIR_3/brief.md"

MOCK_PID_FILE_3="$TMP_TEST_DIR/mock_3.pid"
MOCK_SCRIPT_3="$TMP_TEST_DIR/mock_script_3.sh"

cat <<EOF > "$MOCK_SCRIPT_3"
#!/usr/bin/env bash
echo \$\$ > "$MOCK_PID_FILE_3"
sleep 300
EOF
chmod +x "$MOCK_SCRIPT_3"

clear_logs
t_start="$(date +%s)"
OUTPUT_3="$TMP_TEST_DIR/output_3.log"
set +e
MOCK_RUN_SCRIPT="$MOCK_SCRIPT_3" AGY_TIMEOUT=2s AGY_TIMEOUT_MARGIN_SECONDS=1 \
  run_harness_task "$STEP_DIR_3" >"$OUTPUT_3" 2>&1
rc_3=$?
set -e
t_end="$(date +%s)"
elapsed_3=$((t_end - t_start))

mock_pid_3="$(cat "$MOCK_PID_FILE_3" 2>/dev/null || echo "")"

assert_ok "runner returns near deadline (elapsed: ${elapsed_3}s, expected ~3-6s)" \
  [ "$elapsed_3" -ge 3 ]

assert_ok "runner exits with rc 124 on timeout" \
  [ "$rc_3" -eq 124 ]

assert_ok "metrics recorded status=TIMEOUT" \
  jq -e '.status == "TIMEOUT"' "$TASK_DIR_3/metrics.jsonl"

assert_ok "metrics recorded runner_timeout=true" \
  jq -e '.runner_timeout == true' "$TASK_DIR_3/metrics.jsonl"

assert_ok "metrics recorded terminated_after_result=false" \
  jq -e '.terminated_after_result == false' "$TASK_DIR_3/metrics.jsonl"

assert_ok "metrics recorded exit_code=124" \
  jq -e '.exit_code == 124' "$TASK_DIR_3/metrics.jsonl"

assert_ok "runner printed error for deadline reached" \
  grep -Fq "==> error: runner deadline reached (3s); agy terminated" "$OUTPUT_3"

assert_ok "mock process was terminated by runner deadline" \
  wait_for_pid_dead "$mock_pid_3"

# -----------------------------------------------------------------------------
# Case 4: Runner receives TERM while agy runs
# -----------------------------------------------------------------------------
echo "==> Case 4: Runner receives TERM while agy runs"

TASK_DIR_4="$TMP_TEST_DIR/task-4"
STEP_DIR_4="$TASK_DIR_4/steps/01-step"
mkdir -p "$STEP_DIR_4"
echo "# Brief 4" > "$STEP_DIR_4/brief.md"

MOCK_PID_FILE_4="$TMP_TEST_DIR/mock_4.pid"
CHILD_PID_FILE_4="$TMP_TEST_DIR/child_4.pid"
MOCK_SCRIPT_4="$TMP_TEST_DIR/mock_script_4.sh"

cat <<EOF > "$MOCK_SCRIPT_4"
#!/usr/bin/env bash
echo \$\$ > "$MOCK_PID_FILE_4"
sleep 300 &
echo \$! > "$CHILD_PID_FILE_4"
sleep 300
EOF
chmod +x "$MOCK_SCRIPT_4"

clear_logs
MOCK_RUN_SCRIPT="$MOCK_SCRIPT_4" MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
  "$RUN_TASK_BIN" "$STEP_DIR_4" "$MOCK_WORKDIR" >"$TMP_TEST_DIR/output_4.log" 2>&1 &
RUNNER_PID_4=$!

# Wait for mock to launch and write its PID
mock_pid_4=""
for _ in $(seq 1 50); do
  if [ -s "$MOCK_PID_FILE_4" ] && [ -s "$CHILD_PID_FILE_4" ]; then
    mock_pid_4="$(cat "$MOCK_PID_FILE_4")"
    child_pid_4="$(cat "$CHILD_PID_FILE_4")"
    break
  fi
  sleep 0.05
done

assert_ok "mock process was started by runner" \
  is_pid_alive "$mock_pid_4"

assert_ok "child process was started by mock" \
  is_pid_alive "$child_pid_4"

# Send TERM to runner
kill -TERM "$RUNNER_PID_4" 2>/dev/null || true
set +e
wait "$RUNNER_PID_4" 2>/dev/null
runner_rc_4=$?
set -e

assert_ok "runner exited non-zero upon receiving TERM" \
  [ "$runner_rc_4" -ne 0 ]

assert_ok "mock process is gone shortly after runner receives TERM" \
  wait_for_pid_dead "$mock_pid_4"

assert_ok "child process is gone shortly after runner receives TERM" \
  wait_for_pid_dead "$child_pid_4"

# -----------------------------------------------------------------------------
# Case 5: PID == PGID of the launched agy
# -----------------------------------------------------------------------------
echo "==> Case 5: PID == PGID of the launched agy"

TASK_DIR_5="$TMP_TEST_DIR/task-5"
STEP_DIR_5="$TASK_DIR_5/steps/01-step"
mkdir -p "$STEP_DIR_5"
echo "# Brief 5" > "$STEP_DIR_5/brief.md"

PID_PGID_FILE="$TMP_TEST_DIR/pid_pgid.txt"
MOCK_SCRIPT_5="$TMP_TEST_DIR/mock_script_5.sh"

cat <<EOF > "$MOCK_SCRIPT_5"
#!/usr/bin/env bash
my_pid=\$\$
my_pgid=\$(ps -o pgid= -p \$\$ 2>/dev/null | tr -d ' ')
echo "\$my_pid \$my_pgid" > "$PID_PGID_FILE"
cat <<JSON
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":50},"conversation_id":"conv-pgid-1","response":"# Report: Step 01\n\n## Summary\nPGID verified.\n"}}
JSON
exit 0
EOF
chmod +x "$MOCK_SCRIPT_5"

clear_logs
export MOCK_RUN_SCRIPT="$MOCK_SCRIPT_5"
assert_ok "runner succeeds for PGID check" \
  run_harness_task "$STEP_DIR_5"
unset MOCK_RUN_SCRIPT

read -r recorded_pid recorded_pgid < "$PID_PGID_FILE"
assert_ok "recorded PID ($recorded_pid) equals PGID ($recorded_pgid)" \
  [ -n "$recorded_pid" ] && [ "$recorded_pid" = "$recorded_pgid" ]

# -----------------------------------------------------------------------------
# Case 6: AGY_TIMEOUT validation and normalization
# -----------------------------------------------------------------------------
echo "==> Case 6: AGY_TIMEOUT validation and normalization"

TASK_DIR_6="$TMP_TEST_DIR/task-6"
STEP_DIR_6A="$TASK_DIR_6/steps/01-bare-number"
mkdir -p "$STEP_DIR_6A"
echo "# Brief 6A" > "$STEP_DIR_6A/brief.md"

clear_logs
assert_ok "AGY_TIMEOUT=40 bare integer is accepted" \
  run_with_timeout 40 "$STEP_DIR_6A"

# shellcheck disable=SC2016
assert_ok "AGY_TIMEOUT=40 normalized to 40m in --print-timeout" \
  jq -e '.argv | index("--print-timeout") as $i | .[$i + 1] == "40m"' "$CALLS_JSONL"

STEP_DIR_6B="$TASK_DIR_6/steps/02-hours-minutes"
mkdir -p "$STEP_DIR_6B"
echo "# Brief 6B" > "$STEP_DIR_6B/brief.md"

clear_logs
assert_ok "AGY_TIMEOUT=1h30m is accepted" \
  run_with_timeout 1h30m "$STEP_DIR_6B"

# shellcheck disable=SC2016
assert_ok "AGY_TIMEOUT=1h30m passed as 1h30m in --print-timeout" \
  jq -e '.argv | index("--print-timeout") as $i | .[$i + 1] == "1h30m"' "$CALLS_JSONL"

STEP_DIR_6C="$TASK_DIR_6/steps/03-seconds"
mkdir -p "$STEP_DIR_6C"
echo "# Brief 6C" > "$STEP_DIR_6C/brief.md"

clear_logs
assert_ok "AGY_TIMEOUT=90s is accepted" \
  run_with_timeout 90s "$STEP_DIR_6C"

# shellcheck disable=SC2016
assert_ok "AGY_TIMEOUT=90s passed as 90s in --print-timeout" \
  jq -e '.argv | index("--print-timeout") as $i | .[$i + 1] == "90s"' "$CALLS_JSONL"

# Invalid inputs must exit 2 with specific error message and create no artifacts
test_invalid_timeout() {
  local bad_val="$1"
  local step_name="$2"
  local step_dir="$TASK_DIR_6/steps/$step_name"
  mkdir -p "$step_dir"
  echo "# Brief" > "$step_dir/brief.md"

  local out_file="$TMP_TEST_DIR/bad_${step_name}.log"
  set +e
  AGY_TIMEOUT="$bad_val" run_harness_task "$step_dir" >"$out_file" 2>&1
  local exit_code=$?
  set -e

  if [ "$exit_code" -ne 2 ]; then
    echo "  FAIL : AGY_TIMEOUT='$bad_val' did not exit 2 (got $exit_code)"
    FAILED=$((FAILED + 1))
    return
  fi

  local expected="error: invalid AGY_TIMEOUT '$bad_val' (use e.g. 40m, 1h30m, 90s, or minutes as a bare number)"
  if ! grep -Fq "$expected" "$out_file"; then
    echo "  FAIL : AGY_TIMEOUT='$bad_val' did not print expected error message"
    FAILED=$((FAILED + 1))
    return
  fi

  if ls "$step_dir"/prompt-* "$step_dir"/run-* >/dev/null 2>&1; then
    echo "  FAIL : AGY_TIMEOUT='$bad_val' left prompt or run artifacts behind"
    FAILED=$((FAILED + 1))
    return
  fi

  echo "  ok   : AGY_TIMEOUT='$bad_val' rejected with exit 2, message, and no artifacts"
  PASSED=$((PASSED + 1))
}

test_invalid_timeout "2400x" "04-bad-suffix"
test_invalid_timeout "abc" "05-bad-string"
test_invalid_timeout "0" "06-bad-zero"
test_invalid_timeout "0m" "07-bad-zero-m"

# Non-numeric grace/margin would make the watch loop never terminate agy
test_invalid_knob() {
  local knob="$1"
  local bad_val="$2"
  local step_name="$3"
  local step_dir="$TASK_DIR_6/steps/$step_name"
  mkdir -p "$step_dir"
  echo "# Brief" > "$step_dir/brief.md"

  local out_file="$TMP_TEST_DIR/bad_${step_name}.log"
  set +e
  (export "$knob=$bad_val"; AGY_TIMEOUT=1m run_harness_task "$step_dir") >"$out_file" 2>&1
  local exit_code=$?
  set -e

  if [ "$exit_code" -eq 2 ] && grep -Fq "error: invalid $knob '$bad_val'" "$out_file" \
      && ! ls "$step_dir"/prompt-* "$step_dir"/run-* >/dev/null 2>&1; then
    echo "  ok   : $knob='$bad_val' rejected with exit 2, message, and no artifacts"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL : $knob='$bad_val' not rejected cleanly (exit $exit_code)"
    FAILED=$((FAILED + 1))
  fi
}

test_invalid_knob AGY_RESULT_GRACE_SECONDS abc "08-bad-grace"
test_invalid_knob AGY_TIMEOUT_MARGIN_SECONDS 1.5 "09-bad-margin"

# -----------------------------------------------------------------------------
# Case 7: Model probe failure and fail-fast before attempt allocation
# -----------------------------------------------------------------------------
echo "==> Case 7: Model probe failure and fail-fast before attempt allocation"

TASK_DIR_7="$TMP_TEST_DIR/task-7"
STEP_DIR_7="$TASK_DIR_7/steps/01-step"
mkdir -p "$STEP_DIR_7"
echo "# Brief 7" > "$STEP_DIR_7/brief.md"

clear_logs
OUTPUT_7="$TMP_TEST_DIR/output_7.log"
set +e
MOCK_PROBE_EMPTY=1 run_harness_task "$STEP_DIR_7" >"$OUTPUT_7" 2>&1
rc_7=$?
set -e

assert_ok "empty probe causes runner to exit 2" \
  [ "$rc_7" -eq 2 ]

assert_ok "empty probe prints error naming default model and checking AGY_MODEL" \
  grep -Fq "error: could not resolve model 'gemini-3.8-flash-high' via 'agy -p /model'; check AGY_MODEL (available models: agy -p /model)" "$OUTPUT_7"

assert_ok "no artifacts created when probe fails" \
  has_no_artifacts "$STEP_DIR_7"

assert_ok "no metrics row written when probe fails" \
  [ ! -f "$TASK_DIR_7/metrics.jsonl" ]

# A following normal run on the same step must get attempt 1
clear_logs
OUTPUT_7B="$TMP_TEST_DIR/output_7b.log"
assert_ok "following normal run succeeds" \
  run_harness_task "$STEP_DIR_7" >"$OUTPUT_7B" 2>&1

assert_ok "following run receives attempt 1" \
  test -s "$STEP_DIR_7/prompt-1.md"

assert_ok "following run creates report-1.md" \
  test -s "$STEP_DIR_7/report-1.md"

assert_ok "following run records attempt 1 in metrics" \
  jq -e '.attempt == 1 and .status == "SUCCESS"' "$TASK_DIR_7/metrics.jsonl"

# Probe failure with explicit custom AGY_MODEL names the custom model
clear_logs
OUTPUT_7C="$TMP_TEST_DIR/output_7c.log"
set +e
MOCK_PROBE_EMPTY=1 run_with_model "custom-test-model" "$STEP_DIR_7" >"$OUTPUT_7C" 2>&1
rc_7c=$?
set -e

assert_ok "probe failure with custom AGY_MODEL exits 2" \
  [ "$rc_7c" -eq 2 ]

assert_ok "error message names the custom requested model" \
  grep -Fq "error: could not resolve model 'custom-test-model' via 'agy -p /model'; check AGY_MODEL (available models: agy -p /model)" "$OUTPUT_7C"

# -----------------------------------------------------------------------------
# Case 8: Default model passed to probe and run argv
# -----------------------------------------------------------------------------
echo "==> Case 8: Default model passed to probe and run argv"

TASK_DIR_8="$TMP_TEST_DIR/task-8"
STEP_DIR_8="$TASK_DIR_8/steps/01-step"
mkdir -p "$STEP_DIR_8"
echo "# Brief 8" > "$STEP_DIR_8/brief.md"

clear_logs
unset AGY_MODEL || true
assert_ok "run with unset AGY_MODEL succeeds" \
  run_harness_task "$STEP_DIR_8"

# shellcheck disable=SC2016
assert_ok "probe argv contains --model gemini-3.8-flash-high when AGY_MODEL is unset" \
  jq -e '.argv | index("--model") as $i | .[$i + 1] == "gemini-3.8-flash-high"' "$PROBE_JSONL"

# shellcheck disable=SC2016
assert_ok "run argv contains --model gemini-3.8-flash-high when AGY_MODEL is unset" \
  jq -e '.argv | index("--model") as $i | .[$i + 1] == "gemini-3.8-flash-high"' "$CALLS_JSONL"

# Custom AGY_MODEL is passed to both probe and run argv
TASK_DIR_8B="$TMP_TEST_DIR/task-8b"
STEP_DIR_8B="$TASK_DIR_8B/steps/01-step"
mkdir -p "$STEP_DIR_8B"
echo "# Brief 8B" > "$STEP_DIR_8B/brief.md"

clear_logs
assert_ok "run with custom AGY_MODEL succeeds" \
  run_with_model "gemini-custom-pro" "$STEP_DIR_8B"

# shellcheck disable=SC2016
assert_ok "probe argv contains custom model when AGY_MODEL is set" \
  jq -e '.argv | index("--model") as $i | .[$i + 1] == "gemini-custom-pro"' "$PROBE_JSONL"

# shellcheck disable=SC2016
assert_ok "run argv contains custom model when AGY_MODEL is set" \
  jq -e '.argv | index("--model") as $i | .[$i + 1] == "gemini-custom-pro"' "$CALLS_JSONL"

# -----------------------------------------------------------------------------
echo "=========================================="
echo "Lifecycle tests passed: $PASSED, failed: $FAILED"
echo "=========================================="
[ "$FAILED" -eq 0 ]
