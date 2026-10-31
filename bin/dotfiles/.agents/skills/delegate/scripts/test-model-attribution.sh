#!/usr/bin/env bash
#
# test-model-attribution.sh
#
# Focused offline test suite for session-backed Codex model attribution
# and runner integration with mock agy.
#
set -euo pipefail

# Clear inherited Codex env for deterministic tests
unset CODEX_THREAD_ID CODEX_HOME HARNESS_DESIGNER

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

TMP_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-attribution-test.XXXXXX")"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

echo "==> Setting up mock agy and workdir"

FAKE_BIN_DIR="$TMP_TEST_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"
AGY_INVOKED_FILE="$TMP_TEST_DIR/agy_invoked.count"
echo "0" > "$AGY_INVOKED_FILE"

cat <<EOF > "$FAKE_BIN_DIR/agy"
#!/usr/bin/env bash
# Count both model probes and implementation calls.
count=\$(cat "$AGY_INVOKED_FILE")
echo "\$((count + 1))" > "$AGY_INVOKED_FILE"

if [ "\$1" = "-p" ] && [ "\$2" = "/model" ]; then
  echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
  exit 0
fi

cat <<'JSON'
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"response":"# Report: Step 01\n\n## Summary\nMock run done.\n\n## Context discoveries / corrections\nNone\n"}}
JSON
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/agy"

# Mock workdir
MOCK_WORKDIR="$TMP_TEST_DIR/worktree"
mkdir -p "$MOCK_WORKDIR"
echo "# Mock Agent Instructions" > "$MOCK_WORKDIR/AGENTS.md"
git -C "$MOCK_WORKDIR" init -q

run_harness_task() {
  local step_dir="$1"
  shift
  PATH="$FAKE_BIN_DIR:$PATH" "$RUN_TASK_BIN" "$step_dir" "$MOCK_WORKDIR" "$@"
}

run_with_env() {
  local env_vars=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    env_vars+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift # consume --
  (
    for ev in "${env_vars[@]}"; do
      export "${ev?}"
    done
    "$@"
  )
}

# Helper to create synthetic Codex rollout
create_codex_rollout() {
  local codex_home="$1"
  local session_id="$2"
  local model="${3:-gpt-6.1-sol}"
  local sdir="$codex_home/sessions"
  mkdir -p "$sdir"
  local fpath="$sdir/rollout-20261101120000-$session_id.jsonl"
  cat <<JSON > "$fpath"
{"type":"session_meta","payload":{"id":"$session_id","cwd":"/tmp"}}
{"type":"turn_context","payload":{"model":"$model","turn_id":"11111111-1111-1111-1111-111111111111","cwd":"/tmp"}}
JSON
}

# Scenario 1: Wrong Codex label correction
echo "==> Scenario 1: Wrong Codex label correction"
CODEX_HOME_1="$TMP_TEST_DIR/codex-1"
SID_1="01234567-89ab-cdef-0123-456789abcdef"
create_codex_rollout "$CODEX_HOME_1" "$SID_1" "gpt-6.1-sol"

TASK_DIR_1="$TMP_TEST_DIR/task-correction"
STEP_DIR_1="$TASK_DIR_1/steps/01-step"
mkdir -p "$STEP_DIR_1"
cat <<'EOF' > "$STEP_DIR_1/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task succeeds with stale Codex label" \
  run_with_env CODEX_HOME="$CODEX_HOME_1" CODEX_THREAD_ID="$SID_1" HARNESS_DESIGNER="Codex (gpt-6)" -- \
  run_harness_task "$STEP_DIR_1"

METRICS_ROW_1="$(tail -n 1 "$TASK_DIR_1/metrics.jsonl")"
DESIGNER_1="$(jq -r '.designer' <<<"$METRICS_ROW_1")"
SOURCE_1="$(jq -r '.designer_source' <<<"$METRICS_ROW_1")"
SESSION_1="$(jq -r '.designer_session_id' <<<"$METRICS_ROW_1")"

assert_ok "stale Codex (gpt-6) was corrected to Codex (gpt-6.1-sol)" \
  test "$DESIGNER_1" = "Codex (gpt-6.1-sol)"

assert_ok "metrics recorded designer_source=codex-session" \
  test "$SOURCE_1" = "codex-session"

assert_ok "metrics recorded designer_session_id" \
  test "$SESSION_1" = "$SID_1"

# Scenario 2: Automatic unset designer label
echo "==> Scenario 2: Automatic unset designer label"
TASK_DIR_2="$TMP_TEST_DIR/task-unset"
STEP_DIR_2="$TASK_DIR_2/steps/01-step"
mkdir -p "$STEP_DIR_2"
cat <<'EOF' > "$STEP_DIR_2/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task succeeds with unset HARNESS_DESIGNER" \
  run_with_env CODEX_HOME="$CODEX_HOME_1" CODEX_THREAD_ID="$SID_1" -- \
  run_harness_task "$STEP_DIR_2"

METRICS_ROW_2="$(tail -n 1 "$TASK_DIR_2/metrics.jsonl")"
DESIGNER_2="$(jq -r '.designer' <<<"$METRICS_ROW_2")"
SOURCE_2="$(jq -r '.designer_source' <<<"$METRICS_ROW_2")"

assert_ok "unset HARNESS_DESIGNER automatically derived Codex (gpt-6.1-sol)" \
  test "$DESIGNER_2" = "Codex (gpt-6.1-sol)"

assert_ok "metrics recorded designer_source=codex-session for unset designer" \
  test "$SOURCE_2" = "codex-session"

# Scenario 3: Stale generic Codex or unknown label
echo "==> Scenario 3: Generic Codex or unknown label"
TASK_DIR_3="$TMP_TEST_DIR/task-generic"
STEP_DIR_3="$TASK_DIR_3/steps/01-step"
mkdir -p "$STEP_DIR_3"
cat <<'EOF' > "$STEP_DIR_3/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task succeeds with HARNESS_DESIGNER=Codex" \
  run_with_env CODEX_HOME="$CODEX_HOME_1" CODEX_THREAD_ID="$SID_1" HARNESS_DESIGNER="Codex" -- \
  run_harness_task "$STEP_DIR_3"

METRICS_ROW_3="$(tail -n 1 "$TASK_DIR_3/metrics.jsonl")"
DESIGNER_3="$(jq -r '.designer' <<<"$METRICS_ROW_3")"
assert_ok "bare Codex label was derived to Codex (gpt-6.1-sol)" \
  test "$DESIGNER_3" = "Codex (gpt-6.1-sol)"

# Scenario 4: Fail-before-agy for missing identified session
echo "==> Scenario 4: Fail-before-agy for missing identified session"
TASK_DIR_4="$TMP_TEST_DIR/task-missing-session"
STEP_DIR_4="$TASK_DIR_4/steps/01-step"
mkdir -p "$STEP_DIR_4"
cat <<'EOF' > "$STEP_DIR_4/brief.md"
# Step 01: Test Step
Do something.
EOF

CALLS_BEFORE="$(cat "$AGY_INVOKED_FILE")"

assert_fail "run-task fails when identified session is missing" \
  run_with_env CODEX_HOME="$CODEX_HOME_1" CODEX_THREAD_ID="99999999-9999-9999-9999-999999999999" HARNESS_DESIGNER="Codex (gpt-6)" -- \
  run_harness_task "$STEP_DIR_4"

CALLS_AFTER="$(cat "$AGY_INVOKED_FILE")"

assert_ok "agy was not invoked when session resolution fails" \
  test "$CALLS_BEFORE" = "$CALLS_AFTER"

assert_ok "no prompt artifact was created" \
  test ! -f "$STEP_DIR_4/prompt-1.md"

assert_ok "no report artifact was created" \
  test ! -f "$STEP_DIR_4/report-1.md"

assert_ok "no metrics row was written" \
  test ! -f "$TASK_DIR_4/metrics.jsonl"

# Scenario 5: Preserved Claude label
echo "==> Scenario 5: Preserved Claude label"
TASK_DIR_5="$TMP_TEST_DIR/task-claude"
STEP_DIR_5="$TASK_DIR_5/steps/01-step"
mkdir -p "$STEP_DIR_5"
cat <<'EOF' > "$STEP_DIR_5/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task preserves Claude label even if CODEX_THREAD_ID is present" \
  run_with_env CODEX_HOME="$CODEX_HOME_1" CODEX_THREAD_ID="$SID_1" HARNESS_DESIGNER="Claude (Opus 4.8)" -- \
  run_harness_task "$STEP_DIR_5"

METRICS_ROW_5="$(tail -n 1 "$TASK_DIR_5/metrics.jsonl")"
DESIGNER_5="$(jq -r '.designer' <<<"$METRICS_ROW_5")"
SOURCE_5="$(jq -r '.designer_source' <<<"$METRICS_ROW_5")"
SESSION_5="$(jq -r '.designer_session_id' <<<"$METRICS_ROW_5")"

assert_ok "Claude label was preserved intact" \
  test "$DESIGNER_5" = "Claude (Opus 4.8)"

assert_ok "metrics recorded designer_source=provided" \
  test "$SOURCE_5" = "provided"

assert_ok "metrics recorded designer_session_id=null" \
  test "$SESSION_5" = "null"

# Scenario 6: Explicit cross-host call without local CODEX_THREAD_ID
echo "==> Scenario 6: Cross-host call without local CODEX_THREAD_ID"
TASK_DIR_6="$TMP_TEST_DIR/task-crosshost"
STEP_DIR_6="$TASK_DIR_6/steps/01-step"
mkdir -p "$STEP_DIR_6"
cat <<'EOF' > "$STEP_DIR_6/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task preserves explicit supplied Codex label when CODEX_THREAD_ID is unset" \
  run_with_env HARNESS_DESIGNER="Codex (gpt-6-astra)" -- \
  run_harness_task "$STEP_DIR_6"

METRICS_ROW_6="$(tail -n 1 "$TASK_DIR_6/metrics.jsonl")"
DESIGNER_6="$(jq -r '.designer' <<<"$METRICS_ROW_6")"
SOURCE_6="$(jq -r '.designer_source' <<<"$METRICS_ROW_6")"
SESSION_6="$(jq -r '.designer_session_id' <<<"$METRICS_ROW_6")"

assert_ok "cross-host Codex label was preserved intact" \
  test "$DESIGNER_6" = "Codex (gpt-6-astra)"

assert_ok "metrics recorded designer_source=provided for cross-host" \
  test "$SOURCE_6" = "provided"

assert_ok "metrics recorded designer_session_id=null for cross-host" \
  test "$SESSION_6" = "null"

# Scenario 7: Unknown label when both unset
echo "==> Scenario 7: Unknown label when both unset"
TASK_DIR_7="$TMP_TEST_DIR/task-unknown"
STEP_DIR_7="$TASK_DIR_7/steps/01-step"
mkdir -p "$STEP_DIR_7"
cat <<'EOF' > "$STEP_DIR_7/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task succeeds when both CODEX_THREAD_ID and HARNESS_DESIGNER are unset" \
  run_harness_task "$STEP_DIR_7"

METRICS_ROW_7="$(tail -n 1 "$TASK_DIR_7/metrics.jsonl")"
DESIGNER_7="$(jq -r '.designer' <<<"$METRICS_ROW_7")"
SOURCE_7="$(jq -r '.designer_source' <<<"$METRICS_ROW_7")"

assert_ok "metrics recorded designer=unknown" \
  test "$DESIGNER_7" = "unknown"

assert_ok "metrics recorded designer_source=unknown" \
  test "$SOURCE_7" = "unknown"

# Scenario 8: CODEX_HOME with spaces
echo "==> Scenario 8: CODEX_HOME with spaces"
CODEX_HOME_SPACES="$TMP_TEST_DIR/codex home spaces"
SID_SPACES="12345678-1234-1234-1234-123456789abc"
create_codex_rollout "$CODEX_HOME_SPACES" "$SID_SPACES" "gpt-6.1-sol"

TASK_DIR_8="$TMP_TEST_DIR/task spaces"
STEP_DIR_8="$TASK_DIR_8/steps/01-step"
mkdir -p "$STEP_DIR_8"
cat <<'EOF' > "$STEP_DIR_8/brief.md"
# Step 01: Test Step
Do something.
EOF

assert_ok "run-task succeeds with spaces in CODEX_HOME and task directory" \
  run_with_env CODEX_HOME="$CODEX_HOME_SPACES" CODEX_THREAD_ID="$SID_SPACES" -- \
  run_harness_task "$STEP_DIR_8"

METRICS_ROW_8="$(tail -n 1 "$TASK_DIR_8/metrics.jsonl")"
DESIGNER_8="$(jq -r '.designer' <<<"$METRICS_ROW_8")"
assert_ok "resolved model with spaced paths" \
  test "$DESIGNER_8" = "Codex (gpt-6.1-sol)"

echo "=========================================="
echo "Model attribution tests passed: $PASSED, failed: $FAILED"
echo "=========================================="

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
