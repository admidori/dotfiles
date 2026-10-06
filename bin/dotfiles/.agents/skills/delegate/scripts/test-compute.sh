#!/usr/bin/env bash
#
# test-compute.sh
#
# Focused offline test suite for remote compute manifest validation and
# delegation runner integration.
# Does not require network, Coder, Colab, or real Antigravity.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_BIN="$SCRIPT_DIR/validate-compute.sh"
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

TMP_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-test.XXXXXX")"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

echo "==> Testing compute manifest validation (validate-compute.sh)"

# 1. Valid templates
assert_ok "coder manifest template is valid" \
  "$VALIDATE_BIN" "$SKILL_DIR/templates/compute.json"
assert_ok "colab manifest template is valid" \
  "$VALIDATE_BIN" "$SKILL_DIR/templates/compute-colab.json"

# 2. Syntax, missing file, and root type
assert_fail "non-existent manifest rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/nonexistent.json"

echo "not json" > "$TMP_TEST_DIR/invalid.json"
assert_fail "invalid JSON syntax rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/invalid.json"

echo '["array", "root"]' > "$TMP_TEST_DIR/array-root.json"
assert_fail "non-object JSON root rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/array-root.json"

# 3. Legacy aliases rejected
cat <<'EOF' > "$TMP_TEST_DIR/legacy-timeout-alias.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout": 600,
  "max_attempts": 2
}
EOF
assert_fail "legacy 'timeout' alias rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/legacy-timeout-alias.json"

cat <<'EOF' > "$TMP_TEST_DIR/legacy-attempts-alias.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "attempts": 2
}
EOF
assert_fail "legacy 'attempts' alias rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/legacy-attempts-alias.json"

cat <<'EOF' > "$TMP_TEST_DIR/legacy-commands-alias.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "commands": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "legacy 'commands' alias rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/legacy-commands-alias.json"

# 4. Backend checks
cat <<'EOF' > "$TMP_TEST_DIR/missing-backend.json"
{
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "missing backend rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-backend.json"

cat <<'EOF' > "$TMP_TEST_DIR/numeric-backend.json"
{
  "backend": 123,
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "numeric backend rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/numeric-backend.json"

cat <<'EOF' > "$TMP_TEST_DIR/unknown-backend.json"
{
  "backend": "kubernetes",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "unknown backend rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/unknown-backend.json"

# 5. Target checks
cat <<'EOF' > "$TMP_TEST_DIR/missing-target.json"
{
  "backend": "coder",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "missing target rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-target.json"

cat <<'EOF' > "$TMP_TEST_DIR/numeric-target.json"
{
  "backend": "coder",
  "target": 123,
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "numeric target rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/numeric-target.json"

cat <<'EOF' > "$TMP_TEST_DIR/empty-target.json"
{
  "backend": "coder",
  "target": "   ",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "empty target string rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/empty-target.json"

cat <<'EOF' > "$TMP_TEST_DIR/remote-id-target.json"
{
  "backend": "coder",
  "target": "/workspaces/remote-gpu-workspace",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_ok "remote target identifier with slashes is accepted (not treated as local path)" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/remote-id-target.json"

# 6. Command checks
cat <<'EOF' > "$TMP_TEST_DIR/missing-command.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "missing command rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-command.json"

cat <<'EOF' > "$TMP_TEST_DIR/string-command.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": "python train.py --epochs 5",
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "shell string command rejected (must be argv array)" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/string-command.json"

cat <<'EOF' > "$TMP_TEST_DIR/empty-command-array.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": [],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "empty command array rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/empty-command-array.json"

cat <<'EOF' > "$TMP_TEST_DIR/command-array-with-empty.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "  "],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "command array with blank command rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/command-array-with-empty.json"

cat <<'EOF' > "$TMP_TEST_DIR/command-array-non-string.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", 123],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF
assert_fail "command array with non-string element rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/command-array-non-string.json"

# 7. timeout_seconds checks
cat <<'EOF' > "$TMP_TEST_DIR/missing-timeout.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "max_attempts": 2
}
EOF
assert_fail "missing timeout_seconds rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-timeout.json"

cat <<'EOF' > "$TMP_TEST_DIR/string-timeout.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": "600",
  "max_attempts": 2
}
EOF
assert_fail "string timeout_seconds rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/string-timeout.json"

cat <<'EOF' > "$TMP_TEST_DIR/float-timeout.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600.5,
  "max_attempts": 2
}
EOF
assert_fail "non-integer float timeout_seconds rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/float-timeout.json"

cat <<'EOF' > "$TMP_TEST_DIR/zero-timeout.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 0,
  "max_attempts": 2
}
EOF
assert_fail "zero timeout_seconds rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/zero-timeout.json"

cat <<'EOF' > "$TMP_TEST_DIR/negative-timeout.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": -30,
  "max_attempts": 2
}
EOF
assert_fail "negative timeout_seconds rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/negative-timeout.json"

cat <<'EOF' > "$TMP_TEST_DIR/excessive-timeout.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 86401,
  "max_attempts": 2
}
EOF
assert_fail "excessive timeout_seconds (>86400) rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/excessive-timeout.json"

# 8. max_attempts checks
cat <<'EOF' > "$TMP_TEST_DIR/missing-attempts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600
}
EOF
assert_fail "missing max_attempts rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-attempts.json"

cat <<'EOF' > "$TMP_TEST_DIR/string-attempts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": "2"
}
EOF
assert_fail "string max_attempts rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/string-attempts.json"

cat <<'EOF' > "$TMP_TEST_DIR/float-attempts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2.5
}
EOF
assert_fail "non-integer float max_attempts rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/float-attempts.json"

cat <<'EOF' > "$TMP_TEST_DIR/zero-attempts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 0
}
EOF
assert_fail "zero max_attempts rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/zero-attempts.json"

cat <<'EOF' > "$TMP_TEST_DIR/excessive-attempts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 11
}
EOF
assert_fail "unbounded excessive max_attempts (>10) rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/excessive-attempts.json"

# Keep literal number spellings: jq versions can preserve decimals/exponents.
for values in '0.0 2' '-1.0 2' '86401.0 2' '1e100 2' \
  '600 0.0' '600 -1.0' '600 11.0' '600 1e100'; do
  read -r timeout_value attempts_value <<< "$values"
  printf '{"backend":"coder","target":"gpu-workspace","command":["true"],"timeout_seconds":%s,"max_attempts":%s}\n' \
    "$timeout_value" "$attempts_value" > "$TMP_TEST_DIR/numeric-boundary.json"
  assert_fail "out-of-range numeric literals $values rejected" \
    "$VALIDATE_BIN" "$TMP_TEST_DIR/numeric-boundary.json"
done
for values in '1.0 1.0' '86400.0 10.0' '8.64e4 1e1'; do
  read -r timeout_value attempts_value <<< "$values"
  printf '{"backend":"coder","target":"gpu-workspace","command":["true"],"timeout_seconds":%s,"max_attempts":%s}\n' \
    "$timeout_value" "$attempts_value" > "$TMP_TEST_DIR/numeric-boundary.json"
  assert_ok "valid numeric boundaries $values accepted" \
    "$VALIDATE_BIN" "$TMP_TEST_DIR/numeric-boundary.json"
done

# 9. Path boundary checks
cat <<'EOF' > "$TMP_TEST_DIR/non-array-inputs.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "inputs": "not-an-array.txt"
}
EOF
assert_fail "non-array inputs rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/non-array-inputs.json"

cat <<'EOF' > "$TMP_TEST_DIR/abs-path-inputs.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "inputs": ["/etc/passwd"]
}
EOF
assert_fail "absolute local path in inputs rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/abs-path-inputs.json"

cat <<'EOF' > "$TMP_TEST_DIR/traverse-inputs.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "inputs": ["../secret.txt"]
}
EOF
assert_fail "traversing local path in inputs rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/traverse-inputs.json"

cat <<'EOF' > "$TMP_TEST_DIR/traverse-mid-inputs.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "inputs": ["scripts/../../secret.txt"]
}
EOF
assert_fail "mid-path traversal in inputs rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/traverse-mid-inputs.json"

cat <<'EOF' > "$TMP_TEST_DIR/abs-path-artifacts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "artifacts": ["/var/log/app.log"]
}
EOF
assert_fail "absolute local path in artifacts rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/abs-path-artifacts.json"

cat <<'EOF' > "$TMP_TEST_DIR/traverse-artifacts.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "artifacts": ["outputs/../../out.txt"]
}
EOF
assert_fail "traversing local path in artifacts rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/traverse-artifacts.json"

cat <<'EOF' > "$TMP_TEST_DIR/colab-dir-staging.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "scripts": ["src/"]
}
EOF
assert_fail "colab directory staging rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/colab-dir-staging.json"

cat <<'EOF' > "$TMP_TEST_DIR/colab-dir-artifacts.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "artifacts": ["outputs/"]
}
EOF
assert_fail "colab directory artifacts collection rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/colab-dir-artifacts.json"

for field in inputs scripts artifacts; do
  for paths in '[""]' '["train.py", ""]' '["", "train.py"]' '["train.py", " "]'; do
    jq --arg field "$field" --argjson paths "$paths" '.[$field] = $paths' \
      "$SKILL_DIR/templates/compute.json" > "$TMP_TEST_DIR/empty-path.json"
    assert_fail "$field rejects empty path in $paths" \
      "$VALIDATE_BIN" "$TMP_TEST_DIR/empty-path.json"
  done
  jq --arg field "$field" '.[$field] = []' \
    "$SKILL_DIR/templates/compute.json" > "$TMP_TEST_DIR/empty-path.json"
  assert_ok "$field accepts an empty optional array" \
    "$VALIDATE_BIN" "$TMP_TEST_DIR/empty-path.json"
done

# 10. Datasets checks
cat <<'EOF' > "$TMP_TEST_DIR/non-array-datasets.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": "gs://bucket/dataset.tar.gz"
}
EOF
assert_fail "non-array datasets rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/non-array-datasets.json"

cat <<'EOF' > "$TMP_TEST_DIR/string-datasets.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": ["gs://bucket/dataset.tar.gz"]
}
EOF
assert_fail "array of strings in datasets rejected (must be object with uri and sha256)" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/string-datasets.json"

cat <<'EOF' > "$TMP_TEST_DIR/missing-sha-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "gs://bucket/dataset.tar.gz"
    }
  ]
}
EOF
assert_fail "dataset object without sha256 rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-sha-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/missing-uri-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object without uri rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-uri-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/empty-uri-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "   ",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with empty uri rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/empty-uri-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/relative-path-uri-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "data/dataset.tar.gz",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with relative path (no scheme) rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/relative-path-uri-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/abs-path-uri-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "/tmp/dataset.tar.gz",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with local absolute path (no scheme) rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/abs-path-uri-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/missing-scheme-uri-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "://bucket/dataset.tar.gz",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with missing scheme rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/missing-scheme-uri-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/invalid-scheme-uri-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "123scheme://bucket/dataset.tar.gz",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with numeric-start scheme rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/invalid-scheme-uri-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/short-sha256-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "gs://bucket/dataset.tar.gz",
      "sha256": "000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with short sha256 (63 hex chars) rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/short-sha256-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/long-sha256-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "gs://bucket/dataset.tar.gz",
      "sha256": "00000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with long sha256 (65 hex chars) rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/long-sha256-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/non-hex-sha256-dataset.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "gs://bucket/dataset.tar.gz",
      "sha256": "z000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_fail "dataset object with non-hex characters in sha256 rejected" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/non-hex-sha256-dataset.json"

cat <<'EOF' > "$TMP_TEST_DIR/valid-datasets-lowercase.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "gs://bucket/dataset.tar.gz",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    }
  ]
}
EOF
assert_ok "dataset object with lowercase 64-hex sha256 accepted" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/valid-datasets-lowercase.json"

cat <<'EOF' > "$TMP_TEST_DIR/valid-datasets-uppercase.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "s3://bucket/dataset.tar.gz",
      "sha256": "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
    }
  ]
}
EOF
assert_ok "dataset object with uppercase 64-hex sha256 accepted" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/valid-datasets-uppercase.json"

cat <<'EOF' > "$TMP_TEST_DIR/valid-datasets-custom-scheme.json"
{
  "backend": "colab",
  "target": "notebook.ipynb",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2,
  "datasets": [
    {
      "uri": "custom+proto-1.0://bucket/dataset.tar.gz",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
assert_ok "dataset object with custom valid URI scheme accepted" \
  "$VALIDATE_BIN" "$TMP_TEST_DIR/valid-datasets-custom-scheme.json"

echo "==> Testing run-task.sh integration with fake agy"

# Setup fake agy and harness environment
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
{"event":"result","result":{"status":"SUCCESS","duration_seconds":0.5,"num_turns":1,"response":"# Report: Step 01\n\n## Summary\nMock run done.\n"}}
JSON
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/agy"

# Mock workdir
MOCK_WORKDIR="$TMP_TEST_DIR/worktree"
mkdir -p "$MOCK_WORKDIR"
echo "# Mock Agent Instructions" > "$MOCK_WORKDIR/AGENTS.md"
git -C "$MOCK_WORKDIR" init -q

# Helper to run run-task.sh in isolated task environment
run_harness_task() {
  local step_dir="$1"
  shift
  PATH="$FAKE_BIN_DIR:$PATH" "$RUN_TASK_BIN" "$step_dir" "$MOCK_WORKDIR" "$@"
}

# Scenario A: Step WITHOUT compute.json (local-only step)
TASK_DIR_A="$TMP_TEST_DIR/task-local"
STEP_DIR_A="$TASK_DIR_A/steps/01-local-step"
mkdir -p "$STEP_DIR_A"
cat <<'EOF' > "$STEP_DIR_A/brief.md"
# Step 01: Local Step
## Task
Do local edit.
EOF

assert_ok "run-task succeeds on step without compute.json" \
  run_harness_task "$STEP_DIR_A"

assert_fail "prompt without compute.json has no compute manifest header" \
  grep -q "# Remote GPU compute manifest" "$STEP_DIR_A/prompt-1.md"

assert_fail "prompt without compute.json has no staging rules" \
  grep -q "Backend-specific staging rules" "$STEP_DIR_A/prompt-1.md"

assert_fail "prompt without compute.json has no attempt audit paths" \
  grep -q "Attempt audit paths" "$STEP_DIR_A/prompt-1.md"

assert_fail "local step does not create compute-1 directory" \
  test -d "$STEP_DIR_A/compute-1"

assert_ok "metrics for step without compute.json records null compute_backend" \
  jq -e '.compute_backend == null' "$TASK_DIR_A/metrics.jsonl"

assert_ok "metrics has no duplicate backend field" \
  jq -e 'has("backend") | not' "$TASK_DIR_A/metrics.jsonl"

# Scenario B: Step WITH valid coder compute.json
TASK_DIR_B="$TMP_TEST_DIR/task-coder"
STEP_DIR_B="$TASK_DIR_B/steps/02-gpu-coder"
mkdir -p "$STEP_DIR_B"
cat <<'EOF' > "$STEP_DIR_B/brief.md"
# Step 02: GPU Coder Step
## Task
Run remote training on Coder.
EOF
cp "$SKILL_DIR/templates/compute.json" "$STEP_DIR_B/compute.json"

assert_ok "run-task succeeds on step with valid coder compute.json" \
  run_harness_task "$STEP_DIR_B"

assert_ok "prompt includes remote GPU compute manifest section" \
  grep -q "# Remote GPU compute manifest" "$STEP_DIR_B/prompt-1.md"

assert_ok "prompt includes Coder backend staging rules" \
  grep -q "Backend-specific staging rules: coder" "$STEP_DIR_B/prompt-1.md"

assert_ok "prompt includes retry and release requirements" \
  grep -q "Retry and release requirements" "$STEP_DIR_B/prompt-1.md"

assert_ok "prompt embeds attempt-specific compute audit directory" \
  grep -q "Compute audit directory: \`$STEP_DIR_B/compute-1\`" "$STEP_DIR_B/prompt-1.md"

assert_ok "prompt embeds lifecycle state file path" \
  grep -q "Lifecycle state file: \`$STEP_DIR_B/compute-1/state.json\`" "$STEP_DIR_B/prompt-1.md"

assert_ok "prompt embeds remote events log path" \
  grep -q "Remote events log: \`$STEP_DIR_B/compute-1/events.jsonl\`" "$STEP_DIR_B/prompt-1.md"

assert_ok "prompt embeds artifacts directory path" \
  grep -q "Artifacts directory: \`$STEP_DIR_B/compute-1/artifacts\`" "$STEP_DIR_B/prompt-1.md"

assert_ok "runner created attempt-specific compute audit directory" \
  test -d "$STEP_DIR_B/compute-1"

assert_ok "runner created attempt-specific artifacts directory" \
  test -d "$STEP_DIR_B/compute-1/artifacts"

assert_ok "runner initialized state.json with backend, target, attempt count" \
  jq -e '.backend == "coder" and .target == "gpu-workspace" and .attempt == 1 and .phase == "initialized"' "$STEP_DIR_B/compute-1/state.json"

assert_ok "runner created events.jsonl location" \
  test -f "$STEP_DIR_B/compute-1/events.jsonl"

assert_ok "coder prompt explicitly forbids secrets in state.json and events.jsonl" \
  grep -Fq "Neither \`state.json\` nor \`events.jsonl\` may contain credentials, tokens, dataset contents, or other secrets." "$STEP_DIR_B/prompt-1.md"

assert_ok "metrics records requested compute_backend 'coder'" \
  jq -e '.compute_backend == "coder"' "$TASK_DIR_B/metrics.jsonl"

assert_ok "metrics has no duplicate backend field for coder" \
  jq -e 'has("backend") | not' "$TASK_DIR_B/metrics.jsonl"

# Scenario C: Step WITH valid colab compute.json
TASK_DIR_C="$TMP_TEST_DIR/task-colab"
STEP_DIR_C="$TASK_DIR_C/steps/03-gpu-colab"
mkdir -p "$STEP_DIR_C"
cat <<'EOF' > "$STEP_DIR_C/brief.md"
# Step 03: GPU Colab Step
## Task
Run remote training on Colab.
EOF
cp "$SKILL_DIR/templates/compute-colab.json" "$STEP_DIR_C/compute.json"

assert_ok "run-task succeeds on step with valid colab compute.json" \
  run_harness_task "$STEP_DIR_C"

assert_ok "prompt includes Colab backend staging rules" \
  grep -q "Backend-specific staging rules: colab" "$STEP_DIR_C/prompt-1.md"

assert_ok "prompt requires scripts injected only from manifest" \
  grep -q "inject listed scripts from the manifest" "$STEP_DIR_C/prompt-1.md"

assert_ok "prompt requires datasets use declared URIs" \
  grep -q "datasets use the declared URIs" "$STEP_DIR_C/prompt-1.md"

assert_ok "prompt truthful about no general directory-sync capability" \
  grep -q "Never claim a general directory-sync capability" "$STEP_DIR_C/prompt-1.md"

assert_ok "colab prompt describes official colab-mcp notebook cell output semantics" \
  grep -Fq "Official \`googlecolab/colab-mcp\` exposes notebook cells and outputs, not a general binary download/directory-sync API" "$STEP_DIR_C/prompt-1.md"

assert_ok "colab prompt allows bounded text/JSON results to be saved to artifacts dir" \
  grep -Fq "Bounded text/JSON results may be emitted as cell output and written into \`$STEP_DIR_C/compute-1/artifacts\`" "$STEP_DIR_C/prompt-1.md"

assert_ok "colab prompt requires large/binary artifacts uploaded externally, not base64-inlined" \
  grep -Fq "Never base64-inline them into prompts or cell output" "$STEP_DIR_C/prompt-1.md"

assert_ok "colab prompt does not promise arbitrary download of Colab artifact paths" \
  grep -Fq "Do not promise or expect that arbitrary Colab artifact paths will be downloaded" "$STEP_DIR_C/prompt-1.md"

assert_ok "colab prompt explicitly forbids secrets in state.json and events.jsonl" \
  grep -Fq "Neither \`state.json\` nor \`events.jsonl\` may contain credentials, tokens, dataset contents, or other secrets." "$STEP_DIR_C/prompt-1.md"

assert_ok "prompt specifies recording preserved with reason if runtime cannot be released" \
  grep -q "record \`preserved\` with the reason" "$STEP_DIR_C/prompt-1.md"

assert_ok "metrics records requested compute_backend 'colab'" \
  jq -e '.compute_backend == "colab"' "$TASK_DIR_C/metrics.jsonl"

assert_ok "metrics has no duplicate backend field for colab" \
  jq -e 'has("backend") | not' "$TASK_DIR_C/metrics.jsonl"

# Scenario D: Step WITH invalid compute.json fails BEFORE agy runs (preflight rejection)
TASK_DIR_D="$TMP_TEST_DIR/task-invalid"
STEP_DIR_D="$TASK_DIR_D/steps/04-invalid"
mkdir -p "$STEP_DIR_D"
cat <<'EOF' > "$STEP_DIR_D/brief.md"
# Step 04: Invalid Step
## Task
Invalid.
EOF
cat <<'EOF' > "$STEP_DIR_D/compute.json"
{
  "backend": "unknown-backend",
  "target": "gpu-node",
  "command": ["python", "train.py"],
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF

assert_fail "run-task fails before agy on invalid backend in compute.json" \
  run_harness_task "$STEP_DIR_D"

assert_ok "no run-1.jsonl created when validation fails" \
  test ! -e "$STEP_DIR_D/run-1.jsonl"

cat <<'EOF' > "$STEP_DIR_D/compute.json"
{
  "backend": "coder",
  "target": "gpu-node",
  "command": "python train.py",
  "timeout_seconds": 600,
  "max_attempts": 2
}
EOF

assert_fail "run-task fails before agy on string command in compute.json" \
  run_harness_task "$STEP_DIR_D"

# Scenario E: Multi-attempt recovery and distinct audit paths
TASK_DIR_E="$TMP_TEST_DIR/task-rework"
STEP_DIR_E="$TASK_DIR_E/steps/05-rework"
mkdir -p "$STEP_DIR_E"
cat <<'EOF' > "$STEP_DIR_E/brief.md"
# Step 05: Rework Step
## Task
Initial attempt.
EOF
cp "$SKILL_DIR/templates/compute.json" "$STEP_DIR_E/compute.json"

assert_ok "run-task succeeds on attempt 1" \
  run_harness_task "$STEP_DIR_E"

assert_ok "attempt 1 directory compute-1 exists" \
  test -d "$STEP_DIR_E/compute-1"

cat <<'EOF' > "$STEP_DIR_E/rework-2.md"
# Step 05: Rework 2
## Task
Second attempt rework.
EOF

assert_ok "run-task succeeds on attempt 2" \
  run_harness_task "$STEP_DIR_E" "$STEP_DIR_E/rework-2.md"

assert_ok "attempt 2 directory compute-2 exists" \
  test -d "$STEP_DIR_E/compute-2"

assert_ok "attempt 2 artifacts directory exists" \
  test -d "$STEP_DIR_E/compute-2/artifacts"

assert_ok "prompt-2 embeds attempt 2 audit paths" \
  grep -q "Lifecycle state file: \`$STEP_DIR_E/compute-2/state.json\`" "$STEP_DIR_E/prompt-2.md"

# Scenario F: When agy fails, metrics still records the requested compute_backend
TASK_DIR_F="$TMP_TEST_DIR/task-fail"
STEP_DIR_F="$TASK_DIR_F/steps/06-fail"
mkdir -p "$STEP_DIR_F"
cat <<'EOF' > "$STEP_DIR_F/brief.md"
# Step 06: Fail Step
## Task
Fails.
EOF
cp "$SKILL_DIR/templates/compute.json" "$STEP_DIR_F/compute.json"

# Create a failing fake agy
cat <<'EOF' > "$FAKE_BIN_DIR/agy"
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "/model" ]; then
  echo '{"command":{"data":{"id":"mock-gemini","label":"Mock Gemini"}}}'
  exit 0
fi
echo '{"event":"result","result":{"status":"ERROR","duration_seconds":0.1,"num_turns":1}}'
exit 1
EOF
chmod +x "$FAKE_BIN_DIR/agy"

assert_fail "run-task exits non-zero when agy fails" \
  run_harness_task "$STEP_DIR_F"

assert_ok "metrics records requested compute_backend even when agy fails" \
  jq -e '.compute_backend == "coder" and .exit_code == 1' "$TASK_DIR_F/metrics.jsonl"

assert_ok "metrics has no duplicate backend field when agy fails" \
  jq -e 'has("backend") | not' "$TASK_DIR_F/metrics.jsonl"

echo "=========================================="
echo "Tests passed: $PASSED, failed: $FAILED"
echo "=========================================="
[ "$FAILED" -eq 0 ]
