#!/usr/bin/env bash
#
# test-context.sh
#
# Focused offline test suite for shared exploration context injection
# and delegation runner integration.
# Does not require network, remote compute, or real Antigravity.
#
set -euo pipefail

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

TMP_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-context-test.XXXXXX")"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

echo "==> Testing runner integration with fake agy"

# Setup fake agy binary
FAKE_BIN_DIR="$TMP_TEST_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"
cat <<'EOF' > "$FAKE_BIN_DIR/agy"
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "/model" ]; then
  echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
  exit 0
fi

# Main invocation: emit stream-json event log and exit 0
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

# 2. Absent context (legacy run preservation)
echo "==> Scenario 1: Absent context (legacy run preservation)"
TASK_DIR_1="$TMP_TEST_DIR/task-legacy"
STEP_DIR_1="$TASK_DIR_1/steps/01-legacy-step"
mkdir -p "$STEP_DIR_1"
cat <<'EOF' > "$STEP_DIR_1/brief.md"
# Step 01: Legacy Step
## Task
Do legacy change without context.md.
EOF

assert_ok "run-task succeeds on step when context.md is absent" \
  run_harness_task "$STEP_DIR_1"

assert_ok "prompt snapshot prompt-1.md was created" \
  test -f "$STEP_DIR_1/prompt-1.md"

assert_ok "prompt includes visible notice for missing context" \
  grep -Fq "Notice: No shared exploration context file found at" "$STEP_DIR_1/prompt-1.md"

assert_ok "prompt includes legacy run notice" \
  grep -Fq "Preserving legacy run." "$STEP_DIR_1/prompt-1.md"

assert_fail "prompt does not include context source path header" \
  grep -q "^Source: " "$STEP_DIR_1/prompt-1.md"

assert_ok "agy ran successfully and generated report-1.md" \
  test -s "$STEP_DIR_1/report-1.md"

assert_ok "run-1.jsonl event log was recorded" \
  test -s "$STEP_DIR_1/run-1.jsonl"

# 3. Unreadable context rejected fast before agy runs
echo "==> Scenario 2: Unreadable or invalid context file rejected fast"
TASK_DIR_2="$TMP_TEST_DIR/task-unreadable"
STEP_DIR_2="$TASK_DIR_2/steps/01-unreadable-step"
mkdir -p "$STEP_DIR_2"
cat <<'EOF' > "$STEP_DIR_2/brief.md"
# Step 01: Unreadable Context Step
## Task
Should fail before agy runs.
EOF
ln -s "$TASK_DIR_2/missing-context.md" "$TASK_DIR_2/context.md"

assert_fail "run-task fails when context.md is a broken symlink" \
  run_harness_task "$STEP_DIR_2"

assert_ok "no run-1.jsonl created when context is a broken symlink" \
  test ! -e "$STEP_DIR_2/run-1.jsonl"

TASK_DIR_2_DIR="$TMP_TEST_DIR/task-dir-context"
STEP_DIR_2_DIR="$TASK_DIR_2_DIR/steps/01-dir-step"
mkdir -p "$STEP_DIR_2_DIR"
cat <<'EOF' > "$STEP_DIR_2_DIR/brief.md"
# Step 01: Directory Context Step
## Task
Should fail because context is a directory.
EOF
mkdir -p "$TASK_DIR_2_DIR/context.md"

assert_fail "run-task fails when context.md exists as a directory" \
  run_harness_task "$STEP_DIR_2_DIR"

assert_ok "no run-1.jsonl created when context is a directory" \
  test ! -e "$STEP_DIR_2_DIR/run-1.jsonl"

# 4. Literal inclusion with shell metacharacters and spaced paths
echo "==> Scenario 3: Literal inclusion with shell metacharacters and spaced paths"
TASK_DIR_3="$TMP_TEST_DIR/task with spaces in path"
STEP_DIR_3="$TASK_DIR_3/steps/01-spaced step"
mkdir -p "$STEP_DIR_3"
cat <<'EOF' > "$STEP_DIR_3/brief.md"
# Step 01: Spaced and Metacharacter Step
## Task
Verify literal embedding without expansion.
EOF

cat <<'EOF' > "$TASK_DIR_3/context.md"
# Shared Exploration Context

## Symbols and Paths
- `bin/dotfiles/.agents/skills/delegate/scripts/run-task.sh`: runner entry point
- `app::run_service()`: main service dispatcher

## Tricky Shell Characters
$UNSET_ENV_VARIABLE
${EXPANSION_TEST:-fallback}
`touch /tmp/test-delegate-injected-backtick`
$(touch /tmp/test-delegate-injected-subshell)
"Double quoted string" and 'Single quoted string'
Wildcards * and & and | and ; and \ backslashes
EOF

assert_ok "run-task succeeds with spaced paths and shell metacharacters in context.md" \
  run_harness_task "$STEP_DIR_3"

assert_ok "prompt contains Shared exploration context heading" \
  grep -Fq "# Shared exploration context" "$STEP_DIR_3/prompt-1.md"

assert_ok "prompt contains exact context Source path with spaces" \
  grep -Fq "Source: \`$TASK_DIR_3/context.md\`" "$STEP_DIR_3/prompt-1.md"

assert_ok "prompt instructs to treat context as reviewed evidence rather than scope authorization" \
  grep -Fq "Treat this shared context as reviewed evidence rather than scope authorization;" "$STEP_DIR_3/prompt-1.md"

assert_ok "prompt instructs that brief defines step and source code wins" \
  grep -Fq "the brief defines this step and source code wins when facts are stale." "$STEP_DIR_3/prompt-1.md"

# shellcheck disable=SC2016
assert_ok "prompt contains unexpanded variable literal \$UNSET_ENV_VARIABLE" \
  grep -Fq '$UNSET_ENV_VARIABLE' "$STEP_DIR_3/prompt-1.md"

# shellcheck disable=SC2016
assert_ok "prompt contains unexpanded parameter expansion \${EXPANSION_TEST:-fallback}" \
  grep -Fq '${EXPANSION_TEST:-fallback}' "$STEP_DIR_3/prompt-1.md"

# shellcheck disable=SC2016
assert_ok "prompt contains unexecuted backtick command substitution" \
  grep -Fq '`touch /tmp/test-delegate-injected-backtick`' "$STEP_DIR_3/prompt-1.md"

# shellcheck disable=SC2016
assert_ok "prompt contains unexecuted subshell command substitution" \
  grep -Fq '$(touch /tmp/test-delegate-injected-subshell)' "$STEP_DIR_3/prompt-1.md"

assert_ok "prompt contains path symbol app::run_service()" \
  grep -Fq 'app::run_service()' "$STEP_DIR_3/prompt-1.md"

assert_ok "injected backtick command was not executed" \
  test ! -e /tmp/test-delegate-injected-backtick

assert_ok "injected subshell command was not executed" \
  test ! -e /tmp/test-delegate-injected-subshell

# 5. Next-step updated context and snapshot preservation
echo "==> Scenario 4: Next-step updated context and snapshot preservation"
TASK_DIR_4="$TMP_TEST_DIR/task-next-step"
STEP_DIR_4A="$TASK_DIR_4/steps/01-first-step"
STEP_DIR_4B="$TASK_DIR_4/steps/02-second-step"
mkdir -p "$STEP_DIR_4A" "$STEP_DIR_4B"

cat <<'EOF' > "$TASK_DIR_4/context.md"
# Context Version 1
Initial fact: module_alpha lives in src/alpha.py
EOF

cat <<'EOF' > "$STEP_DIR_4A/brief.md"
# Step 01: First Step
## Task
Run first step.
EOF

assert_ok "step 1 runs successfully" \
  run_harness_task "$STEP_DIR_4A"

assert_ok "step 1 prompt contains initial context fact" \
  grep -Fq "Initial fact: module_alpha lives in src/alpha.py" "$STEP_DIR_4A/prompt-1.md"

STEP1_PROMPT_COPY="$TMP_TEST_DIR/step1-prompt-copy.md"
cp "$STEP_DIR_4A/prompt-1.md" "$STEP1_PROMPT_COPY"

# Designer updates context before step 2
cat <<'EOF' > "$TASK_DIR_4/context.md"
# Context Version 2
Initial fact: module_alpha lives in src/alpha.py
Promoted fact: module_beta added in src/beta.py with symbol beta_handler()
EOF

cat <<'EOF' > "$STEP_DIR_4B/brief.md"
# Step 02: Second Step
## Task
Run second step with updated context.
EOF

assert_ok "step 2 runs successfully" \
  run_harness_task "$STEP_DIR_4B"

assert_ok "step 2 prompt contains newly promoted fact" \
  grep -Fq "Promoted fact: module_beta added in src/beta.py with symbol beta_handler()" "$STEP_DIR_4B/prompt-1.md"

assert_ok "step 1 prompt snapshot was preserved byte-for-byte" \
  cmp -s "$STEP1_PROMPT_COPY" "$STEP_DIR_4A/prompt-1.md"

# 6. Rework updated context with third-argument rework brief
echo "==> Scenario 5: Rework updated context with third-argument rework brief"
TASK_DIR_5="$TMP_TEST_DIR/task-rework-context"
STEP_DIR_5="$TASK_DIR_5/steps/01-step-with-rework"
mkdir -p "$STEP_DIR_5"

cat <<'EOF' > "$TASK_DIR_5/context.md"
# Context for Step 1 Attempt 1
Verified fact: baseline config is valid
EOF

cat <<'EOF' > "$STEP_DIR_5/brief.md"
# Step 01: Initial Brief
## Task
First attempt at implementation.
EOF

assert_ok "attempt 1 runs successfully" \
  run_harness_task "$STEP_DIR_5"

assert_ok "attempt 1 prompt exists" \
  test -f "$STEP_DIR_5/prompt-1.md"

assert_ok "attempt 1 prompt contains attempt 1 context" \
  grep -Fq "Verified fact: baseline config is valid" "$STEP_DIR_5/prompt-1.md"

ATTEMPT1_PROMPT_COPY="$TMP_TEST_DIR/rework-attempt1-copy.md"
cp "$STEP_DIR_5/prompt-1.md" "$ATTEMPT1_PROMPT_COPY"

# Designer updates context based on attempt 1 review and prepares rework brief
cat <<'EOF' > "$TASK_DIR_5/context.md"
# Context for Step 1 Attempt 2
Verified fact: baseline config is valid
Rejected path: approach with direct socket failed due to sandbox constraints
EOF

cat <<'EOF' > "$STEP_DIR_5/rework-2.md"
# Step 01: Rework Brief 2
## Task
Fix defects from attempt 1 using updated constraints.
EOF

assert_ok "attempt 2 runs successfully with third-argument rework brief" \
  run_harness_task "$STEP_DIR_5" "$STEP_DIR_5/rework-2.md"

assert_ok "attempt 2 prompt prompt-2.md was created" \
  test -f "$STEP_DIR_5/prompt-2.md"

assert_ok "attempt 2 prompt contains rework brief task" \
  grep -Fq "Fix defects from attempt 1 using updated constraints." "$STEP_DIR_5/prompt-2.md"

assert_ok "attempt 2 prompt contains updated rejected path from context" \
  grep -Fq "Rejected path: approach with direct socket failed due to sandbox constraints" "$STEP_DIR_5/prompt-2.md"

assert_ok "attempt 1 prompt prompt-1.md remained unchanged" \
  cmp -s "$ATTEMPT1_PROMPT_COPY" "$STEP_DIR_5/prompt-1.md"

assert_ok "attempt 2 metrics row exists" \
  jq -e 'select(.step == "01-step-with-rework" and .attempt == 2)' "$TASK_DIR_5/metrics.jsonl"

echo "=========================================="
echo "Tests passed: $PASSED, failed: $FAILED"
echo "=========================================="
[ "$FAILED" -eq 0 ]
