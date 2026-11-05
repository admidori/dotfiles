#!/usr/bin/env bash
#
# test-docker-sandbox.sh
#
# Focused test suite for sequential Docker Sandbox delegation runner mode:
# - HARNESS_EXECUTION_MODE validation (default host, invalid rejected before agy)
# - Accidental-host guard (rejection on unmarked host/environment)
# - Correct full-access arguments (--dangerously-skip-permissions, --settings)
#   and working directory (workdir) in marked sandbox
# - Same-workdir contention across distinct step dirs & worktree isolation
# - Stage/commit detection (rejecting acceptance when HEAD, branch, or index changes)
# - Project directory survival across completion and interruption
#
set -euo pipefail

# Clear inherited Codex env for deterministic tests
unset CODEX_THREAD_ID CODEX_HOME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_TASK_BIN="$SCRIPT_DIR/run-task.sh"

PASSED=0
FAILED=0
SKIPPED=0

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

skip_test() {
  local desc="$1"
  local reason="$2"
  echo "  skip : $desc ($reason)"
  SKIPPED=$((SKIPPED + 1))
}

TMP_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-docker-test.XXXXXX")"
# shellcheck disable=SC2317,SC2329
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
PROBE_CWD="$MOCK_LOG_DIR/agy_probe_cwd.log"
CALLS_LOG="$MOCK_LOG_DIR/agy_calls.log"
CALLS_JSONL="$MOCK_LOG_DIR/agy_calls.jsonl"
CALLS_CWD="$MOCK_LOG_DIR/agy_calls_cwd.log"

FAKE_BIN_DIR="$TMP_TEST_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"

cat <<'EOF' > "$FAKE_BIN_DIR/agy"
#!/usr/bin/env bash
if [ -n "${MOCK_PROBE_SCRIPT:-}" ] && [ "$1" = "-p" ] && [ "$2" = "/model" ]; then
  exec "$MOCK_PROBE_SCRIPT" "$@"
fi
if [ "$1" = "-p" ] && [ "$2" = "/model" ]; then
  pwd -P >> "${MOCK_LOG_DIR}/agy_probe_cwd.log"
  echo "$*" >> "${MOCK_LOG_DIR}/agy_probe.log"
  jq -n -c '{argv: $ARGS.positional}' --args -- "$@" >> "${MOCK_LOG_DIR}/agy_probe.jsonl"
  if [ -n "${MOCK_PROBE_EMPTY:-}" ]; then
    echo '{}'
    exit 0
  fi
  echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
  exit 0
fi

pwd -P >> "${MOCK_LOG_DIR}/agy_calls_cwd.log"
echo "$*" >> "${MOCK_LOG_DIR}/agy_calls.log"
jq -n -c '{argv: $ARGS.positional}' --args -- "$@" >> "${MOCK_LOG_DIR}/agy_calls.jsonl"

if [ -n "${MOCK_RUN_SCRIPT:-}" ] && [ -f "$MOCK_RUN_SCRIPT" ]; then
  exec "$MOCK_RUN_SCRIPT" "$@"
fi

cat <<JSON
{"event":"step_update","step_update":{"step_index":1,"state":"DONE"}}
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":50},"conversation_id":"conv-test-1","response":"# Report: Step 01\n\n## Summary\nDone.\n"}}
JSON
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/agy"

clear_logs() {
  rm -f "$PROBE_LOG" "$PROBE_JSONL" "$PROBE_CWD" "$CALLS_LOG" "$CALLS_JSONL" "$CALLS_CWD"
}

is_sandbox_marked() {
  local marker="/etc/agent-harness/docker-sandbox"
  [ -e "$marker" ] && [ ! -L "$marker" ] && [ -f "$marker" ] && [ "$(stat -c '%u' "$marker" 2>/dev/null || echo -1)" = "0" ]
}

# -----------------------------------------------------------------------------
# Scenario 1: HARNESS_EXECUTION_MODE validation
# -----------------------------------------------------------------------------
echo "==> Scenario 1: HARNESS_EXECUTION_MODE validation"

TASK_DIR_1="$TMP_TEST_DIR/task-1"
STEP_DIR_1="$TASK_DIR_1/steps/01-step"
WORKDIR_1="$TMP_TEST_DIR/worktree-1"
mkdir -p "$STEP_DIR_1" "$WORKDIR_1"
echo "# Brief 1" > "$STEP_DIR_1/brief.md"

clear_logs
OUTPUT_1="$TMP_TEST_DIR/output_1.log"
set +e
PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="invalid-mode" \
  "$RUN_TASK_BIN" "$STEP_DIR_1" "$WORKDIR_1" >"$OUTPUT_1" 2>&1
rc_1=$?
set -e

assert_fail "invalid HARNESS_EXECUTION_MODE fails" \
  [ "$rc_1" -eq 0 ]

assert_ok "invalid HARNESS_EXECUTION_MODE exits with code 2" \
  [ "$rc_1" -eq 2 ]

assert_ok "invalid mode prints descriptive error message" \
  grep -Fq "error: invalid HARNESS_EXECUTION_MODE 'invalid-mode' (expected 'host' or 'docker-sandbox')" "$OUTPUT_1"

assert_ok "no artifacts created on invalid mode" \
  test ! -f "$STEP_DIR_1/prompt-1.md" && test ! -f "$STEP_DIR_1/run-1.jsonl"

assert_ok "agy was never invoked on invalid mode" \
  test ! -f "$CALLS_LOG"

# -----------------------------------------------------------------------------
# Scenario 2: Docker mode rejected on unmarked host / environment
# -----------------------------------------------------------------------------
echo "==> Scenario 2: Docker mode rejected on unmarked host / environment"

TASK_DIR_2="$TMP_TEST_DIR/task-2"
STEP_DIR_2="$TASK_DIR_2/steps/01-step"
WORKDIR_2="$TMP_TEST_DIR/worktree-2"
mkdir -p "$STEP_DIR_2" "$WORKDIR_2"
echo "# Brief 2" > "$STEP_DIR_2/brief.md"

# 2a: Missing SANDBOX_ID
clear_logs
OUTPUT_2A="$TMP_TEST_DIR/output_2a.log"
set +e
PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
  SANDBOX_ID="" SANDBOX_VM_ID="vm-123" SBX_AGENT="designer" \
  "$RUN_TASK_BIN" "$STEP_DIR_2" "$WORKDIR_2" >"$OUTPUT_2A" 2>&1
rc_2a=$?
set -e

assert_ok "docker mode rejected when SANDBOX_ID is empty (exit 2)" \
  [ "$rc_2a" -eq 2 ]

assert_ok "error specifies missing required environment variables" \
  grep -Fq "error: docker-sandbox execution mode requires nonempty SANDBOX_ID, SANDBOX_VM_ID, and SBX_AGENT" "$OUTPUT_2A"

assert_ok "agy not called when SANDBOX_ID is empty" \
  test ! -f "$CALLS_LOG"

# 2b: Missing SANDBOX_VM_ID
clear_logs
OUTPUT_2B="$TMP_TEST_DIR/output_2b.log"
set +e
PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
  SANDBOX_ID="sbx-123" SANDBOX_VM_ID="" SBX_AGENT="designer" \
  "$RUN_TASK_BIN" "$STEP_DIR_2" "$WORKDIR_2" >"$OUTPUT_2B" 2>&1
rc_2b=$?
set -e

assert_ok "docker mode rejected when SANDBOX_VM_ID is empty (exit 2)" \
  [ "$rc_2b" -eq 2 ]

# 2c: Missing SBX_AGENT
clear_logs
OUTPUT_2C="$TMP_TEST_DIR/output_2c.log"
set +e
PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
  SANDBOX_ID="sbx-123" SANDBOX_VM_ID="vm-123" SBX_AGENT="" \
  "$RUN_TASK_BIN" "$STEP_DIR_2" "$WORKDIR_2" >"$OUTPUT_2C" 2>&1
rc_2c=$?
set -e

assert_ok "docker mode rejected when SBX_AGENT is empty (exit 2)" \
  [ "$rc_2c" -eq 2 ]

# -----------------------------------------------------------------------------
# Scenario 3: Same-workdir contention & worktree isolation
# -----------------------------------------------------------------------------
echo "==> Scenario 3: Same-workdir contention & worktree isolation"

TASK_DIR_3="$TMP_TEST_DIR/task-3"
STEP_DIR_3A="$TASK_DIR_3/steps/01-step"
STEP_DIR_3B="$TASK_DIR_3/steps/02-step"
WORKDIR_3="$TMP_TEST_DIR/worktree-3"
mkdir -p "$STEP_DIR_3A" "$STEP_DIR_3B" "$WORKDIR_3"
echo "# Brief 3A" > "$STEP_DIR_3A/brief.md"
echo "# Brief 3B" > "$STEP_DIR_3B/brief.md"
git -C "$WORKDIR_3" init -q -b main
git -C "$WORKDIR_3" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

# 3a: Step 3A holds workdir lock, Step 3B attempts to target the same workdir
git_lock="$(git -C "$WORKDIR_3" rev-parse --path-format=absolute --git-path harness.lock 2>/dev/null || echo "$WORKDIR_3/.git/harness.lock")"
touch "$git_lock"
(
  exec 8>>"$git_lock"
  flock -n 8
  sleep 2
) &
BG_LOCK_PID=$!
sleep 0.1

clear_logs
OUTPUT_3="$TMP_TEST_DIR/output_3.log"
set +e
MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
  "$RUN_TASK_BIN" "$STEP_DIR_3B" "$WORKDIR_3" >"$OUTPUT_3" 2>&1
rc_3=$?
set -e

wait "$BG_LOCK_PID" 2>/dev/null || true

assert_fail "concurrent execution targeting same workdir is rejected" \
  [ "$rc_3" -eq 0 ]

assert_ok "workdir lock collision exits with code 1" \
  [ "$rc_3" -eq 1 ]

assert_ok "workdir lock collision prints error message" \
  grep -Fq "error: workdir is locked by another process: $WORKDIR_3" "$OUTPUT_3"

assert_ok "agy was not called during workdir lock collision" \
  test ! -f "$CALLS_LOG"

# 3b: Distinct worktrees do not collide
WT_DIR_3="$TMP_TEST_DIR/worktree-3-linked"
git -C "$WORKDIR_3" worktree add "$WT_DIR_3" -b wt-branch -q

wt_lock="$(git -C "$WT_DIR_3" rev-parse --path-format=absolute --git-path harness.lock 2>/dev/null || true)"
assert_ok "linked worktree has distinct git metadata lock path" \
  [ "$git_lock" != "$wt_lock" ]

# -----------------------------------------------------------------------------
# Scenario 4: Correct full-access arguments and cwd in marked sandbox
# -----------------------------------------------------------------------------
echo "==> Scenario 4: Correct full-access arguments and cwd in marked sandbox"

if is_sandbox_marked; then
  TASK_DIR_4="$TMP_TEST_DIR/task-4"
  STEP_DIR_4="$TASK_DIR_4/steps/01-step"
  WORKDIR_4="$TMP_TEST_DIR/worktree-4"
  mkdir -p "$STEP_DIR_4" "$WORKDIR_4"
  echo "# Brief 4" > "$STEP_DIR_4/brief.md"
  git -C "$WORKDIR_4" init -q -b main
  git -C "$WORKDIR_4" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

  clear_logs
  OUTPUT_4="$TMP_TEST_DIR/output_4.log"
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" \
    SANDBOX_VM_ID="test-vm-id" \
    SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_4" "$WORKDIR_4" >"$OUTPUT_4" 2>&1

  assert_ok "docker-sandbox run succeeds in marked environment" \
    test -s "$STEP_DIR_4/report-1.md"

  assert_ok "probe cwd matches workdir in docker-sandbox mode" \
    [ "$(cat "$PROBE_CWD")" = "$WORKDIR_4" ]

  assert_ok "run cwd matches workdir in docker-sandbox mode" \
    [ "$(cat "$CALLS_CWD")" = "$WORKDIR_4" ]

  assert_ok "probe -p /model ordering is preserved as first arguments" \
    jq -e '.argv[0] == "-p" and .argv[1] == "/model"' "$PROBE_JSONL"

  assert_ok "probe argv contains --dangerously-skip-permissions" \
    jq -e '.argv | any(. == "--dangerously-skip-permissions")' "$PROBE_JSONL"

  # shellcheck disable=SC2016
  assert_ok "probe argv contains disabled terminal sandbox settings" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .enableTerminalSandbox == false' "$PROBE_JSONL"

  assert_ok "run argv contains --dangerously-skip-permissions" \
    jq -e '.argv | any(. == "--dangerously-skip-permissions")' "$CALLS_JSONL"

  # shellcheck disable=SC2016
  assert_ok "run argv contains disabled terminal sandbox settings" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .enableTerminalSandbox == false' "$CALLS_JSONL"

  assert_ok "metrics records execution_mode=docker-sandbox and git_state_changed=false" \
    jq -e '.execution_mode == "docker-sandbox" and .git_state_changed == false and .status == "SUCCESS"' "$TASK_DIR_4/metrics.jsonl"
else
  skip_test "docker-sandbox positive argument and cwd checks" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 5: Stage/commit mutation detection in docker-sandbox mode
# -----------------------------------------------------------------------------
echo "==> Scenario 5: Stage/commit mutation detection in docker-sandbox mode"

if is_sandbox_marked; then
  # 5a: agy creates a commit
  TASK_DIR_5A="$TMP_TEST_DIR/task-5a"
  STEP_DIR_5A="$TASK_DIR_5A/steps/01-step"
  WORKDIR_5A="$TMP_TEST_DIR/worktree-5a"
  mkdir -p "$STEP_DIR_5A" "$WORKDIR_5A"
  echo "# Brief 5A" > "$STEP_DIR_5A/brief.md"
  git -C "$WORKDIR_5A" init -q -b main
  git -C "$WORKDIR_5A" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

  MUTATE_COMMIT_SCRIPT="$TMP_TEST_DIR/mutate_commit.sh"
  cat <<'EOF' > "$MUTATE_COMMIT_SCRIPT"
#!/usr/bin/env bash
git -c user.name="Mutator" -c user.email="mutator@test.com" commit --allow-empty -m "unauthorized commit" -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-mut-1","response":"# Report\nDone commit\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_COMMIT_SCRIPT"

  clear_logs
  OUTPUT_5A="$TMP_TEST_DIR/output_5a.log"
  set +e
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$MUTATE_COMMIT_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_5A" "$WORKDIR_5A" >"$OUTPUT_5A" 2>&1
  rc_5a=$?
  set -e

  assert_ok "commit mutation rejects acceptance (exit code non-zero 1)" \
    [ "$rc_5a" -eq 1 ]

  assert_ok "commit mutation sets status=GIT_STATE_MUTATED in metrics" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_state_changed == true and .exit_code == 1' "$TASK_DIR_5A/metrics.jsonl"

  git -C "$WORKDIR_5A" log -1 --pretty=%B > "$TMP_TEST_DIR/commit_5a.txt"
  assert_ok "commit mutation is not silently undone" \
    grep -Fq "unauthorized commit" "$TMP_TEST_DIR/commit_5a.txt"

  # 5b: agy stages a file (git add)
  TASK_DIR_5B="$TMP_TEST_DIR/task-5b"
  STEP_DIR_5B="$TASK_DIR_5B/steps/01-step"
  WORKDIR_5B="$TMP_TEST_DIR/worktree-5b"
  mkdir -p "$STEP_DIR_5B" "$WORKDIR_5B"
  echo "# Brief 5B" > "$STEP_DIR_5B/brief.md"
  git -C "$WORKDIR_5B" init -q -b main
  git -C "$WORKDIR_5B" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

  MUTATE_STAGE_SCRIPT="$TMP_TEST_DIR/mutate_stage.sh"
  cat <<'EOF' > "$MUTATE_STAGE_SCRIPT"
#!/usr/bin/env bash
echo "staged content" > staged_file.txt
git add staged_file.txt
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-mut-2","response":"# Report\nDone stage\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_STAGE_SCRIPT"

  clear_logs
  OUTPUT_5B="$TMP_TEST_DIR/output_5b.log"
  set +e
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$MUTATE_STAGE_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_5B" "$WORKDIR_5B" >"$OUTPUT_5B" 2>&1
  rc_5b=$?
  set -e

  assert_ok "staging mutation rejects acceptance (exit code non-zero 1)" \
    [ "$rc_5b" -eq 1 ]

  assert_ok "staging mutation sets status=GIT_STATE_MUTATED in metrics" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_state_changed == true and .exit_code == 1' "$TASK_DIR_5B/metrics.jsonl"

  git -C "$WORKDIR_5B" diff --cached --name-only > "$TMP_TEST_DIR/diff_5b.txt"
  assert_ok "staged file is not silently un-staged" \
    grep -Fq "staged_file.txt" "$TMP_TEST_DIR/diff_5b.txt"

  # 5c: agy branches/checks out (symbolic ref changed)
  TASK_DIR_5C="$TMP_TEST_DIR/task-5c"
  STEP_DIR_5C="$TASK_DIR_5C/steps/01-step"
  WORKDIR_5C="$TMP_TEST_DIR/worktree-5c"
  mkdir -p "$STEP_DIR_5C" "$WORKDIR_5C"
  echo "# Brief 5C" > "$STEP_DIR_5C/brief.md"
  git -C "$WORKDIR_5C" init -q -b main
  git -C "$WORKDIR_5C" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

  MUTATE_BRANCH_SCRIPT="$TMP_TEST_DIR/mutate_branch.sh"
  cat <<'EOF' > "$MUTATE_BRANCH_SCRIPT"
#!/usr/bin/env bash
git checkout -b unauthorized-branch -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-mut-3","response":"# Report\nDone branch\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_BRANCH_SCRIPT"

  clear_logs
  OUTPUT_5C="$TMP_TEST_DIR/output_5c.log"
  set +e
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$MUTATE_BRANCH_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_5C" "$WORKDIR_5C" >"$OUTPUT_5C" 2>&1
  rc_5c=$?
  set -e

  assert_ok "branch checkout mutation rejects acceptance (exit code non-zero 1)" \
    [ "$rc_5c" -eq 1 ]

  assert_ok "branch checkout mutation sets status=GIT_STATE_MUTATED in metrics" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_state_changed == true and .exit_code == 1' "$TASK_DIR_5C/metrics.jsonl"

  # 5d: normal execution failure with mutation
  TASK_DIR_5D="$TMP_TEST_DIR/task-5d"
  STEP_DIR_5D="$TASK_DIR_5D/steps/01-step"
  WORKDIR_5D="$TMP_TEST_DIR/worktree-5d"
  mkdir -p "$STEP_DIR_5D" "$WORKDIR_5D"
  echo "# Brief 5D" > "$STEP_DIR_5D/brief.md"
  git -C "$WORKDIR_5D" init -q -b main
  git -C "$WORKDIR_5D" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

  MUTATE_FAIL_SCRIPT="$TMP_TEST_DIR/mutate_fail.sh"
  cat <<'EOF' > "$MUTATE_FAIL_SCRIPT"
#!/usr/bin/env bash
echo "dirty" > staged_err.txt
git add staged_err.txt
cat <<JSON
{"event":"result","result":{"status":"ERROR","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-mut-4","response":"# Report\nFailed\n"}}
JSON
exit 1
EOF
  chmod +x "$MUTATE_FAIL_SCRIPT"

  clear_logs
  OUTPUT_5D="$TMP_TEST_DIR/output_5d.log"
  set +e
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$MUTATE_FAIL_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_5D" "$WORKDIR_5D" >"$OUTPUT_5D" 2>&1
  rc_5d=$?
  set -e

  assert_ok "execution failure with mutation exits non-zero" \
    [ "$rc_5d" -ne 0 ]

  assert_ok "execution failure with mutation rejects acceptance and sets GIT_STATE_MUTATED" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_state_changed == true and .exit_code == 1' "$TASK_DIR_5D/metrics.jsonl"

  # 5e: execution failure with branch switching
  TASK_DIR_5E="$TMP_TEST_DIR/task-5e"
  STEP_DIR_5E="$TASK_DIR_5E/steps/01-step"
  WORKDIR_5E="$TMP_TEST_DIR/worktree-5e"
  mkdir -p "$STEP_DIR_5E" "$WORKDIR_5E"
  echo "# Brief 5E" > "$STEP_DIR_5E/brief.md"
  git -C "$WORKDIR_5E" init -q -b main
  git -C "$WORKDIR_5E" -c user.name="Test" -c user.email="test@test.com" commit --allow-empty -m "init" -q

  MUTATE_FAIL_BRANCH_SCRIPT="$TMP_TEST_DIR/mutate_fail_branch.sh"
  cat <<'EOF' > "$MUTATE_FAIL_BRANCH_SCRIPT"
#!/usr/bin/env bash
git checkout -b err-branch -q
cat <<JSON
{"event":"result","result":{"status":"ERROR","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-mut-5","response":"# Report\nFailed branch\n"}}
JSON
exit 1
EOF
  chmod +x "$MUTATE_FAIL_BRANCH_SCRIPT"

  clear_logs
  OUTPUT_5E="$TMP_TEST_DIR/output_5e.log"
  set +e
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$MUTATE_FAIL_BRANCH_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_5E" "$WORKDIR_5E" >"$OUTPUT_5E" 2>&1
  rc_5e=$?
  set -e

  assert_ok "execution failure with branch switching exits non-zero" \
    [ "$rc_5e" -ne 0 ]

  assert_ok "execution failure with branch switching rejects acceptance and sets GIT_STATE_MUTATED" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_state_changed == true and .exit_code == 1' "$TASK_DIR_5E/metrics.jsonl"
else
  skip_test "docker-sandbox git mutation checks" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 6: Project directory survives completion and interruption
# -----------------------------------------------------------------------------
echo "==> Scenario 6: Project directory survives completion and interruption"

TASK_DIR_6="$TMP_TEST_DIR/task-6"
STEP_DIR_6A="$TASK_DIR_6/steps/01-step"
WORKDIR_6A="$TMP_TEST_DIR/worktree-6a"
mkdir -p "$STEP_DIR_6A" "$WORKDIR_6A"
echo "# Brief 6A" > "$STEP_DIR_6A/brief.md"
echo "permanent project data" > "$WORKDIR_6A/data.txt"

# 6a: Completion survival (in host mode and docker mode)
clear_logs
MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
  "$RUN_TASK_BIN" "$STEP_DIR_6A" "$WORKDIR_6A" >/dev/null 2>&1

assert_ok "workdir survives normal completion in host mode" \
  test -d "$WORKDIR_6A" && test -f "$WORKDIR_6A/data.txt"

if is_sandbox_marked; then
  STEP_DIR_6B="$TASK_DIR_6/steps/02-step"
  WORKDIR_6B="$TMP_TEST_DIR/worktree-6b"
  mkdir -p "$STEP_DIR_6B" "$WORKDIR_6B"
  echo "# Brief 6B" > "$STEP_DIR_6B/brief.md"
  echo "permanent project data" > "$WORKDIR_6B/data.txt"

  clear_logs
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_6B" "$WORKDIR_6B" >/dev/null 2>&1

  assert_ok "workdir survives normal completion in docker-sandbox mode" \
    test -d "$WORKDIR_6B" && test -f "$WORKDIR_6B/data.txt"

  # 6b: Interruption survival (TERM signal)
  STEP_DIR_6C="$TASK_DIR_6/steps/03-step"
  WORKDIR_6C="$TMP_TEST_DIR/worktree-6c"
  mkdir -p "$STEP_DIR_6C" "$WORKDIR_6C"
  echo "# Brief 6C" > "$STEP_DIR_6C/brief.md"
  echo "permanent data before term" > "$WORKDIR_6C/preserved.txt"

  SLEEP_SCRIPT_6="$TMP_TEST_DIR/sleep_script_6.sh"
  READY_FILE_6="$TMP_TEST_DIR/ready_6"
  rm -f "$READY_FILE_6"
  cat <<EOF > "$SLEEP_SCRIPT_6"
#!/usr/bin/env bash
touch "$READY_FILE_6"
sleep 5
exit 0
EOF
  chmod +x "$SLEEP_SCRIPT_6"

  clear_logs
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$SLEEP_SCRIPT_6" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    "$RUN_TASK_BIN" "$STEP_DIR_6C" "$WORKDIR_6C" >/dev/null 2>&1 &
  RUNNER_PID_6=$!

  # Wait for agy to start
  waited=0
  while [ ! -f "$READY_FILE_6" ] && [ "$waited" -lt 50 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done

  # Send TERM to runner
  kill -TERM "$RUNNER_PID_6" 2>/dev/null || true
  wait "$RUNNER_PID_6" 2>/dev/null || true

  assert_ok "workdir survives runner TERM interruption in docker-sandbox mode" \
    test -d "$WORKDIR_6C" && test -f "$WORKDIR_6C/preserved.txt"

  # 6d: Timeout survival
  STEP_DIR_6D="$TASK_DIR_6/steps/04-step"
  WORKDIR_6D="$TMP_TEST_DIR/worktree-6d"
  mkdir -p "$STEP_DIR_6D" "$WORKDIR_6D"
  echo "# Brief 6D" > "$STEP_DIR_6D/brief.md"
  echo "permanent data before timeout" > "$WORKDIR_6D/preserved_timeout.txt"

  SLEEP_FOREVER_6="$TMP_TEST_DIR/sleep_forever_6.sh"
  cat <<'EOF' > "$SLEEP_FOREVER_6"
#!/usr/bin/env bash
sleep 100
exit 0
EOF
  chmod +x "$SLEEP_FOREVER_6"

  clear_logs
  set +e
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" \
    MOCK_RUN_SCRIPT="$SLEEP_FOREVER_6" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    AGY_TIMEOUT="1s" AGY_TIMEOUT_MARGIN_SECONDS="0" AGY_RESULT_GRACE_SECONDS="1" \
    "$RUN_TASK_BIN" "$STEP_DIR_6D" "$WORKDIR_6D" >/dev/null 2>&1
  rc_6d=$?
  set -e

  assert_ok "timeout run exits with code 124" \
    [ "$rc_6d" -eq 124 ]

  assert_ok "workdir survives timeout in docker-sandbox mode" \
    test -d "$WORKDIR_6D" && test -f "$WORKDIR_6D/preserved_timeout.txt"
fi

# -----------------------------------------------------------------------------
# Scenario 7: HARNESS_GIT_POLICY option validation
# -----------------------------------------------------------------------------
echo "==> Scenario 7: HARNESS_GIT_POLICY option validation"

TASK_DIR_7="$TMP_TEST_DIR/task-7"
STEP_DIR_7="$TASK_DIR_7/steps/01-step"
WORKDIR_7="$TMP_TEST_DIR/worktree-7"
mkdir -p "$STEP_DIR_7" "$WORKDIR_7"
echo "# Brief 7" > "$STEP_DIR_7/brief.md"

# 7a: Invalid HARNESS_GIT_POLICY value
clear_logs
OUTPUT_7A="$TMP_TEST_DIR/output_7a.log"
set +e
PATH="$FAKE_BIN_DIR:$PATH" HARNESS_GIT_POLICY="invalid-policy" \
  "$RUN_TASK_BIN" "$STEP_DIR_7" "$WORKDIR_7" >"$OUTPUT_7A" 2>&1
rc_7a=$?
set -e

assert_fail "invalid HARNESS_GIT_POLICY fails" \
  [ "$rc_7a" -eq 0 ]
assert_ok "invalid HARNESS_GIT_POLICY exits with code 2" \
  [ "$rc_7a" -eq 2 ]
assert_ok "invalid HARNESS_GIT_POLICY prints error message" \
  grep -Fq "error: invalid HARNESS_GIT_POLICY 'invalid-policy' (expected 'strict' or 'task-commits')" "$OUTPUT_7A"
assert_ok "no artifacts created on invalid HARNESS_GIT_POLICY" \
  test ! -f "$STEP_DIR_7/prompt-1.md"
assert_ok "agy was never invoked on invalid HARNESS_GIT_POLICY" \
  test ! -f "$CALLS_LOG"

# 7b: Forbidden host opt-in: task-commits in host mode
clear_logs
OUTPUT_7B="$TMP_TEST_DIR/output_7b.log"
set +e
PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="host" HARNESS_GIT_POLICY="task-commits" \
  "$RUN_TASK_BIN" "$STEP_DIR_7" "$WORKDIR_7" >"$OUTPUT_7B" 2>&1
rc_7b=$?
set -e

assert_fail "task-commits in host mode fails" \
  [ "$rc_7b" -eq 0 ]
assert_ok "task-commits in host mode exits with code 2" \
  [ "$rc_7b" -eq 2 ]
assert_ok "task-commits in host mode prints descriptive error message" \
  grep -Fq "error: HARNESS_GIT_POLICY=task-commits is only supported in docker-sandbox execution mode" "$OUTPUT_7B"
assert_ok "agy was never invoked for host opt-in" \
  test ! -f "$CALLS_LOG"

# -----------------------------------------------------------------------------
# Scenario 8: task-commits prerequisites validation
# -----------------------------------------------------------------------------
echo "==> Scenario 8: task-commits prerequisites validation"

if is_sandbox_marked; then
  TASK_DIR_8="$TMP_TEST_DIR/task-8"
  STEP_DIR_8="$TASK_DIR_8/steps/01-step"
  WORKDIR_8="$TMP_TEST_DIR/worktree-8"
  mkdir -p "$STEP_DIR_8" "$WORKDIR_8"
  echo "# Brief 8" > "$STEP_DIR_8/brief.md"

  git -C "$WORKDIR_8" init -q -b main
  echo "initial content" > "$WORKDIR_8/init.txt"
  git -C "$WORKDIR_8" add init.txt
  git -C "$WORKDIR_8" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_8="$(git -C "$WORKDIR_8" rev-parse HEAD)"
  git -C "$WORKDIR_8" checkout -q -b task/feature-8

  # 8a: Missing HARNESS_TASK_BRANCH
  clear_logs
  OUTPUT_8A="$TMP_TEST_DIR/output_8a.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="" HARNESS_TASK_BASE="$BASE_8" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8A" 2>&1
  rc_8a=$?
  set -e
  assert_ok "missing HARNESS_TASK_BRANCH exits 2" [ "$rc_8a" -eq 2 ]
  assert_ok "missing HARNESS_TASK_BRANCH prints error" \
    grep -Fq "error: HARNESS_GIT_POLICY=task-commits requires nonempty HARNESS_TASK_BRANCH" "$OUTPUT_8A"
  assert_ok "agy never invoked when HARNESS_TASK_BRANCH missing" test ! -f "$CALLS_LOG"

  # 8b: Missing HARNESS_TASK_BASE
  clear_logs
  OUTPUT_8B="$TMP_TEST_DIR/output_8b.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-8" HARNESS_TASK_BASE="" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8B" 2>&1
  rc_8b=$?
  set -e
  assert_ok "missing HARNESS_TASK_BASE exits 2" [ "$rc_8b" -eq 2 ]
  assert_ok "missing HARNESS_TASK_BASE prints error" \
    grep -Fq "error: HARNESS_GIT_POLICY=task-commits requires nonempty HARNESS_TASK_BASE" "$OUTPUT_8B"

  # 8c: HARNESS_TASK_BRANCH is main
  clear_logs
  OUTPUT_8C="$TMP_TEST_DIR/output_8c.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="main" HARNESS_TASK_BASE="$BASE_8" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8C" 2>&1
  rc_8c=$?
  set -e
  assert_ok "HARNESS_TASK_BRANCH=main exits 2" [ "$rc_8c" -eq 2 ]
  assert_ok "main branch rejected with message" \
    grep -Fq "error: HARNESS_TASK_BRANCH cannot be main or master" "$OUTPUT_8C"

  # 8d: Branch mismatch
  clear_logs
  OUTPUT_8D="$TMP_TEST_DIR/output_8d.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/other-branch" HARNESS_TASK_BASE="$BASE_8" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8D" 2>&1
  rc_8d=$?
  set -e
  assert_ok "branch mismatch exits 2" [ "$rc_8d" -eq 2 ]
  assert_ok "branch mismatch prints error" \
    grep -Fq "error: workdir branch 'task/feature-8' does not match HARNESS_TASK_BRANCH 'task/other-branch'" "$OUTPUT_8D"

  # 8e: Nonexistent base commit
  clear_logs
  OUTPUT_8E="$TMP_TEST_DIR/output_8e.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-8" \
    HARNESS_TASK_BASE="0123456789012345678901234567890123456789" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8E" 2>&1
  rc_8e=$?
  set -e
  assert_ok "nonexistent base commit exits 2" [ "$rc_8e" -eq 2 ]
  assert_ok "nonexistent base prints error" \
    grep -Fq "does not exist as a commit" "$OUTPUT_8E"

  # 8f: Non-ancestor base commit
  WORKDIR_8F="$TMP_TEST_DIR/worktree-8f"
  git clone -q "$WORKDIR_8" "$WORKDIR_8F"
  git -C "$WORKDIR_8F" checkout -q -b task/side-branch
  echo "side" > "$WORKDIR_8F/side.txt"
  git -C "$WORKDIR_8F" add side.txt
  git -C "$WORKDIR_8F" -c user.name="Test" -c user.email="test@test.com" commit -m "side commit" -q
  SIDE_SHA="$(git -C "$WORKDIR_8F" rev-parse HEAD)"
  git -C "$WORKDIR_8F" checkout -q task/feature-8

  clear_logs
  OUTPUT_8F="$TMP_TEST_DIR/output_8f.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-8" \
    HARNESS_TASK_BASE="$SIDE_SHA" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8F" >"$OUTPUT_8F" 2>&1
  rc_8f=$?
  set -e
  assert_ok "non-ancestor base exits 2" [ "$rc_8f" -eq 2 ]
  assert_ok "non-ancestor base prints error" \
    grep -Fq "is not an ancestor of HEAD" "$OUTPUT_8F"

  # 8g: Detached HEAD state
  git -C "$WORKDIR_8" checkout -q --detach HEAD
  clear_logs
  OUTPUT_8G="$TMP_TEST_DIR/output_8g.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-8" \
    HARNESS_TASK_BASE="$BASE_8" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8G" 2>&1
  rc_8g=$?
  set -e
  assert_ok "detached HEAD exits 2" [ "$rc_8g" -eq 2 ]
  assert_ok "detached HEAD prints error" \
    grep -Fq "detached HEAD state is not permitted" "$OUTPUT_8G"
  git -C "$WORKDIR_8" checkout -q task/feature-8

  # 8h: Dirty initial worktree
  echo "dirty untracked" > "$WORKDIR_8/dirty.txt"
  clear_logs
  OUTPUT_8H="$TMP_TEST_DIR/output_8h.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-8" \
    HARNESS_TASK_BASE="$BASE_8" \
    "$RUN_TASK_BIN" "$STEP_DIR_8" "$WORKDIR_8" >"$OUTPUT_8H" 2>&1
  rc_8h=$?
  set -e
  assert_ok "dirty initial state exits 2" [ "$rc_8h" -eq 2 ]
  assert_ok "dirty initial state prints error" \
    grep -Fq "initial git state is not clean" "$OUTPUT_8H"
  rm -f "$WORKDIR_8/dirty.txt"
else
  skip_test "task-commits prerequisites validation" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 9: Task policy supplemental command deny in --settings argv
# -----------------------------------------------------------------------------
echo "==> Scenario 9: Task policy supplemental command deny in --settings argv"

if is_sandbox_marked; then
  TASK_DIR_9="$TMP_TEST_DIR/task-9"
  STEP_DIR_9="$TASK_DIR_9/steps/01-step"
  WORKDIR_9="$TMP_TEST_DIR/worktree-9"
  mkdir -p "$STEP_DIR_9" "$WORKDIR_9"
  echo "# Brief 9" > "$STEP_DIR_9/brief.md"

  git -C "$WORKDIR_9" init -q -b main
  echo "init" > "$WORKDIR_9/init.txt"
  git -C "$WORKDIR_9" add init.txt
  git -C "$WORKDIR_9" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_9="$(git -C "$WORKDIR_9" rev-parse HEAD)"
  git -C "$WORKDIR_9" checkout -q -b task/feature-9

  clear_logs
  MOCK_LOG_DIR="$MOCK_LOG_DIR" PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-9" \
    HARNESS_TASK_BASE="$BASE_9" \
    "$RUN_TASK_BIN" "$STEP_DIR_9" "$WORKDIR_9" >/dev/null 2>&1

  # shellcheck disable=SC2016
  assert_ok "probe argv contains disabled terminal sandbox" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .enableTerminalSandbox == false' "$PROBE_JSONL"

  # shellcheck disable=SC2016
  assert_ok "probe argv contains command deny for git push" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .permissions.deny | any(. == "command(git push)")' "$PROBE_JSONL"

  # shellcheck disable=SC2016
  assert_ok "probe argv contains command deny for git merge" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .permissions.deny | any(. == "command(git merge)")' "$PROBE_JSONL"

  # shellcheck disable=SC2016
  assert_ok "probe argv does NOT blanket deny git commit" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .permissions.deny | any(. == "command(git commit)") | not' "$PROBE_JSONL"

  # shellcheck disable=SC2016
  assert_ok "run argv contains command deny for git push" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .permissions.deny | any(. == "command(git push)")' "$CALLS_JSONL"

  # shellcheck disable=SC2016
  assert_ok "run argv contains command deny for git merge" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .permissions.deny | any(. == "command(git merge)")' "$CALLS_JSONL"

  # shellcheck disable=SC2016
  assert_ok "run argv does NOT blanket deny git commit" \
    jq -e '.argv | index("--settings") as $i | .[$i + 1] | fromjson | .permissions.deny | any(. == "command(git commit)") | not' "$CALLS_JSONL"
else
  skip_test "task policy supplemental command deny" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 10: Task policy prompt rules and exact trailer
# -----------------------------------------------------------------------------
echo "==> Scenario 10: Task policy prompt rules and exact trailer"

if is_sandbox_marked; then
  TASK_DIR_10="$TMP_TEST_DIR/task-10"
  STEP_DIR_10="$TASK_DIR_10/steps/01-step"
  WORKDIR_10="$TMP_TEST_DIR/worktree-10"
  mkdir -p "$STEP_DIR_10" "$WORKDIR_10"
  echo "# Brief 10" > "$STEP_DIR_10/brief.md"

  git -C "$WORKDIR_10" init -q -b main
  echo "init" > "$WORKDIR_10/init.txt"
  git -C "$WORKDIR_10" add init.txt
  git -C "$WORKDIR_10" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_10="$(git -C "$WORKDIR_10" rev-parse HEAD)"
  git -C "$WORKDIR_10" checkout -q -b task/feature-10

  clear_logs
  PATH="$FAKE_BIN_DIR:$PATH" HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-10" \
    HARNESS_TASK_BASE="$BASE_10" \
    "$RUN_TASK_BIN" "$STEP_DIR_10" "$WORKDIR_10" >/dev/null 2>&1

  assert_ok "prompt embeds exact task policy flag" \
    grep -Fq "HARNESS_GIT_POLICY=task-commits" "$STEP_DIR_10/prompt-1.md"

  assert_ok "prompt embeds exact task branch" \
    grep -Fq "task/feature-10" "$STEP_DIR_10/prompt-1.md"

  assert_ok "prompt embeds exact task base" \
    grep -Fq "$BASE_10" "$STEP_DIR_10/prompt-1.md"

  assert_ok "prompt embeds exact Antigravity trailer" \
    grep -Fq "Co-authored-by: Antigravity (Mock Gemini) <noreply@google.com>" "$STEP_DIR_10/prompt-1.md"

  assert_ok "prompt explains checkpoint commits are unreviewed, not accepted submissions" \
    grep -Fq "Checkpoint commits are unreviewed, not accepted submissions" "$STEP_DIR_10/prompt-1.md"

  assert_fail "prompt does NOT assert unconditional no-stage/no-commit rule" \
    grep -Fq "In both modes, role separation is strict: do not commit, stage, or branch" "$STEP_DIR_10/prompt-1.md"
else
  skip_test "task policy prompt rules" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 11: Allowed linear commits with content
# -----------------------------------------------------------------------------
echo "==> Scenario 11: Allowed linear commits with content"

if is_sandbox_marked; then
  TASK_DIR_11="$TMP_TEST_DIR/task-11"
  STEP_DIR_11="$TASK_DIR_11/steps/01-step"
  WORKDIR_11="$TMP_TEST_DIR/worktree-11"
  mkdir -p "$STEP_DIR_11" "$WORKDIR_11"
  echo "# Brief 11" > "$STEP_DIR_11/brief.md"

  git -C "$WORKDIR_11" init -q -b main
  echo "init" > "$WORKDIR_11/init.txt"
  git -C "$WORKDIR_11" add init.txt
  git -C "$WORKDIR_11" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_11="$(git -C "$WORKDIR_11" rev-parse HEAD)"
  git -C "$WORKDIR_11" checkout -q -b task/feature-11

  COMMIT_SCRIPT_11="$TMP_TEST_DIR/commit_script_11.sh"
  cat <<'EOF' > "$COMMIT_SCRIPT_11"
#!/usr/bin/env bash
echo "change 1" > file1.txt
git add file1.txt
git -c user.name="Antigravity" -c user.email="agy@test.com" commit -m "feat: change 1" -q
echo "change 2" > file2.txt
git add file2.txt
git -c user.name="Antigravity" -c user.email="agy@test.com" commit -m "feat: change 2" -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-commit-11","response":"# Report\nDone 2 commits\n"}}
JSON
exit 0
EOF
  chmod +x "$COMMIT_SCRIPT_11"

  clear_logs
  OUTPUT_11="$TMP_TEST_DIR/output_11.log"
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$COMMIT_SCRIPT_11" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-11" \
    HARNESS_TASK_BASE="$BASE_11" \
    "$RUN_TASK_BIN" "$STEP_DIR_11" "$WORKDIR_11" >"$OUTPUT_11" 2>&1
  rc_11=$?

  assert_ok "run with allowed linear commits succeeds (exit 0)" [ "$rc_11" -eq 0 ]
  assert_ok "metrics status is SUCCESS and git_policy_outcome is passed" \
    jq -e '.status == "SUCCESS" and .git_policy == "task-commits" and .git_policy_outcome == "passed" and .git_policy_reason == "linear_commits"' "$TASK_DIR_11/metrics.jsonl"
  assert_ok "metrics records factual git_state_changed=true" \
    jq -e '.git_state_changed == true' "$TASK_DIR_11/metrics.jsonl"
  # shellcheck disable=SC2016
  assert_ok "metrics records start sha and end sha" \
    jq -e --arg start "$BASE_11" '.git_start_sha == $start and .git_end_sha != $start' "$TASK_DIR_11/metrics.jsonl"
  assert_ok "metrics records exactly 2 created commits" \
    jq -e '.git_created_commits | length == 2' "$TASK_DIR_11/metrics.jsonl"
  assert_ok "metrics records clean dirty state" \
    jq -e '.git_dirty == false and .git_dirty_state.dirty == false' "$TASK_DIR_11/metrics.jsonl"
else
  skip_test "allowed linear commits with content" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 12: Clean no-op inspection run
# -----------------------------------------------------------------------------
echo "==> Scenario 12: Clean no-op inspection run"

if is_sandbox_marked; then
  TASK_DIR_12="$TMP_TEST_DIR/task-12"
  STEP_DIR_12="$TASK_DIR_12/steps/01-step"
  WORKDIR_12="$TMP_TEST_DIR/worktree-12"
  mkdir -p "$STEP_DIR_12" "$WORKDIR_12"
  echo "# Brief 12" > "$STEP_DIR_12/brief.md"

  git -C "$WORKDIR_12" init -q -b main
  echo "init" > "$WORKDIR_12/init.txt"
  git -C "$WORKDIR_12" add init.txt
  git -C "$WORKDIR_12" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_12="$(git -C "$WORKDIR_12" rev-parse HEAD)"
  git -C "$WORKDIR_12" checkout -q -b task/feature-12

  clear_logs
  OUTPUT_12="$TMP_TEST_DIR/output_12.log"
  PATH="$FAKE_BIN_DIR:$PATH" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-12" \
    HARNESS_TASK_BASE="$BASE_12" \
    "$RUN_TASK_BIN" "$STEP_DIR_12" "$WORKDIR_12" >"$OUTPUT_12" 2>&1
  rc_12=$?

  assert_ok "clean no-op inspection run succeeds (exit 0)" [ "$rc_12" -eq 0 ]
  assert_ok "no-op records status=SUCCESS and git_policy_reason=clean_noop" \
    jq -e '.status == "SUCCESS" and .git_policy_outcome == "passed" and .git_policy_reason == "clean_noop"' "$TASK_DIR_12/metrics.jsonl"
  assert_ok "no-op records git_state_changed=false and 0 created commits" \
    jq -e '.git_state_changed == false and .git_created_commits == []' "$TASK_DIR_12/metrics.jsonl"
else
  skip_test "clean no-op inspection run" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 13: task-commits violations rejected with GIT_STATE_MUTATED
# -----------------------------------------------------------------------------
echo "==> Scenario 13: task-commits violations rejected with GIT_STATE_MUTATED"

if is_sandbox_marked; then
  setup_fixture_13() {
    local target="$1"
    mkdir -p "$target"
    git -C "$target" init -q -b main
    echo "init" > "$target/init.txt"
    git -C "$target" add init.txt
    git -C "$target" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
    git -C "$target" -c user.name="Test" -c user.email="test@test.com" tag -a v1.0.0 -m "release 1.0.0"
    git -C "$target" checkout -q -b task/feature-13
  }

  # 13a: Branch switch
  WORKDIR_13A="$TMP_TEST_DIR/worktree-13a"
  setup_fixture_13 "$WORKDIR_13A"
  BASE_13A="$(git -C "$WORKDIR_13A" rev-parse HEAD)"
  STEP_DIR_13A="$TMP_TEST_DIR/task-13a/steps/01-step"
  mkdir -p "$STEP_DIR_13A"
  echo "# Brief 13A" > "$STEP_DIR_13A/brief.md"

  MUTATE_SCRIPT_13A="$TMP_TEST_DIR/mutate_13a.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13A"
#!/usr/bin/env bash
git checkout -b unauthorized-branch -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13a","response":"# Report\nSwitched branch\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13A"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13A" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13A" \
    "$RUN_TASK_BIN" "$STEP_DIR_13A" "$WORKDIR_13A" >/dev/null 2>&1
  rc_13a=$?
  set -e
  assert_ok "branch switch rejected (exit non-zero 1)" [ "$rc_13a" -eq 1 ]
  assert_ok "branch switch sets GIT_STATE_MUTATED and rejected outcome" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("branch_changed"))' "$TMP_TEST_DIR/task-13a/metrics.jsonl"

  # 13b: Protected ref modification (updating main)
  WORKDIR_13B="$TMP_TEST_DIR/worktree-13b"
  setup_fixture_13 "$WORKDIR_13B"
  BASE_13B="$(git -C "$WORKDIR_13B" rev-parse HEAD)"
  STEP_DIR_13B="$TMP_TEST_DIR/task-13b/steps/01-step"
  mkdir -p "$STEP_DIR_13B"
  echo "# Brief 13B" > "$STEP_DIR_13B/brief.md"

  MUTATE_SCRIPT_13B="$TMP_TEST_DIR/mutate_13b.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13B"
#!/usr/bin/env bash
echo "content" > f.txt
git add f.txt
git -c user.name="Agy" -c user.email="a@test.com" commit -m "commit on feature" -q
git branch -f main HEAD -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13b","response":"# Report\nMod main\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13B"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13B" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13B" \
    "$RUN_TASK_BIN" "$STEP_DIR_13B" "$WORKDIR_13B" >/dev/null 2>&1
  rc_13b=$?
  set -e
  assert_ok "protected ref modification rejected (exit 1)" [ "$rc_13b" -eq 1 ]
  assert_ok "protected ref modification sets GIT_STATE_MUTATED and rejected outcome" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("protected_ref_modified"))' "$TMP_TEST_DIR/task-13b/metrics.jsonl"

  # 13c: Protected ref deletion (deleting tag)
  WORKDIR_13C="$TMP_TEST_DIR/worktree-13c"
  setup_fixture_13 "$WORKDIR_13C"
  BASE_13C="$(git -C "$WORKDIR_13C" rev-parse HEAD)"
  STEP_DIR_13C="$TMP_TEST_DIR/task-13c/steps/01-step"
  mkdir -p "$STEP_DIR_13C"
  echo "# Brief 13C" > "$STEP_DIR_13C/brief.md"

  MUTATE_SCRIPT_13C="$TMP_TEST_DIR/mutate_13c.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13C"
#!/usr/bin/env bash
git tag -d v1.0.0
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13c","response":"# Report\nDeleted tag\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13C"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13C" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13C" \
    "$RUN_TASK_BIN" "$STEP_DIR_13C" "$WORKDIR_13C" >/dev/null 2>&1
  rc_13c=$?
  set -e
  assert_ok "protected ref deletion rejected (exit 1)" [ "$rc_13c" -eq 1 ]
  assert_ok "protected ref deletion sets GIT_STATE_MUTATED and rejected outcome" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("protected_ref_deleted"))' "$TMP_TEST_DIR/task-13c/metrics.jsonl"

  # 13d: Protected ref created (new tag)
  WORKDIR_13D="$TMP_TEST_DIR/worktree-13d"
  setup_fixture_13 "$WORKDIR_13D"
  BASE_13D="$(git -C "$WORKDIR_13D" rev-parse HEAD)"
  STEP_DIR_13D="$TMP_TEST_DIR/task-13d/steps/01-step"
  mkdir -p "$STEP_DIR_13D"
  echo "# Brief 13D" > "$STEP_DIR_13D/brief.md"

  MUTATE_SCRIPT_13D="$TMP_TEST_DIR/mutate_13d.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13D"
#!/usr/bin/env bash
git tag v2.0.0
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13d","response":"# Report\nCreated tag\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13D"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13D" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13D" \
    "$RUN_TASK_BIN" "$STEP_DIR_13D" "$WORKDIR_13D" >/dev/null 2>&1
  rc_13d=$?
  set -e
  assert_ok "protected ref creation rejected (exit 1)" [ "$rc_13d" -eq 1 ]
  assert_ok "protected ref creation sets GIT_STATE_MUTATED and rejected outcome" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("protected_ref_created"))' "$TMP_TEST_DIR/task-13d/metrics.jsonl"

  # 13e: Rewind / non-descendant HEAD
  WORKDIR_13E="$TMP_TEST_DIR/worktree-13e"
  setup_fixture_13 "$WORKDIR_13E"
  echo "pre-commit" > "$WORKDIR_13E/pre.txt"
  git -C "$WORKDIR_13E" add pre.txt
  git -C "$WORKDIR_13E" -c user.name="Test" -c user.email="test@test.com" commit -m "pre commit" -q
  BASE_13E="$(git -C "$WORKDIR_13E" rev-parse HEAD~1)"
  STEP_DIR_13E="$TMP_TEST_DIR/task-13e/steps/01-step"
  mkdir -p "$STEP_DIR_13E"
  echo "# Brief 13E" > "$STEP_DIR_13E/brief.md"

  MUTATE_SCRIPT_13E="$TMP_TEST_DIR/mutate_13e.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13E"
#!/usr/bin/env bash
git reset --hard HEAD~1 -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13e","response":"# Report\nRewound HEAD\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13E"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13E" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13E" \
    "$RUN_TASK_BIN" "$STEP_DIR_13E" "$WORKDIR_13E" >/dev/null 2>&1
  rc_13e=$?
  set -e
  assert_ok "rewound HEAD rejected (exit 1)" [ "$rc_13e" -eq 1 ]
  assert_ok "rewound HEAD sets GIT_STATE_MUTATED and non_descendant_head" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and .git_policy_reason == "non_descendant_head"' "$TMP_TEST_DIR/task-13e/metrics.jsonl"

  # 13f: Merge commit
  WORKDIR_13F="$TMP_TEST_DIR/worktree-13f"
  setup_fixture_13 "$WORKDIR_13F"
  BASE_13F="$(git -C "$WORKDIR_13F" rev-parse HEAD)"
  git -C "$WORKDIR_13F" checkout -q -b side-branch-13f
  echo "side content" > "$WORKDIR_13F/side.txt"
  git -C "$WORKDIR_13F" add side.txt
  git -C "$WORKDIR_13F" -c user.name="Test" -c user.email="test@test.com" commit -m "side branch commit" -q
  git -C "$WORKDIR_13F" checkout -q task/feature-13
  STEP_DIR_13F="$TMP_TEST_DIR/task-13f/steps/01-step"
  mkdir -p "$STEP_DIR_13F"
  echo "# Brief 13F" > "$STEP_DIR_13F/brief.md"

  MUTATE_SCRIPT_13F="$TMP_TEST_DIR/mutate_13f.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13F"
#!/usr/bin/env bash
git -c user.name="Agy" -c user.email="a@test.com" merge side-branch-13f --no-ff -m "merge commit" -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13f","response":"# Report\nMerged branch\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13F"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13F" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13F" \
    "$RUN_TASK_BIN" "$STEP_DIR_13F" "$WORKDIR_13F" >/dev/null 2>&1
  rc_13f=$?
  set -e
  assert_ok "merge commit rejected (exit 1)" [ "$rc_13f" -eq 1 ]
  assert_ok "merge commit sets GIT_STATE_MUTATED and merge_commit_detected" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("merge_commit_detected"))' "$TMP_TEST_DIR/task-13f/metrics.jsonl"

  # 13g: Staged changes uncommitted on SUCCESS
  WORKDIR_13G="$TMP_TEST_DIR/worktree-13g"
  setup_fixture_13 "$WORKDIR_13G"
  BASE_13G="$(git -C "$WORKDIR_13G" rev-parse HEAD)"
  STEP_DIR_13G="$TMP_TEST_DIR/task-13g/steps/01-step"
  mkdir -p "$STEP_DIR_13G"
  echo "# Brief 13G" > "$STEP_DIR_13G/brief.md"

  MUTATE_SCRIPT_13G="$TMP_TEST_DIR/mutate_13g.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13G"
#!/usr/bin/env bash
echo "staged" > staged_file.txt
git add staged_file.txt
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13g","response":"# Report\nStaged but not committed\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13G"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13G" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13G" \
    "$RUN_TASK_BIN" "$STEP_DIR_13G" "$WORKDIR_13G" >/dev/null 2>&1
  rc_13g=$?
  set -e
  assert_ok "uncommitted staged changes rejected (exit 1)" [ "$rc_13g" -eq 1 ]
  assert_ok "uncommitted staged changes sets staged_changes_uncommitted" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and .git_policy_reason == "staged_changes_uncommitted"' "$TMP_TEST_DIR/task-13g/metrics.jsonl"

  # 13h: Untracked dirty files on SUCCESS
  WORKDIR_13H="$TMP_TEST_DIR/worktree-13h"
  setup_fixture_13 "$WORKDIR_13H"
  BASE_13H="$(git -C "$WORKDIR_13H" rev-parse HEAD)"
  STEP_DIR_13H="$TMP_TEST_DIR/task-13h/steps/01-step"
  mkdir -p "$STEP_DIR_13H"
  echo "# Brief 13H" > "$STEP_DIR_13H/brief.md"

  MUTATE_SCRIPT_13H="$TMP_TEST_DIR/mutate_13h.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13H"
#!/usr/bin/env bash
echo "committed" > committed.txt
git add committed.txt
git -c user.name="Agy" -c user.email="a@test.com" commit -m "feat: committed" -q
echo "untracked" > untracked.txt
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13h","response":"# Report\nUntracked left behind\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13H"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13H" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13H" \
    "$RUN_TASK_BIN" "$STEP_DIR_13H" "$WORKDIR_13H" >/dev/null 2>&1
  rc_13h=$?
  set -e
  assert_ok "untracked dirty files on SUCCESS rejected (exit 1)" [ "$rc_13h" -eq 1 ]
  assert_ok "untracked dirty files sets dirty_worktree" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and .git_policy_reason == "dirty_worktree"' "$TMP_TEST_DIR/task-13h/metrics.jsonl"

  # 13i: Missing snapshot rejection (mock deletes snapshot)
  WORKDIR_13I="$TMP_TEST_DIR/worktree-13i"
  setup_fixture_13 "$WORKDIR_13I"
  BASE_13I="$(git -C "$WORKDIR_13I" rev-parse HEAD)"
  STEP_DIR_13I="$TMP_TEST_DIR/task-13i/steps/01-step"
  mkdir -p "$STEP_DIR_13I"
  echo "# Brief 13I" > "$STEP_DIR_13I/brief.md"

  MUTATE_SCRIPT_13I="$TMP_TEST_DIR/mutate_13i.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13I"
#!/usr/bin/env bash
rm -f /tmp/harness-git-snapshot.* "${TMPDIR:-/tmp}"/harness-git-snapshot.* 2>/dev/null || true
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13i","response":"# Report\nDeleted snapshot\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13I"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13I" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13I" \
    "$RUN_TASK_BIN" "$STEP_DIR_13I" "$WORKDIR_13I" >/dev/null 2>&1
  rc_13i=$?
  set -e
  assert_ok "missing initial snapshot rejected (exit 1)" [ "$rc_13i" -eq 1 ]
  assert_ok "missing initial snapshot sets GIT_STATE_MUTATED and missing_initial_snapshot" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and .git_policy_reason == "missing_initial_snapshot"' "$TMP_TEST_DIR/task-13i/metrics.jsonl"

  # 13j: Malformed snapshot rejection
  WORKDIR_13J="$TMP_TEST_DIR/worktree-13j"
  setup_fixture_13 "$WORKDIR_13J"
  BASE_13J="$(git -C "$WORKDIR_13J" rev-parse HEAD)"
  STEP_DIR_13J="$TMP_TEST_DIR/task-13j/steps/01-step"
  mkdir -p "$STEP_DIR_13J"
  echo "# Brief 13J" > "$STEP_DIR_13J/brief.md"

  MUTATE_SCRIPT_13J="$TMP_TEST_DIR/mutate_13j.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13J"
#!/usr/bin/env bash
for f in /tmp/harness-git-snapshot.* "${TMPDIR:-/tmp}"/harness-git-snapshot.*; do
  [ -f "$f" ] && echo "broken-json" > "$f"
done
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13j","response":"# Report\nCorrupted snapshot\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13J"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13J" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13J" \
    "$RUN_TASK_BIN" "$STEP_DIR_13J" "$WORKDIR_13J" >/dev/null 2>&1
  rc_13j=$?
  set -e
  assert_ok "malformed initial snapshot rejected (exit 1)" [ "$rc_13j" -eq 1 ]
  assert_ok "malformed initial snapshot sets GIT_STATE_MUTATED and malformed_initial_snapshot" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("malformed_initial_snapshot"))' "$TMP_TEST_DIR/task-13j/metrics.jsonl"

  # 13k: Git command read failure during post-check fails closed
  WORKDIR_13K="$TMP_TEST_DIR/worktree-13k"
  setup_fixture_13 "$WORKDIR_13K"
  BASE_13K="$(git -C "$WORKDIR_13K" rev-parse HEAD)"
  STEP_DIR_13K="$TMP_TEST_DIR/task-13k/steps/01-step"
  mkdir -p "$STEP_DIR_13K"
  echo "# Brief 13K" > "$STEP_DIR_13K/brief.md"

  MUTATE_SCRIPT_13K="$TMP_TEST_DIR/mutate_13k.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13K"
#!/usr/bin/env bash
chmod 000 "$PWD/.git/refs" "$PWD/.git/refs/heads" 2>/dev/null || true
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13k","response":"# Report\nInaccessible refs\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13K"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13K" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13K" \
    "$RUN_TASK_BIN" "$STEP_DIR_13K" "$WORKDIR_13K" >/dev/null 2>&1
  rc_13k=$?
  set -e
  chmod 755 "$WORKDIR_13K/.git/refs" "$WORKDIR_13K/.git/refs/heads" 2>/dev/null || true
  assert_ok "git read error during post-check rejected (exit 1)" [ "$rc_13k" -eq 1 ]
  assert_ok "git read error sets GIT_STATE_MUTATED and git_read_failed" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("git_read_failed"))' "$TMP_TEST_DIR/task-13k/metrics.jsonl"

  # 13l: Rejection preserves actual observables in metrics (not clean defaults)
  WORKDIR_13L="$TMP_TEST_DIR/worktree-13l"
  setup_fixture_13 "$WORKDIR_13L"
  BASE_13L="$(git -C "$WORKDIR_13L" rev-parse HEAD)"
  STEP_DIR_13L="$TMP_TEST_DIR/task-13l/steps/01-step"
  mkdir -p "$STEP_DIR_13L"
  echo "# Brief 13L" > "$STEP_DIR_13L/brief.md"

  MUTATE_SCRIPT_13L="$TMP_TEST_DIR/mutate_13l.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13L"
#!/usr/bin/env bash
echo "change" > new_file.txt
git add new_file.txt
git -c user.name="Agy" -c user.email="a@test.com" commit -m "feat: valid commit on feature" -q
echo "wip" > dirty_extra.txt
git checkout -b other-branch -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13l","response":"# Report\nBranch changed with commit and dirty\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13L"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13L" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13L" \
    "$RUN_TASK_BIN" "$STEP_DIR_13L" "$WORKDIR_13L" >/dev/null 2>&1
  rc_13l=$?
  set -e
  assert_ok "rejection run in 13l exits non-zero (exit 1)" [ "$rc_13l" -eq 1 ]
  assert_ok "rejection preserves actual git_created_commits and dirty state" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_created_commits | length == 1) and .git_dirty == true and .git_dirty_state.untracked == true' "$TMP_TEST_DIR/task-13l/metrics.jsonl"

  # 13m: rev-list --reverse failure during post-check created_commits collection fails closed
  WORKDIR_13M="$TMP_TEST_DIR/worktree-13m"
  setup_fixture_13 "$WORKDIR_13M"
  BASE_13M="$(git -C "$WORKDIR_13M" rev-parse HEAD)"
  STEP_DIR_13M="$TMP_TEST_DIR/task-13m/steps/01-step"
  mkdir -p "$STEP_DIR_13M"
  echo "# Brief 13M" > "$STEP_DIR_13M/brief.md"

  WRAP_DIR_13M="$TMP_TEST_DIR/wrap_13m"
  mkdir -p "$WRAP_DIR_13M"
  cat <<'EOF' > "$WRAP_DIR_13M/git"
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "--reverse" ]; then
    echo "fatal: simulated rev-list failure" >&2
    exit 128
  fi
done
exec /usr/bin/git "$@"
EOF
  chmod +x "$WRAP_DIR_13M/git"

  MUTATE_SCRIPT_13M="$TMP_TEST_DIR/mutate_13m.sh"
  cat <<'EOF' > "$MUTATE_SCRIPT_13M"
#!/usr/bin/env bash
echo "change" > new_file.txt
/usr/bin/git add new_file.txt
/usr/bin/git -c user.name="Agy" -c user.email="a@test.com" commit -m "feat: valid commit" -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c13m","response":"# Report\nCommit created\n"}}
JSON
exit 0
EOF
  chmod +x "$MUTATE_SCRIPT_13M"

  clear_logs
  set +e
  PATH="$WRAP_DIR_13M:$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$MUTATE_SCRIPT_13M" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-13" \
    HARNESS_TASK_BASE="$BASE_13M" \
    "$RUN_TASK_BIN" "$STEP_DIR_13M" "$WORKDIR_13M" >/dev/null 2>&1
  rc_13m=$?
  set -e

  assert_ok "rev-list read error during post-check rejected (exit 1)" [ "$rc_13m" -eq 1 ]
  assert_ok "rev-list read error sets GIT_STATE_MUTATED and git_read_failed" \
    jq -e '.status == "GIT_STATE_MUTATED" and .git_policy_outcome == "rejected" and (.git_policy_reason | test("git_read_failed.*rev-list.*reverse"))' "$TMP_TEST_DIR/task-13m/metrics.jsonl"
else
  skip_test "task-commits violations rejected" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 14: Failed run preserves dirty changes
# -----------------------------------------------------------------------------
echo "==> Scenario 14: Failed run preserves dirty changes"

if is_sandbox_marked; then
  TASK_DIR_14="$TMP_TEST_DIR/task-14"
  STEP_DIR_14="$TASK_DIR_14/steps/01-step"
  WORKDIR_14="$TMP_TEST_DIR/worktree-14"
  mkdir -p "$STEP_DIR_14" "$WORKDIR_14"
  echo "# Brief 14" > "$STEP_DIR_14/brief.md"

  git -C "$WORKDIR_14" init -q -b main
  echo "init" > "$WORKDIR_14/init.txt"
  git -C "$WORKDIR_14" add init.txt
  git -C "$WORKDIR_14" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_14="$(git -C "$WORKDIR_14" rev-parse HEAD)"
  git -C "$WORKDIR_14" checkout -q -b task/feature-14

  FAIL_SCRIPT_14="$TMP_TEST_DIR/fail_script_14.sh"
  cat <<'EOF' > "$FAIL_SCRIPT_14"
#!/usr/bin/env bash
echo "checkpoint before failure" > checkpoint.txt
git add checkpoint.txt
git -c user.name="Agy" -c user.email="a@test.com" commit -m "feat: checkpoint" -q
echo "in-progress dirty work" > dirty_wip.txt
cat <<JSON
{"event":"result","result":{"status":"ERROR","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c14","response":"# Report\nFailed\n"}}
JSON
exit 1
EOF
  chmod +x "$FAIL_SCRIPT_14"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$FAIL_SCRIPT_14" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-14" \
    HARNESS_TASK_BASE="$BASE_14" \
    "$RUN_TASK_BIN" "$STEP_DIR_14" "$WORKDIR_14" >/dev/null 2>&1
  rc_14=$?
  set -e

  assert_ok "failed run exits non-zero (1)" [ "$rc_14" -ne 0 ]
  assert_ok "failed run preserves status=ERROR in metrics (not overridden to GIT_STATE_MUTATED)" \
    jq -e '.status == "ERROR" and .git_policy_outcome == "passed"' "$TASK_DIR_14/metrics.jsonl"
  assert_ok "failed run records dirty state in metrics" \
    jq -e '.git_dirty == true and .git_dirty_state.untracked == true' "$TASK_DIR_14/metrics.jsonl"
  git -C "$WORKDIR_14" log -1 --pretty=%B > "$TMP_TEST_DIR/log14.txt"
  assert_ok "checkpoint commit was preserved in git" \
    grep -Fq "feat: checkpoint" "$TMP_TEST_DIR/log14.txt"
  assert_ok "dirty wip file was preserved (never reset)" \
    test -f "$WORKDIR_14/dirty_wip.txt"

  # 14b: Failed run with unstaged tracked edit preserves work without misclassifying as staged
  TASK_DIR_14B="$TMP_TEST_DIR/task-14b"
  STEP_DIR_14B="$TASK_DIR_14B/steps/01-step"
  WORKDIR_14B="$TMP_TEST_DIR/worktree-14b"
  mkdir -p "$STEP_DIR_14B" "$WORKDIR_14B"
  echo "# Brief 14B" > "$STEP_DIR_14B/brief.md"

  git -C "$WORKDIR_14B" init -q -b main
  echo "init" > "$WORKDIR_14B/init.txt"
  git -C "$WORKDIR_14B" add init.txt
  git -C "$WORKDIR_14B" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_14B="$(git -C "$WORKDIR_14B" rev-parse HEAD)"
  git -C "$WORKDIR_14B" checkout -q -b task/feature-14b

  FAIL_SCRIPT_14B="$TMP_TEST_DIR/fail_script_14b.sh"
  cat <<'EOF' > "$FAIL_SCRIPT_14B"
#!/usr/bin/env bash
echo "unstaged modification" >> init.txt
cat <<JSON
{"event":"result","result":{"status":"ERROR","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"c14b","response":"# Report\nFailed with unstaged edit\n"}}
JSON
exit 1
EOF
  chmod +x "$FAIL_SCRIPT_14B"

  clear_logs
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$FAIL_SCRIPT_14B" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-14b" \
    HARNESS_TASK_BASE="$BASE_14B" \
    "$RUN_TASK_BIN" "$STEP_DIR_14B" "$WORKDIR_14B" >/dev/null 2>&1
  rc_14b=$?
  set -e

  assert_ok "failed run with unstaged tracked edit exits non-zero (1)" [ "$rc_14b" -ne 0 ]
  assert_ok "unstaged edit preserves status=ERROR in metrics" \
    jq -e '.status == "ERROR" and .git_policy_outcome == "passed" and .git_policy_reason == "dirty_preserved"' "$TASK_DIR_14B/metrics.jsonl"
  assert_ok "unstaged edit records tracked=true and staged=false" \
    jq -e '.git_dirty == true and .git_dirty_state.tracked == true and .git_dirty_state.staged == false' "$TASK_DIR_14B/metrics.jsonl"
  assert_ok "unstaged tracked edit is preserved on disk" \
    grep -Fq "unstaged modification" "$WORKDIR_14B/init.txt"
else
  skip_test "failed run preserves dirty changes" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 15: Interruption preserves changes and checks policy
# -----------------------------------------------------------------------------
echo "==> Scenario 15: Interruption preserves changes and checks policy"

if is_sandbox_marked; then
  TASK_DIR_15="$TMP_TEST_DIR/task-15"
  STEP_DIR_15="$TASK_DIR_15/steps/01-step"
  WORKDIR_15="$TMP_TEST_DIR/worktree-15"
  mkdir -p "$STEP_DIR_15" "$WORKDIR_15"
  echo "# Brief 15" > "$STEP_DIR_15/brief.md"

  git -C "$WORKDIR_15" init -q -b main
  echo "init" > "$WORKDIR_15/init.txt"
  git -C "$WORKDIR_15" add init.txt
  git -C "$WORKDIR_15" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_15="$(git -C "$WORKDIR_15" rev-parse HEAD)"
  git -C "$WORKDIR_15" checkout -q -b task/feature-15

  SLEEP_SCRIPT_15="$TMP_TEST_DIR/sleep_script_15.sh"
  READY_FILE_15="$TMP_TEST_DIR/ready_15"
  rm -f "$READY_FILE_15"
  cat <<EOF > "$SLEEP_SCRIPT_15"
#!/usr/bin/env bash
echo "interrupted wip" > wip_file.txt
touch "$READY_FILE_15"
sleep 5
exit 0
EOF
  chmod +x "$SLEEP_SCRIPT_15"

  clear_logs
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$SLEEP_SCRIPT_15" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-15" \
    HARNESS_TASK_BASE="$BASE_15" \
    "$RUN_TASK_BIN" "$STEP_DIR_15" "$WORKDIR_15" >/dev/null 2>&1 &
  RUNNER_PID_15=$!

  waited=0
  while [ ! -f "$READY_FILE_15" ] && [ "$waited" -lt 50 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done

  kill -TERM "$RUNNER_PID_15" 2>/dev/null || true
  set +e
  wait "$RUNNER_PID_15" 2>/dev/null
  rc_15=$?
  set -e

  assert_ok "runner exited with 143 on TERM" [ "$rc_15" -eq 143 ]
  assert_ok "metrics recorded status=INTERRUPTED" \
    jq -e '.status == "INTERRUPTED" and .exit_code == 143 and .git_policy == "task-commits"' "$TASK_DIR_15/metrics.jsonl"
  assert_ok "interrupted dirty work was preserved" \
    test -f "$WORKDIR_15/wip_file.txt"

  # 15b: Interrupted run with unstaged tracked edit
  TASK_DIR_15B="$TMP_TEST_DIR/task-15b"
  STEP_DIR_15B="$TASK_DIR_15B/steps/01-step"
  WORKDIR_15B="$TMP_TEST_DIR/worktree-15b"
  mkdir -p "$STEP_DIR_15B" "$WORKDIR_15B"
  echo "# Brief 15B" > "$STEP_DIR_15B/brief.md"

  git -C "$WORKDIR_15B" init -q -b main
  echo "init" > "$WORKDIR_15B/init.txt"
  git -C "$WORKDIR_15B" add init.txt
  git -C "$WORKDIR_15B" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_15B="$(git -C "$WORKDIR_15B" rev-parse HEAD)"
  git -C "$WORKDIR_15B" checkout -q -b task/feature-15b

  SLEEP_SCRIPT_15B="$TMP_TEST_DIR/sleep_script_15b.sh"
  READY_FILE_15B="$TMP_TEST_DIR/ready_15b"
  rm -f "$READY_FILE_15B"
  cat <<EOF > "$SLEEP_SCRIPT_15B"
#!/usr/bin/env bash
echo "interrupted unstaged edit" >> init.txt
touch "$READY_FILE_15B"
sleep 5
exit 0
EOF
  chmod +x "$SLEEP_SCRIPT_15B"

  clear_logs
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$SLEEP_SCRIPT_15B" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-15b" \
    HARNESS_TASK_BASE="$BASE_15B" \
    "$RUN_TASK_BIN" "$STEP_DIR_15B" "$WORKDIR_15B" >/dev/null 2>&1 &
  RUNNER_PID_15B=$!

  waited=0
  while [ ! -f "$READY_FILE_15B" ] && [ "$waited" -lt 50 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done

  kill -TERM "$RUNNER_PID_15B" 2>/dev/null || true
  set +e
  wait "$RUNNER_PID_15B" 2>/dev/null
  rc_15b=$?
  set -e

  assert_ok "runner exited with 143 on TERM for unstaged edit" [ "$rc_15b" -eq 143 ]
  assert_ok "interrupted unstaged edit records INTERRUPTED and dirty_preserved" \
    jq -e '.status == "INTERRUPTED" and .exit_code == 143 and .git_policy_outcome == "passed" and .git_policy_reason == "dirty_preserved"' "$TASK_DIR_15B/metrics.jsonl"
  assert_ok "interrupted unstaged edit records tracked=true and staged=false" \
    jq -e '.git_dirty == true and .git_dirty_state.tracked == true and .git_dirty_state.staged == false' "$TASK_DIR_15B/metrics.jsonl"
  assert_ok "interrupted unstaged edit is preserved on disk" \
    grep -Fq "interrupted unstaged edit" "$WORKDIR_15B/init.txt"
else
  skip_test "interruption preserves changes" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 16: Resume metrics remain coherent across attempts
# -----------------------------------------------------------------------------
echo "==> Scenario 16: Resume metrics remain coherent across attempts"

if is_sandbox_marked; then
  TASK_DIR_16="$TMP_TEST_DIR/task-16"
  STEP_DIR_16="$TASK_DIR_16/steps/01-step"
  WORKDIR_16="$TMP_TEST_DIR/worktree-16"
  mkdir -p "$STEP_DIR_16" "$WORKDIR_16"
  echo "# Brief 16" > "$STEP_DIR_16/brief.md"

  git -C "$WORKDIR_16" init -q -b main
  echo "init" > "$WORKDIR_16/init.txt"
  git -C "$WORKDIR_16" add init.txt
  git -C "$WORKDIR_16" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_16="$(git -C "$WORKDIR_16" rev-parse HEAD)"
  git -C "$WORKDIR_16" checkout -q -b task/feature-16

  RESUME_SCRIPT_16A="$TMP_TEST_DIR/resume_16a.sh"
  cat <<'EOF' > "$RESUME_SCRIPT_16A"
#!/usr/bin/env bash
echo "step 1" > step1.txt
git add step1.txt
git -c user.name="Agy" -c user.email="a@test.com" commit -m "feat: step 1 commit" -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"conversation_id":"conv-resume-16","response":"# Report\nStep 1 done\n"}}
JSON
exit 0
EOF
  chmod +x "$RESUME_SCRIPT_16A"

  clear_logs
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$RESUME_SCRIPT_16A" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-16" \
    HARNESS_TASK_BASE="$BASE_16" \
    "$RUN_TASK_BIN" "$STEP_DIR_16" "$WORKDIR_16" >/dev/null 2>&1

  assert_ok "attempt 1 completed with SUCCESS" \
    jq -e '.attempt == 1 and .status == "SUCCESS" and .git_policy_outcome == "passed"' "$TASK_DIR_16/metrics.jsonl"

  RESUME_SCRIPT_16B="$TMP_TEST_DIR/resume_16b.sh"
  cat <<'EOF' > "$RESUME_SCRIPT_16B"
#!/usr/bin/env bash
echo "step 2" > step2.txt
git add step2.txt
git -c user.name="Agy" -c user.email="a@test.com" commit -m "feat: step 2 commit" -q
cat <<JSON
{"event":"result","result":{"status":"SUCCESS","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":20,"output_tokens":10},"conversation_id":"conv-resume-16","response":"# Report\nStep 2 done\n"}}
JSON
exit 0
EOF
  chmod +x "$RESUME_SCRIPT_16B"

  clear_logs
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_RUN_SCRIPT="$RESUME_SCRIPT_16B" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-16" \
    HARNESS_TASK_BASE="$BASE_16" \
    "$RUN_TASK_BIN" "$STEP_DIR_16" "$WORKDIR_16" --resume-attempt 1 >/dev/null 2>&1

  assert_ok "attempt 2 (resume) completed with SUCCESS" \
    jq -e '.attempt == 2 and .status == "SUCCESS" and .mode == "resume" and .source_attempt == 1' "$TASK_DIR_16/metrics.jsonl"
  assert_ok "attempt 2 recorded linear commit outcome and trailer" \
    jq -e '.attempt == 2 and .git_policy == "task-commits" and .git_policy_outcome == "passed"' "$TASK_DIR_16/metrics.jsonl"
else
  skip_test "resume metrics remain coherent" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
# Scenario 17: Probe-phase policy audit, interruption, and mutation detection
# -----------------------------------------------------------------------------
echo "==> Scenario 17: Probe-phase policy audit, interruption, and mutation detection"

if is_sandbox_marked; then
  # 17a: Clean probe failure creates probe audit without normal attempt
  TASK_DIR_17A="$TMP_TEST_DIR/task-17a"
  STEP_DIR_17A="$TASK_DIR_17A/steps/01-step"
  WORKDIR_17A="$TMP_TEST_DIR/worktree-17a"
  mkdir -p "$STEP_DIR_17A" "$WORKDIR_17A"
  echo "# Brief 17A" > "$STEP_DIR_17A/brief.md"

  git -C "$WORKDIR_17A" init -q -b main
  echo "init" > "$WORKDIR_17A/init.txt"
  git -C "$WORKDIR_17A" add init.txt
  git -C "$WORKDIR_17A" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_17A="$(git -C "$WORKDIR_17A" rev-parse HEAD)"
  git -C "$WORKDIR_17A" checkout -q -b task/feature-17a

  clear_logs
  OUTPUT_17A="$TMP_TEST_DIR/output_17a.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_PROBE_EMPTY=1 \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-17a" \
    HARNESS_TASK_BASE="$BASE_17A" \
    "$RUN_TASK_BIN" "$STEP_DIR_17A" "$WORKDIR_17A" >"$OUTPUT_17A" 2>&1
  rc_17a=$?
  set -e

  assert_ok "empty probe in docker mode exits 2" [ "$rc_17a" -eq 2 ]
  assert_ok "empty probe does not write metrics.jsonl" [ ! -f "$TASK_DIR_17A/metrics.jsonl" ]
  assert_ok "empty probe does not allocate normal attempts" \
    test ! -f "$STEP_DIR_17A/prompt-1.md" -a ! -f "$STEP_DIR_17A/run-1.jsonl" -a ! -f "$STEP_DIR_17A/report-1.md"
  assert_ok "empty probe writes durable probe-audit.jsonl" [ -s "$TASK_DIR_17A/probe-audit.jsonl" ]
  assert_ok "probe audit records phase=model_probe and status=MODEL_PROBE_FAILED" \
    jq -e '.phase == "model_probe" and .status == "MODEL_PROBE_FAILED" and .git_policy_outcome == "passed" and .git_state_changed == false' "$TASK_DIR_17A/probe-audit.jsonl"

  # 17b: Mutated probe failure rejects and exits 1
  TASK_DIR_17B="$TMP_TEST_DIR/task-17b"
  STEP_DIR_17B="$TASK_DIR_17B/steps/01-step"
  WORKDIR_17B="$TMP_TEST_DIR/worktree-17b"
  mkdir -p "$STEP_DIR_17B" "$WORKDIR_17B"
  echo "# Brief 17B" > "$STEP_DIR_17B/brief.md"

  git -C "$WORKDIR_17B" init -q -b main
  echo "init" > "$WORKDIR_17B/init.txt"
  git -C "$WORKDIR_17B" add init.txt
  git -C "$WORKDIR_17B" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_17B="$(git -C "$WORKDIR_17B" rev-parse HEAD)"
  git -C "$WORKDIR_17B" checkout -q -b task/feature-17b

  MUTATE_PROBE_SCRIPT="$TMP_TEST_DIR/mutate_probe.sh"
  cat <<'EOF' > "$MUTATE_PROBE_SCRIPT"
#!/usr/bin/env bash
echo "probe unauthorized mutation" >> init.txt
exit 1
EOF
  chmod +x "$MUTATE_PROBE_SCRIPT"

  clear_logs
  OUTPUT_17B="$TMP_TEST_DIR/output_17b.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_PROBE_SCRIPT="$MUTATE_PROBE_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-17b" \
    HARNESS_TASK_BASE="$BASE_17B" \
    "$RUN_TASK_BIN" "$STEP_DIR_17B" "$WORKDIR_17B" >"$OUTPUT_17B" 2>&1
  rc_17b=$?
  set -e

  assert_ok "mutated probe rejects and exits 1" [ "$rc_17b" -eq 1 ]
  assert_ok "mutated probe prints git state changed error" \
    grep -Fq "error: git state changed during model probe" "$OUTPUT_17B"
  assert_ok "mutated probe records git_state_changed=true in probe-audit.jsonl" \
    jq -e '.phase == "model_probe" and .git_state_changed == true' "$TASK_DIR_17B/probe-audit.jsonl"
  assert_ok "mutated probe records honest exit_code=1 in probe-audit.jsonl" \
    jq -e '.phase == "model_probe" and .exit_code == 1' "$TASK_DIR_17B/probe-audit.jsonl"

  # 17c: Interrupted probe terminates probe processes and records probe audit
  TASK_DIR_17C="$TMP_TEST_DIR/task-17c"
  STEP_DIR_17C="$TASK_DIR_17C/steps/01-step"
  WORKDIR_17C="$TMP_TEST_DIR/worktree-17c"
  mkdir -p "$STEP_DIR_17C" "$WORKDIR_17C"
  echo "# Brief 17C" > "$STEP_DIR_17C/brief.md"

  git -C "$WORKDIR_17C" init -q -b main
  echo "init" > "$WORKDIR_17C/init.txt"
  git -C "$WORKDIR_17C" add init.txt
  git -C "$WORKDIR_17C" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_17C="$(git -C "$WORKDIR_17C" rev-parse HEAD)"
  git -C "$WORKDIR_17C" checkout -q -b task/feature-17c

  SLEEP_PROBE_SCRIPT="$TMP_TEST_DIR/sleep_probe.sh"
  READY_PROBE_FILE="$TMP_TEST_DIR/ready_probe"
  rm -f "$READY_PROBE_FILE"
  cat <<EOF > "$SLEEP_PROBE_SCRIPT"
#!/usr/bin/env bash
touch "$READY_PROBE_FILE"
sleep 10
exit 0
EOF
  chmod +x "$SLEEP_PROBE_SCRIPT"

  clear_logs
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_PROBE_SCRIPT="$SLEEP_PROBE_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-17c" \
    HARNESS_TASK_BASE="$BASE_17C" \
    "$RUN_TASK_BIN" "$STEP_DIR_17C" "$WORKDIR_17C" >/dev/null 2>&1 &
  RUNNER_PID_17C=$!

  waited=0
  while [ ! -f "$READY_PROBE_FILE" ] && [ "$waited" -lt 50 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done

  kill -TERM "$RUNNER_PID_17C" 2>/dev/null || true
  set +e
  wait "$RUNNER_PID_17C" 2>/dev/null
  rc_17c=$?
  set -e

  assert_ok "runner exited with 143 on probe TERM" [ "$rc_17c" -eq 143 ]
  assert_ok "interrupted probe writes probe audit with status=INTERRUPTED" \
    jq -e '.phase == "model_probe" and .status == "INTERRUPTED" and .exit_code == 143' "$TASK_DIR_17C/probe-audit.jsonl"

  # 17d: Nonzero probe exit with parseable model JSON stops before implementation
  TASK_DIR_17D="$TMP_TEST_DIR/task-17d"
  STEP_DIR_17D="$TASK_DIR_17D/steps/01-step"
  WORKDIR_17D="$TMP_TEST_DIR/worktree-17d"
  mkdir -p "$STEP_DIR_17D" "$WORKDIR_17D"
  echo "# Brief 17D" > "$STEP_DIR_17D/brief.md"

  git -C "$WORKDIR_17D" init -q -b main
  echo "init" > "$WORKDIR_17D/init.txt"
  git -C "$WORKDIR_17D" add init.txt
  git -C "$WORKDIR_17D" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_17D="$(git -C "$WORKDIR_17D" rev-parse HEAD)"
  git -C "$WORKDIR_17D" checkout -q -b task/feature-17d

  EXIT7_PROBE_SCRIPT="$TMP_TEST_DIR/exit7_probe.sh"
  cat <<'EOF' > "$EXIT7_PROBE_SCRIPT"
#!/usr/bin/env bash
echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
exit 7
EOF
  chmod +x "$EXIT7_PROBE_SCRIPT"

  clear_logs
  OUTPUT_17D="$TMP_TEST_DIR/output_17d.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_PROBE_SCRIPT="$EXIT7_PROBE_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-17d" \
    HARNESS_TASK_BASE="$BASE_17D" \
    "$RUN_TASK_BIN" "$STEP_DIR_17D" "$WORKDIR_17D" >"$OUTPUT_17D" 2>&1
  rc_17d=$?
  set -e

  assert_ok "nonzero probe exit stops before implementation (exit 2)" [ "$rc_17d" -eq 2 ]
  assert_ok "nonzero probe exit does not write metrics.jsonl" [ ! -f "$TASK_DIR_17D/metrics.jsonl" ]
  assert_ok "nonzero probe exit does not allocate normal attempts" \
    test ! -f "$STEP_DIR_17D/prompt-1.md" -a ! -f "$STEP_DIR_17D/run-1.jsonl" -a ! -f "$STEP_DIR_17D/report-1.md"
  assert_ok "nonzero probe audit records probe_exit_code=7 and exit_code=2" \
    jq -e '.phase == "model_probe" and .status == "MODEL_PROBE_FAILED" and .exit_code == 2 and .probe_exit_code == 7' "$TASK_DIR_17D/probe-audit.jsonl"

  # 17e: Probe post-check helper failure yields explicit rejected audit with exit 1
  TASK_DIR_17E="$TMP_TEST_DIR/task-17e"
  STEP_DIR_17E="$TASK_DIR_17E/steps/01-step"
  WORKDIR_17E="$TMP_TEST_DIR/worktree-17e"
  mkdir -p "$STEP_DIR_17E" "$WORKDIR_17E"
  echo "# Brief 17E" > "$STEP_DIR_17E/brief.md"

  git -C "$WORKDIR_17E" init -q -b main
  echo "init" > "$WORKDIR_17E/init.txt"
  git -C "$WORKDIR_17E" add init.txt
  git -C "$WORKDIR_17E" -c user.name="Test" -c user.email="test@test.com" commit -m "initial commit" -q
  BASE_17E="$(git -C "$WORKDIR_17E" rev-parse HEAD)"
  git -C "$WORKDIR_17E" checkout -q -b task/feature-17e

  FAIL_POST_SCRIPT="$TMP_TEST_DIR/fail_post_probe.sh"
  cat <<'EOF' > "$FAIL_POST_SCRIPT"
#!/usr/bin/env bash
rm -f /tmp/harness-git-snapshot.* "${TMPDIR:-/tmp}"/harness-git-snapshot.* 2>/dev/null || true
exit 1
EOF
  chmod +x "$FAIL_POST_SCRIPT"

  clear_logs
  OUTPUT_17E="$TMP_TEST_DIR/output_17e.log"
  set +e
  PATH="$FAKE_BIN_DIR:$PATH" MOCK_PROBE_SCRIPT="$FAIL_POST_SCRIPT" \
    HARNESS_EXECUTION_MODE="docker-sandbox" \
    SANDBOX_ID="test-sandbox-id" SANDBOX_VM_ID="test-vm-id" SBX_AGENT="designer" \
    HARNESS_GIT_POLICY="task-commits" HARNESS_TASK_BRANCH="task/feature-17e" \
    HARNESS_TASK_BASE="$BASE_17E" \
    "$RUN_TASK_BIN" "$STEP_DIR_17E" "$WORKDIR_17E" >"$OUTPUT_17E" 2>&1
  rc_17e=$?
  set -e

  assert_ok "probe audit helper failure exits 1" [ "$rc_17e" -eq 1 ]
  assert_ok "probe audit records rejected outcome on helper failure" \
    jq -e '.phase == "model_probe" and .git_policy_outcome == "rejected" and .git_state_changed == true and .exit_code == 1' "$TASK_DIR_17E/probe-audit.jsonl"
else
  skip_test "probe-phase policy audit" "not running in a marked sandbox environment"
fi

# -----------------------------------------------------------------------------
echo "=========================================="
echo "Docker Sandbox tests passed: $PASSED, failed: $FAILED, skipped: $SKIPPED"
echo "=========================================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
