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
echo "=========================================="
echo "Docker Sandbox tests passed: $PASSED, failed: $FAILED, skipped: $SKIPPED"
echo "=========================================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
