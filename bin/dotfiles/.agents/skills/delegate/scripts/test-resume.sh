#!/usr/bin/env bash
#
# test-resume.sh
#
# Focused offline test suite for same-step conversation continuation,
# argv/prompt validation, locking, workdir isolation, error handling,
# history identity, artifact allocation, and metrics recording.
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

TMP_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-resume-test.XXXXXX")"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

MOCK_LOG_DIR="$TMP_TEST_DIR/logs"
mkdir -p "$MOCK_LOG_DIR"
PROBE_LOG="$MOCK_LOG_DIR/agy_probe.log"
CALLS_LOG="$MOCK_LOG_DIR/agy_calls.log"
CALLS_JSONL="$MOCK_LOG_DIR/agy_calls.jsonl"

FAKE_BIN_DIR="$TMP_TEST_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"

cat <<'EOF' > "$FAKE_BIN_DIR/agy"
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "/model" ]; then
  echo "$*" >> "${MOCK_LOG_DIR}/agy_probe.log"
  echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
  exit 0
fi

echo "$*" >> "${MOCK_LOG_DIR}/agy_calls.log"
jq -n -c '{argv: $ARGS.positional}' --args -- "$@" >> "${MOCK_LOG_DIR}/agy_calls.jsonl"

if [ -n "${MOCK_RUN_SCRIPT:-}" ] && [ -f "$MOCK_RUN_SCRIPT" ]; then
  exec "$MOCK_RUN_SCRIPT" "$@"
fi

# Detect if --conversation is present
passed_conv_id=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--conversation" ]; then
    next_i=$((i+1))
    passed_conv_id="${!next_i}"
    break
  fi
done

if [ "${MOCK_CONV_ID+defined}" = "defined" ]; then
  conv_id="$MOCK_CONV_ID"
else
  conv_id="${passed_conv_id:-conv-default-1}"
fi
status="${MOCK_STATUS:-SUCCESS}"
exit_code="${MOCK_EXIT_CODE:-0}"
duration="${MOCK_DURATION:-0.5}"
turns="${MOCK_TURNS:-1}"
if [ -n "${MOCK_USAGE:-}" ]; then
  usage="$MOCK_USAGE"
else
  usage='{"input_tokens":100,"output_tokens":50}'
fi

if [ -n "$conv_id" ]; then
  conv_id_json="\"$conv_id\""
else
  conv_id_json="null"
fi

cat <<JSON
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"$status","duration_seconds":$duration,"num_turns":$turns,"usage":$usage,"conversation_id":$conv_id_json,"response":"# Report: Step 01\n\n## Summary\nMock run done.\n\n## Decisions\nNone\n\n## Deviations from the brief\nNone\n\n## Assumptions\nNone\n\n## Context discoveries / corrections\nNone\n\n## Not done / open questions\nNone\n\n## Verification\n- mock: passed\n\n## Not verified\nNone\n\n## Remote compute (when compute.json was used)\nNone\n"}}
JSON
exit "$exit_code"
EOF
chmod +x "$FAKE_BIN_DIR/agy"

MOCK_WORKDIR_1="$TMP_TEST_DIR/worktree1"
mkdir -p "$MOCK_WORKDIR_1"
echo "# Mock Agent Instructions" > "$MOCK_WORKDIR_1/AGENTS.md"
git -C "$MOCK_WORKDIR_1" init -q

MOCK_WORKDIR_2="$TMP_TEST_DIR/worktree2"
mkdir -p "$MOCK_WORKDIR_2"
echo "# Mock Agent Instructions" > "$MOCK_WORKDIR_2/AGENTS.md"
git -C "$MOCK_WORKDIR_2" init -q

run_harness_task() {
  local step_dir="$1"
  shift
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" "$RUN_TASK_BIN" "$step_dir" "$MOCK_WORKDIR_1" "$@"
}

clear_logs() {
  : > "$PROBE_LOG"
  : > "$CALLS_LOG"
  : > "$CALLS_JSONL"
}

# -----------------------------------------------------------------------------
# 1. CLI Usage & Invalid Requests (agy must not be invoked)
# -----------------------------------------------------------------------------
echo "==> Scenario 1: CLI usage and invalid option validation"

TASK_DIR_1="$TMP_TEST_DIR/task-1"
STEP_DIR_1="$TASK_DIR_1/steps/01-step"
mkdir -p "$STEP_DIR_1"
cat <<'EOF' > "$STEP_DIR_1/brief.md"
# Step 01: Test Brief
## Task
Do task.
EOF

clear_logs
assert_fail "fewer than 2 arguments fails" \
  "$RUN_TASK_BIN" "$STEP_DIR_1"

assert_fail "--continue option is rejected" \
  run_harness_task "$STEP_DIR_1" --continue

assert_fail "--resume-attempt without number fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt

assert_fail "--resume-attempt with empty string fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt ""

assert_fail "--resume-attempt=1 fails as unknown option (spaced form required)" \
  run_harness_task "$STEP_DIR_1" --resume-attempt=1

assert_fail "--resume-attempt= fails as unknown option" \
  run_harness_task "$STEP_DIR_1" --resume-attempt=

assert_fail "invalid N (0) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 0

assert_fail "invalid N (-1) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt -1

assert_fail "invalid N (01 with leading zero) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 01

assert_fail "invalid N (abc) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt abc

assert_fail "invalid N (1.5) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 1.5

assert_fail "huge attempt number (> 1000000) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 1000001

assert_fail "huge attempt number (overflowing digits) fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 99999999999999999999

assert_fail "unknown option fails" \
  run_harness_task "$STEP_DIR_1" --unknown-flag

assert_fail "duplicate --resume-attempt fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 1 --resume-attempt 2

assert_fail "duplicate --resume-attempt with empty first option fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt "" --resume-attempt 1

assert_fail "resume attempt with no history fails" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 1

assert_ok "agy was never invoked (no model probe calls)" \
  test ! -s "$PROBE_LOG"

assert_ok "agy was never invoked (no execution calls)" \
  test ! -s "$CALLS_LOG"

# -----------------------------------------------------------------------------
# 2. Fresh Run vs Resume Run: actual argv and prompt content
# -----------------------------------------------------------------------------
echo "==> Scenario 2: Fresh run vs resume run (actual argv and prompt content)"

clear_logs
assert_ok "fresh attempt 1 succeeds" \
  run_harness_task "$STEP_DIR_1"

assert_ok "attempt 1 prompt prompt-1.md was created" \
  test -f "$STEP_DIR_1/prompt-1.md"

assert_fail "attempt 1 prompt does NOT have resumed conversation header" \
  grep -Fq "# Resumed conversation" "$STEP_DIR_1/prompt-1.md"

assert_fail "attempt 1 prompt does NOT have precedence notice" \
  grep -Fq "precedence over old conversation scope" "$STEP_DIR_1/prompt-1.md"

assert_ok "attempt 1 fake agy was invoked without --conversation (structural argv)" \
  jq -e -s '.[0].argv | any(. == "--conversation") | not' "$CALLS_JSONL"

assert_ok "attempt 1 fake agy argv does NOT contain --continue (structural argv)" \
  jq -e -s '.[0].argv | any(. == "--continue") | not' "$CALLS_JSONL"

assert_ok "attempt 1 metrics has mode=fresh and source_attempt=null" \
  jq -e -s 'map(select(.attempt == 1 and .mode == "fresh" and .source_attempt == null and .requested_conversation_id == null)) | length == 1' "$TASK_DIR_1/metrics.jsonl"

# shellcheck disable=SC2016
assert_ok "attempt 1 metrics records workdir" \
  jq -e -s --arg w "$MOCK_WORKDIR_1" 'map(select(.attempt == 1 and .workdir == $w)) | length == 1' "$TASK_DIR_1/metrics.jsonl"

assert_ok "attempt 1 metrics records conversation counter scope and wall duration" \
  jq -e -s 'map(select(.attempt == 1 and .counter_scope == "conversation" and .wall_duration_seconds > 0)) | length == 1' "$TASK_DIR_1/metrics.jsonl"

assert_ok "attempt 1 metrics contains no speculative aliases" \
  jq -e -s '.[0] | (has("canonical_workdir") or has("resume") or has("is_resume") or has("wall_elapsed_seconds") or has("raw_counter_scope") or has("usage_scope")) | not' "$TASK_DIR_1/metrics.jsonl"

conv_id_1="$(jq -r 'select(.attempt == 1) | .conversation_id' "$TASK_DIR_1/metrics.jsonl")"

# Now run resume attempt 2
clear_logs
assert_ok "resume attempt 2 succeeds" \
  run_harness_task "$STEP_DIR_1" --resume-attempt 1

assert_ok "attempt 2 prompt prompt-2.md was created" \
  test -f "$STEP_DIR_1/prompt-2.md"

assert_ok "attempt 2 prompt contains resumed conversation header" \
  grep -Fq "# Resumed conversation" "$STEP_DIR_1/prompt-2.md"

assert_ok "attempt 2 prompt embeds source conversation id" \
  grep -Fq "$conv_id_1" "$STEP_DIR_1/prompt-2.md"

assert_ok "attempt 2 prompt contains exact precedence statement" \
  grep -Fq "The current brief and run rules take precedence over old conversation scope, without overriding safety." "$STEP_DIR_1/prompt-2.md"

assert_ok "attempt 2 prompt still includes brief" \
  grep -Fq "Do task." "$STEP_DIR_1/prompt-2.md"

  # shellcheck disable=SC2016
assert_ok "attempt 2 fake agy argv contains exact --conversation ID (structural argv)" \
  jq -e -s --arg id "$conv_id_1" '.[0].argv | any(. == "--conversation") and (index("--conversation") as $i | .[$i+1] == $id)' "$CALLS_JSONL"

assert_ok "attempt 2 fake agy argv does NOT contain --continue (structural argv)" \
  jq -e -s '.[0].argv | any(. == "--continue") | not' "$CALLS_JSONL"

# shellcheck disable=SC2016
assert_ok "attempt 2 metrics records mode=resume and source_attempt=1" \
  jq -e -s --arg id "$conv_id_1" 'map(select(.attempt == 2 and .mode == "resume" and .source_attempt == 1 and .requested_conversation_id == $id and .conversation_id == $id)) | length == 1' "$TASK_DIR_1/metrics.jsonl"

assert_ok "attempt 2 metrics records wall duration" \
  jq -e -s 'map(select(.attempt == 2 and .wall_duration_seconds > 0)) | length == 1' "$TASK_DIR_1/metrics.jsonl"

# -----------------------------------------------------------------------------
# 3. Same-Step Isolation & Workdir Mismatch
# -----------------------------------------------------------------------------
echo "==> Scenario 3: Same-step isolation and workdir mismatch"

TASK_DIR_2="$TMP_TEST_DIR/task-2"
STEP_DIR_2A="$TASK_DIR_2/steps/01-first"
STEP_DIR_2B="$TASK_DIR_2/steps/02-second"
mkdir -p "$STEP_DIR_2A" "$STEP_DIR_2B"
echo "# Step 2A" > "$STEP_DIR_2A/brief.md"
echo "# Step 2B" > "$STEP_DIR_2B/brief.md"

assert_ok "step 2A attempt 1 completes" \
  run_harness_task "$STEP_DIR_2A"

# Try resuming attempt 1 in step 2B (step 2B has no attempt 1)
clear_logs
assert_fail "cannot resume attempt across different steps (same-step isolation)" \
  run_harness_task "$STEP_DIR_2B" --resume-attempt 1

assert_ok "agy was not called on cross-step resume attempt" \
  test ! -s "$CALLS_LOG"

# Workdir mismatch test: attempt 1 was run on MOCK_WORKDIR_1, try resume with MOCK_WORKDIR_2
clear_logs
assert_fail "workdir mismatch is rejected" \
  env MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" "$RUN_TASK_BIN" "$STEP_DIR_2A" "$MOCK_WORKDIR_2" --resume-attempt 1

assert_ok "agy was not called on workdir mismatch" \
  test ! -s "$CALLS_LOG"

# -----------------------------------------------------------------------------
# 4. Legacy records without reliable workdir cannot be resumed
# -----------------------------------------------------------------------------
echo "==> Scenario 4: Legacy records without reliable workdir"

TASK_DIR_LEGACY="$TMP_TEST_DIR/task-legacy"
STEP_DIR_LEGACY="$TASK_DIR_LEGACY/steps/01-legacy"
mkdir -p "$STEP_DIR_LEGACY"
echo "# Legacy brief" > "$STEP_DIR_LEGACY/brief.md"
# Create legacy run-1.jsonl and metrics.jsonl missing workdir
cat <<'JSON' > "$STEP_DIR_LEGACY/run-1.jsonl"
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"conversation_id":"conv-legacy-1","response":"# Report\nDone\n"}}
JSON
echo '{"ts":"2026-10-09T00:00:00Z","task":"task-legacy","step":"01-legacy","attempt":1,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":null,"conversation_id":"conv-legacy-1"}' \
  > "$TASK_DIR_LEGACY/metrics.jsonl"

clear_logs
assert_fail "resuming legacy record without workdir is rejected" \
  run_harness_task "$STEP_DIR_LEGACY" --resume-attempt 1

assert_ok "agy was not called when resuming legacy record" \
  test ! -s "$CALLS_LOG"

# Fresh execution on legacy step remains compatible
assert_ok "fresh execution on step with legacy history succeeds and allocates attempt 2" \
  run_harness_task "$STEP_DIR_LEGACY"

assert_ok "attempt 2 was created on legacy step" \
  test -f "$STEP_DIR_LEGACY/prompt-2.md"

# -----------------------------------------------------------------------------
# 5. Missing conversation ID / unfinished source attempt
# -----------------------------------------------------------------------------
echo "==> Scenario 5: Missing conversation ID and unfinished source"

TASK_DIR_UNFINISHED="$TMP_TEST_DIR/task-unfinished"
STEP_DIR_UNFINISHED="$TASK_DIR_UNFINISHED/steps/01-step"
mkdir -p "$STEP_DIR_UNFINISHED"
echo "# Brief" > "$STEP_DIR_UNFINISHED/brief.md"

# Create interrupted/partial run: prompt and partial run log without result event, no metrics
touch "$STEP_DIR_UNFINISHED/prompt-1.md"
echo '{"event":"step_update","step_update":{"step_index":1,"state":"RUNNING"}}' > "$STEP_DIR_UNFINISHED/run-1.jsonl"

clear_logs
assert_fail "cannot resume unfinished attempt" \
  run_harness_task "$STEP_DIR_UNFINISHED" --resume-attempt 1

assert_ok "agy was not called for unfinished source" \
  test ! -s "$CALLS_LOG"

# Missing conversation ID in completed record
TASK_DIR_NO_ID="$TMP_TEST_DIR/task-no-id"
STEP_DIR_NO_ID="$TASK_DIR_NO_ID/steps/01-step"
mkdir -p "$STEP_DIR_NO_ID"
echo "# Brief" > "$STEP_DIR_NO_ID/brief.md"
cat <<'JSON' > "$STEP_DIR_NO_ID/run-1.jsonl"
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"conversation_id":null,"response":"# Report\nDone\n"}}
JSON
jq -n -c \
  --arg step "01-step" \
  --arg step_dir "$(cd "$STEP_DIR_NO_ID" && pwd -P)" \
  --arg workdir "$MOCK_WORKDIR_1" \
  '{step: $step, step_dir: $step_dir, attempt: 1, workdir: $workdir, status: "SUCCESS", exit_code: 0, conversation_id: null}' \
  > "$TASK_DIR_NO_ID/metrics.jsonl"

clear_logs
assert_fail "cannot resume attempt with missing conversation ID" \
  run_harness_task "$STEP_DIR_NO_ID" --resume-attempt 1

assert_ok "agy was not called for source with null conversation ID" \
  test ! -s "$CALLS_LOG"

# -----------------------------------------------------------------------------
# 6. Prior failed attempt with terminal results CAN be resumed
# -----------------------------------------------------------------------------
echo "==> Scenario 6: Prior failed attempt with terminal results can be resumed"

TASK_DIR_FAILED="$TMP_TEST_DIR/task-failed"
STEP_DIR_FAILED="$TASK_DIR_FAILED/steps/01-step"
mkdir -p "$STEP_DIR_FAILED"
echo "# Brief" > "$STEP_DIR_FAILED/brief.md"

# Mock attempt 1 that exited non-zero with ERROR status but has terminal result event
export MOCK_STATUS="ERROR"
export MOCK_EXIT_CODE=1
export MOCK_CONV_ID="conv-failed-source-1"

assert_fail "attempt 1 exits non-zero on failure" \
  run_harness_task "$STEP_DIR_FAILED"

assert_ok "attempt 1 recorded exit_code=1 and status=ERROR" \
  jq -e -s 'map(select(.attempt == 1 and .exit_code == 1 and .status == "ERROR" and .conversation_id == "conv-failed-source-1")) | length == 1' "$TASK_DIR_FAILED/metrics.jsonl"

# Now resume attempt 1 with a successful agy run
unset MOCK_STATUS
unset MOCK_EXIT_CODE
unset MOCK_CONV_ID

clear_logs
assert_ok "resume of prior failed attempt succeeds" \
  run_harness_task "$STEP_DIR_FAILED" --resume-attempt 1

  # shellcheck disable=SC2016
assert_ok "resumed run passed expected conversation ID from failed attempt" \
  jq -e -s '.[0].argv | any(. == "--conversation") and (index("--conversation") as $i | .[$i+1] == "conv-failed-source-1")' "$CALLS_JSONL"

assert_ok "attempt 2 metrics records source_attempt=1 and SUCCESS" \
  jq -e -s 'map(select(.attempt == 2 and .source_attempt == 1 and .status == "SUCCESS" and .conversation_id == "conv-failed-source-1")) | length == 1' "$TASK_DIR_FAILED/metrics.jsonl"

# -----------------------------------------------------------------------------
# 7. Returned conversation ID mismatch or absent is failure
# -----------------------------------------------------------------------------
echo "==> Scenario 7: Returned conversation ID mismatch or absent is failure"

TASK_DIR_MISMATCH="$TMP_TEST_DIR/task-mismatch"
STEP_DIR_MISMATCH="$TASK_DIR_MISMATCH/steps/01-step"
mkdir -p "$STEP_DIR_MISMATCH"
echo "# Brief" > "$STEP_DIR_MISMATCH/brief.md"

export MOCK_CONV_ID="conv-step7-initial"
assert_ok "attempt 1 completes" \
  run_harness_task "$STEP_DIR_MISMATCH"
unset MOCK_CONV_ID

# On resume, agy returns mismatched conversation ID
export MOCK_CONV_ID="conv-unexpected-999"
assert_fail "resumed run fails when agy returns unexpected conversation ID" \
  run_harness_task "$STEP_DIR_MISMATCH" --resume-attempt 1

assert_ok "mismatch recorded in metrics as CONVERSATION_MISMATCH" \
  jq -e -s 'map(select(.attempt == 2 and .status == "CONVERSATION_MISMATCH" and .exit_code == 1 and .requested_conversation_id == "conv-step7-initial" and .conversation_id == "conv-unexpected-999")) | length == 1' "$TASK_DIR_MISMATCH/metrics.jsonl"
unset MOCK_CONV_ID

# On resume, agy returns absent/null conversation ID
TASK_DIR_ABSENT="$TMP_TEST_DIR/task-absent"
STEP_DIR_ABSENT="$TASK_DIR_ABSENT/steps/01-step"
mkdir -p "$STEP_DIR_ABSENT"
echo "# Brief" > "$STEP_DIR_ABSENT/brief.md"

export MOCK_CONV_ID="conv-step7-absent-source"
assert_ok "attempt 1 completes" \
  run_harness_task "$STEP_DIR_ABSENT"
unset MOCK_CONV_ID

export MOCK_CONV_ID=""
assert_fail "resumed run fails when agy returns absent conversation ID" \
  run_harness_task "$STEP_DIR_ABSENT" --resume-attempt 1

assert_ok "absent returned ID recorded in metrics as CONVERSATION_MISMATCH" \
  jq -e -s 'map(select(.attempt == 2 and .status == "CONVERSATION_MISMATCH" and .exit_code == 1)) | length == 1' "$TASK_DIR_ABSENT/metrics.jsonl"
unset MOCK_CONV_ID

# -----------------------------------------------------------------------------
# 8. Fresh reset (next attempt after resume can start fresh)
# -----------------------------------------------------------------------------
echo "==> Scenario 8: Fresh reset after resume"

TASK_DIR_RESET="$TMP_TEST_DIR/task-reset"
STEP_DIR_RESET="$TASK_DIR_RESET/steps/01-step"
mkdir -p "$STEP_DIR_RESET"
echo "# Brief" > "$STEP_DIR_RESET/brief.md"

assert_ok "attempt 1 (fresh) succeeds" \
  run_harness_task "$STEP_DIR_RESET"

assert_ok "attempt 2 (resume) succeeds" \
  run_harness_task "$STEP_DIR_RESET" --resume-attempt 1

clear_logs
assert_ok "attempt 3 (fresh reset without --resume-attempt) succeeds" \
  run_harness_task "$STEP_DIR_RESET"

# Genuinely assert absence of header (not false positive grep -Fv)
assert_fail "attempt 3 prompt does NOT have resumed conversation header" \
  grep -Fq "# Resumed conversation" "$STEP_DIR_RESET/prompt-3.md"

assert_ok "attempt 3 agy argv does NOT contain --conversation" \
  jq -e -s '.[0].argv | any(. == "--conversation") | not' "$CALLS_JSONL"

assert_ok "attempt 3 metrics records mode=fresh and source_attempt=null" \
  jq -e -s 'map(select(.attempt == 3 and .mode == "fresh" and .source_attempt == null)) | length == 1' "$TASK_DIR_RESET/metrics.jsonl"

# -----------------------------------------------------------------------------
# 9. Locking and concurrent conflict & FD inheritance
# -----------------------------------------------------------------------------
echo "==> Scenario 9: Locking and concurrent conflict"

TASK_DIR_LOCK="$TMP_TEST_DIR/task-lock"
STEP_DIR_LOCK="$TASK_DIR_LOCK/steps/01-step"
mkdir -p "$STEP_DIR_LOCK"
echo "# Brief" > "$STEP_DIR_LOCK/brief.md"

# 9a: External process holds flock on step lock file
touch "$STEP_DIR_LOCK/.lock"
(
  exec 9>>"$STEP_DIR_LOCK/.lock"
  flock -n 9
  sleep 2
) &
LOCK_PID=$!
sleep 0.1

clear_logs
assert_fail "concurrent execution is rejected immediately by nonblocking flock" \
  run_harness_task "$STEP_DIR_LOCK"

wait "$LOCK_PID"

assert_ok "agy was not called during lock conflict" \
  test ! -s "$CALLS_LOG"

assert_ok "lock file inode is preserved on exit" \
  test -f "$STEP_DIR_LOCK/.lock"

# 9b: Child agy holds lock if runner process is interrupted
LOCK_CHILD_DIR="$TMP_TEST_DIR/task-lock-child"
STEP_CHILD_DIR="$LOCK_CHILD_DIR/steps/01-step"
mkdir -p "$STEP_CHILD_DIR"
echo "# Brief" > "$STEP_CHILD_DIR/brief.md"

SLEEP_SCRIPT="$TMP_TEST_DIR/sleep_agy.sh"
READY_FILE="$TMP_TEST_DIR/agy_running"
RELEASE_FILE="$TMP_TEST_DIR/agy_release"
rm -f "$READY_FILE" "$RELEASE_FILE"

cat <<EOF > "$SLEEP_SCRIPT"
#!/usr/bin/env bash
touch "$READY_FILE"
timeout=100
while [ ! -f "$RELEASE_FILE" ] && [ \$timeout -gt 0 ]; do
  sleep 0.05
  timeout=\$((timeout - 1))
done
cat <<JSON
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":2,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-lock-1","response":"# Report\nDone\n"}}
JSON
exit 0
EOF
chmod +x "$SLEEP_SCRIPT"

MOCK_RUN_SCRIPT="$SLEEP_SCRIPT" MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
  "$RUN_TASK_BIN" "$STEP_CHILD_DIR" "$MOCK_WORKDIR_1" &
RUNNER_PID=$!

# Wait for handshake that child agy is actively running
waited=0
while [ ! -f "$READY_FILE" ] && [ "$waited" -lt 50 ]; do
  sleep 0.05
  waited=$((waited + 1))
done

assert_ok "child agy signaled it is running (handshake)" \
  test -f "$READY_FILE"

# Interrupt runner parent process while fake agy is kept alive
kill -TERM "$RUNNER_PID" 2>/dev/null || true
wait "$RUNNER_PID" 2>/dev/null || true

# Runner is dead, but child agy is still running holding FD 9
assert_fail "cannot acquire lock while child agy remains alive after runner interrupt" \
  flock -n "$STEP_CHILD_DIR/.lock" true

# Release child agy
touch "$RELEASE_FILE"

# Wait for child agy to exit and release lock
released=false
for _ in $(seq 1 50); do
  if flock -n "$STEP_CHILD_DIR/.lock" true 2>/dev/null; then
    released=true
    break
  fi
  sleep 0.05
done

assert_ok "lock is released after child agy terminates" \
  test "$released" = true

assert_ok "lock inode exists after child execution completes" \
  test -f "$STEP_CHILD_DIR/.lock"

# -----------------------------------------------------------------------------
# 10. Partial artifacts preserved (no duplicate IDs or overwriting)
# -----------------------------------------------------------------------------
echo "==> Scenario 10: Partial artifacts preserved"

TASK_DIR_PARTIAL="$TMP_TEST_DIR/task-partial"
STEP_DIR_PARTIAL="$TASK_DIR_PARTIAL/steps/01-step"
mkdir -p "$STEP_DIR_PARTIAL"
echo "# Brief" > "$STEP_DIR_PARTIAL/brief.md"

# Simulate an interrupted run that left prompt-1.md and stderr-1.log
echo "INTERRUPTED PROMPT" > "$STEP_DIR_PARTIAL/prompt-1.md"
echo "INTERRUPTED STDERR" > "$STEP_DIR_PARTIAL/stderr-1.log"

assert_ok "new run allocates attempt 2 without overwriting attempt 1 artifacts" \
  run_harness_task "$STEP_DIR_PARTIAL"

assert_ok "prompt-1.md was preserved intact" \
  grep -Fq "INTERRUPTED PROMPT" "$STEP_DIR_PARTIAL/prompt-1.md"

assert_ok "stderr-1.log was preserved intact" \
  grep -Fq "INTERRUPTED STDERR" "$STEP_DIR_PARTIAL/stderr-1.log"

assert_ok "new run created prompt-2.md" \
  test -f "$STEP_DIR_PARTIAL/prompt-2.md"

assert_ok "metrics recorded attempt 2" \
  jq -e -s 'map(select(.attempt == 2)) | length == 1' "$TASK_DIR_PARTIAL/metrics.jsonl"

# -----------------------------------------------------------------------------
# 11. Custom brief and spaced syntax validation
# -----------------------------------------------------------------------------
echo "==> Scenario 11: Custom brief with spaced --resume-attempt"

TASK_DIR_SYNTAX="$TMP_TEST_DIR/task-syntax"
STEP_DIR_SYNTAX="$TASK_DIR_SYNTAX/steps/01-step"
mkdir -p "$STEP_DIR_SYNTAX"
echo "# Initial brief" > "$STEP_DIR_SYNTAX/brief.md"
echo "# Custom rework brief" > "$STEP_DIR_SYNTAX/rework.md"

assert_ok "attempt 1 succeeds" \
  run_harness_task "$STEP_DIR_SYNTAX"

# Documented spaced form with custom rework brief
assert_ok "spaced form --resume-attempt 1 with custom brief succeeds" \
  run_harness_task "$STEP_DIR_SYNTAX" "$STEP_DIR_SYNTAX/rework.md" --resume-attempt 1

assert_ok "prompt-2 includes custom rework brief" \
  grep -Fq "Custom rework brief" "$STEP_DIR_SYNTAX/prompt-2.md"

assert_ok "attempt 2 metrics records source_attempt=1" \
  jq -e -s 'map(select(.attempt == 2 and .source_attempt == 1)) | length == 1' "$TASK_DIR_SYNTAX/metrics.jsonl"

# -----------------------------------------------------------------------------
# 12. Cumulative counters, usage preservation, and metrics scopes
# -----------------------------------------------------------------------------
echo "==> Scenario 12: Cumulative counters and usage preservation"

TASK_DIR_COUNTERS="$TMP_TEST_DIR/task-counters"
STEP_DIR_COUNTERS="$TASK_DIR_COUNTERS/steps/01-step"
mkdir -p "$STEP_DIR_COUNTERS"
echo "# Brief" > "$STEP_DIR_COUNTERS/brief.md"

export MOCK_DURATION=1.5
export MOCK_TURNS=3
export MOCK_USAGE='{"input_tokens":100,"output_tokens":50}'
assert_ok "attempt 1 succeeds with raw provider counters" \
  run_harness_task "$STEP_DIR_COUNTERS"

# Attempt 2 simulates cumulative counters from provider
export MOCK_DURATION=4.2
export MOCK_TURNS=7
export MOCK_USAGE='{"input_tokens":250,"output_tokens":120}'
assert_ok "attempt 2 succeeds with cumulative provider counters" \
  run_harness_task "$STEP_DIR_COUNTERS" --resume-attempt 1
unset MOCK_DURATION
unset MOCK_TURNS
unset MOCK_USAGE

assert_ok "attempt 2 preserves raw cumulative duration (4.2)" \
  jq -e -s 'map(select(.attempt == 2 and .duration_seconds == 4.2)) | length == 1' "$TASK_DIR_COUNTERS/metrics.jsonl"

assert_ok "attempt 2 preserves raw cumulative turns (7)" \
  jq -e -s 'map(select(.attempt == 2 and .num_turns == 7)) | length == 1' "$TASK_DIR_COUNTERS/metrics.jsonl"

assert_ok "attempt 2 preserves raw cumulative usage input_tokens (250) and output_tokens (120)" \
  jq -e -s 'map(select(.attempt == 2 and .usage.input_tokens == 250 and .usage.output_tokens == 120)) | length == 1' "$TASK_DIR_COUNTERS/metrics.jsonl"

assert_ok "attempt 2 explicitly scopes counters to conversation" \
  jq -e -s 'map(select(.attempt == 2 and .counter_scope == "conversation")) | length == 1' "$TASK_DIR_COUNTERS/metrics.jsonl"

assert_ok "attempt 2 records per-attempt wall clock duration > 0" \
  jq -e -s 'map(select(.attempt == 2 and .wall_duration_seconds > 0)) | length == 1' "$TASK_DIR_COUNTERS/metrics.jsonl"

# -----------------------------------------------------------------------------
# 13. Symlinks and canonicalization via pwd -P
# -----------------------------------------------------------------------------
echo "==> Scenario 13: Symlinks and canonicalization via pwd -P"

TASK_DIR_SYM="$TMP_TEST_DIR/task-sym"
STEP_DIR_SYM="$TASK_DIR_SYM/steps/01-step"
mkdir -p "$STEP_DIR_SYM"
echo "# Brief" > "$STEP_DIR_SYM/brief.md"

SYM_STEP_LINK="$TMP_TEST_DIR/sym-step-link"
SYM_WORK_LINK="$TMP_TEST_DIR/sym-work-link"
ln -s "$STEP_DIR_SYM" "$SYM_STEP_LINK"
ln -s "$MOCK_WORKDIR_1" "$SYM_WORK_LINK"

CANONICAL_STEP="$(cd "$STEP_DIR_SYM" && pwd -P)"
CANONICAL_WORK="$(cd "$MOCK_WORKDIR_1" && pwd -P)"

assert_ok "fresh execution via symlinked step and workdir paths succeeds" \
  env MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" "$RUN_TASK_BIN" "$SYM_STEP_LINK" "$SYM_WORK_LINK"

  # shellcheck disable=SC2016
assert_ok "metrics records canonical physical step_dir" \
  jq -e -s --arg s "$CANONICAL_STEP" 'map(select(.attempt == 1 and .step_dir == $s)) | length == 1' "$TASK_DIR_SYM/metrics.jsonl"

  # shellcheck disable=SC2016
assert_ok "metrics records canonical physical workdir" \
  jq -e -s --arg w "$CANONICAL_WORK" 'map(select(.attempt == 1 and .workdir == $w)) | length == 1' "$TASK_DIR_SYM/metrics.jsonl"

assert_ok "resume execution via symlinked step and workdir paths succeeds" \
  env MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" "$RUN_TASK_BIN" "$SYM_STEP_LINK" "$SYM_WORK_LINK" --resume-attempt 1

# -----------------------------------------------------------------------------
# 14. Source metrics validation and CONVERSATION_MISMATCH rejection
# -----------------------------------------------------------------------------
echo "==> Scenario 14: Source metrics validation and CONVERSATION_MISMATCH rejection"

TASK_DIR_VALID="$TMP_TEST_DIR/task-valid"
STEP_DIR_VALID="$TASK_DIR_VALID/steps/01-step"
mkdir -p "$STEP_DIR_VALID"
echo "# Brief" > "$STEP_DIR_VALID/brief.md"

CANON_STEP="$(cd "$STEP_DIR_VALID" && pwd -P)"
CANON_WORK="$(cd "$MOCK_WORKDIR_1" && pwd -P)"

cat <<'JSON' > "$STEP_DIR_VALID/run-1.jsonl"
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1","response":"# Report\nDone\n"}}
JSON

# 14a: Duplicate rows for attempt 1 in metrics.jsonl
cat <<EOF > "$TASK_DIR_VALID/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-valid","step":"01-step","step_dir":"$CANON_STEP","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1"}
{"ts":"2026-10-09T00:00:01Z","task":"task-valid","step":"01-step","step_dir":"$CANON_STEP","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1"}
EOF

clear_logs
assert_fail "duplicate metrics rows for attempt 1 is rejected" \
  run_harness_task "$STEP_DIR_VALID" --resume-attempt 1

# 14b: Source step_dir mismatch
cat <<EOF > "$TASK_DIR_VALID/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-valid","step":"01-step","step_dir":"/wrong/path/step","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1"}
EOF

clear_logs
assert_fail "step_dir mismatch in metrics is rejected" \
  run_harness_task "$STEP_DIR_VALID" --resume-attempt 1

# 14c: Non-terminal source status (WAITING / RUNNING)
cat <<EOF > "$TASK_DIR_VALID/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-valid","step":"01-step","step_dir":"$CANON_STEP","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"RUNNING","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1"}
EOF

clear_logs
assert_fail "non-terminal RUNNING status in source metrics is rejected" \
  run_harness_task "$STEP_DIR_VALID" --resume-attempt 1

# 14d: CONVERSATION_MISMATCH status rejected as source
cat <<EOF > "$TASK_DIR_VALID/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-valid","step":"01-step","step_dir":"$CANON_STEP","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":1,"status":"CONVERSATION_MISMATCH","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1"}
EOF

clear_logs
assert_fail "CONVERSATION_MISMATCH source status is rejected" \
  run_harness_task "$STEP_DIR_VALID" --resume-attempt 1

# 14e: Non-numeric exit_code
cat <<EOF > "$TASK_DIR_VALID/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-valid","step":"01-step","step_dir":"$CANON_STEP","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":"0","status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-val-1"}
EOF

clear_logs
assert_fail "non-numeric string exit_code in source metrics is rejected" \
  run_harness_task "$STEP_DIR_VALID" --resume-attempt 1

# 14f: Whitespace-only conversation_id
cat <<EOF > "$TASK_DIR_VALID/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-valid","step":"01-step","step_dir":"$CANON_STEP","workdir":"$CANON_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"   "}
EOF

clear_logs
assert_fail "whitespace-only conversation_id in source metrics is rejected" \
  run_harness_task "$STEP_DIR_VALID" --resume-attempt 1

# -----------------------------------------------------------------------------
# 15. History identity (latest recorded attempt & incomplete attempts)
# -----------------------------------------------------------------------------
echo "==> Scenario 15: History identity (latest recorded attempt & incomplete attempts)"

TASK_DIR_HIST="$TMP_TEST_DIR/task-hist"
STEP_DIR_HIST="$TASK_DIR_HIST/steps/01-step"
mkdir -p "$STEP_DIR_HIST"
echo "# Brief" > "$STEP_DIR_HIST/brief.md"

export MOCK_CONV_ID="conv-chain-1"
assert_ok "attempt 1 starts conv-chain-1" \
  run_harness_task "$STEP_DIR_HIST"

assert_ok "attempt 2 resumes attempt 1 on conv-chain-1" \
  run_harness_task "$STEP_DIR_HIST" --resume-attempt 1

# Now attempt 1 is NO LONGER the latest recorded attempt for conv-chain-1
clear_logs
assert_fail "attempting to resume older attempt 1 for conv-chain-1 fails (not latest recorded attempt)" \
  run_harness_task "$STEP_DIR_HIST" --resume-attempt 1

assert_ok "resuming latest attempt 2 succeeds" \
  run_harness_task "$STEP_DIR_HIST" --resume-attempt 2

# Simulate an incomplete attempt 4 that created prompt-4.md resuming conv-chain-1 but crashed before writing metrics
cat <<EOF > "$STEP_DIR_HIST/prompt-4.md"
# Resumed conversation
This attempt resumes conversation \`conv-chain-1\` from attempt 3.
EOF

clear_logs
assert_fail "resuming attempt 3 fails when newer incomplete attempt 4 for conv-chain-1 exists" \
  run_harness_task "$STEP_DIR_HIST" --resume-attempt 3

# But a plain fresh run on this step still succeeds and allocates attempt 5
unset MOCK_CONV_ID
export MOCK_CONV_ID="conv-fresh-after-incomplete"
assert_ok "plain run succeeds and allocates attempt 5 after incomplete attempt" \
  run_harness_task "$STEP_DIR_HIST"

assert_ok "attempt 5 metrics records mode=fresh" \
  jq -e -s 'map(select(.attempt == 5 and .mode == "fresh")) | length == 1' "$TASK_DIR_HIST/metrics.jsonl"
unset MOCK_CONV_ID

# -----------------------------------------------------------------------------
# 16. Artifact allocation with gaps and broken symlinks
# -----------------------------------------------------------------------------
echo "==> Scenario 16: Artifact allocation with gaps and broken symlinks"

TASK_DIR_GAP="$TMP_TEST_DIR/task-gap"
STEP_DIR_GAP="$TASK_DIR_GAP/steps/01-step"
mkdir -p "$STEP_DIR_GAP"
echo "# Brief" > "$STEP_DIR_GAP/brief.md"

CANON_GAP_STEP="$(cd "$STEP_DIR_GAP" && pwd -P)"
CANON_GAP_WORK="$(cd "$MOCK_WORKDIR_1" && pwd -P)"

# Case: metrics has attempt 1, run-1.jsonl is missing, orphan prompt-2.md exists
cat <<EOF > "$TASK_DIR_GAP/metrics.jsonl"
{"ts":"2026-10-09T00:00:00Z","task":"task-gap","step":"01-step","step_dir":"$CANON_GAP_STEP","workdir":"$CANON_GAP_WORK","attempt":1,"mode":"fresh","source_attempt":null,"requested_conversation_id":null,"counter_scope":"conversation","wall_duration_seconds":0.5,"variant":"baseline","harness_rev":"abc","designer":"unknown","model":"mock","trailer":"trailer","compute_backend":null,"compute_recovery_pending":false,"exit_code":0,"status":"SUCCESS","denied_tool_calls":0,"report_empty":false,"duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-gap-1"}
EOF

echo "ORPHAN PROMPT 2 CONTENT" > "$STEP_DIR_GAP/prompt-2.md"

assert_ok "fresh run allocates attempt 3 without overwriting orphan prompt-2.md" \
  run_harness_task "$STEP_DIR_GAP"

assert_ok "orphan prompt-2.md content was preserved intact" \
  grep -Fq "ORPHAN PROMPT 2 CONTENT" "$STEP_DIR_GAP/prompt-2.md"

assert_ok "prompt-3.md was created" \
  test -f "$STEP_DIR_GAP/prompt-3.md"

assert_ok "metrics recorded attempt 3" \
  jq -e -s 'map(select(.attempt == 3 and .mode == "fresh")) | length == 1' "$TASK_DIR_GAP/metrics.jsonl"

# Broken symlink case: create broken symlink for candidate attempt 4
ln -s "/nonexistent/path/for/test" "$STEP_DIR_GAP/run-4.jsonl"

assert_ok "candidate with broken symlink is treated as occupied and allocates attempt 5" \
  run_harness_task "$STEP_DIR_GAP"

assert_ok "prompt-5.md was created" \
  test -f "$STEP_DIR_GAP/prompt-5.md"

assert_ok "metrics recorded attempt 5" \
  jq -e -s 'map(select(.attempt == 5 and .mode == "fresh")) | length == 1' "$TASK_DIR_GAP/metrics.jsonl"

# -----------------------------------------------------------------------------
# 17. Flock prerequisite check
# -----------------------------------------------------------------------------
echo "==> Scenario 17: Flock prerequisite check"

TASK_DIR_PREREQ="$TMP_TEST_DIR/task-prereq"
STEP_DIR_PREREQ="$TASK_DIR_PREREQ/steps/01-step"
mkdir -p "$STEP_DIR_PREREQ"
echo "# Brief" > "$STEP_DIR_PREREQ/brief.md"

NO_FLOCK_BIN="$TMP_TEST_DIR/no-flock-bin"
mkdir -p "$NO_FLOCK_BIN"
# Create a path that has required binaries except flock
for tool in basename date dirname jq agy touch rm awk cat sed tr; do
  p="$(type -p "$tool" || true)"
  if [ -n "$p" ] && [ -x "$p" ]; then
    ln -sf "$p" "$NO_FLOCK_BIN/$tool"
  fi
done
ln -sf "$FAKE_BIN_DIR/agy" "$NO_FLOCK_BIN/agy"

assert_fail "run-task fails immediately with error when flock is missing" \
  env PATH="$NO_FLOCK_BIN" "$RUN_TASK_BIN" "$STEP_DIR_PREREQ" "$MOCK_WORKDIR_1"

# Interrupted attempts beyond a numbering gap must remain part of history.
STEP_DIR_GAP="$TMP_TEST_DIR/task-gap/steps/01-step"
mkdir -p "$STEP_DIR_GAP"
echo '# Brief' > "$STEP_DIR_GAP/brief.md"
assert_ok "gap fixture starts a conversation" run_harness_task "$STEP_DIR_GAP"
echo 'Resuming conv-default-1' > "$STEP_DIR_GAP/prompt-5.md"
clear_logs
assert_fail "incomplete same-conversation attempt beyond a gap blocks resume" \
  run_harness_task "$STEP_DIR_GAP" --resume-attempt 1
assert_ok "gap rejection does not invoke agy" test ! -s "$PROBE_LOG"
assert_ok "fresh run allocates above highest partial artifact" run_harness_task "$STEP_DIR_GAP"
assert_ok "fresh run used attempt 6" test -f "$STEP_DIR_GAP/run-6.jsonl"
assert_ok "partial attempt 5 is preserved" grep -Fxq 'Resuming conv-default-1' "$STEP_DIR_GAP/prompt-5.md"

# -----------------------------------------------------------------------------
echo "=========================================="
echo "Resume tests passed: $PASSED, failed: $FAILED"
echo "=========================================="
[ "$FAILED" -eq 0 ]
