#!/usr/bin/env bash
#
# Rule validation tests for ai-insecure.yml semgrep rules.
# Asserts each rule matches positive fixture and ignores negative fixture.
#
set -euo pipefail

if ! command -v semgrep >/dev/null 2>&1; then
  echo "SKIP: semgrep is not installed or not on PATH"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RULES_FILE="$REPO_ROOT/bin/dotfiles/.git-hooks/semgrep/ai-insecure.yml"

fail=0
check() {
  local desc="$1"; shift
  if "$@"; then
    echo "  ok   : $desc"
  else
    echo "  FAIL : $desc"
    fail=1
  fi
}

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

assert_rule() {
  local rule_id="$1"
  local file="$2"
  local expected="$3" # 1 = should match, 0 = should not match

  local json
  json="$(semgrep scan --config "$RULES_FILE" --metrics=off --disable-version-check --json "$file" 2>/dev/null)"

  local match_count
  match_count="$(echo "$json" | jq --arg r "$rule_id" '[.results[] | select(.check_id | endswith($r))] | length')"

  if [ "$expected" -eq 1 ]; then
    [ "$match_count" -gt 0 ]
  else
    [ "$match_count" -eq 0 ]
  fi
}

# --- Runtime assembly tokens for bash tests ---
c_bin="cu""rl"
b_bin="ba""sh"
k_flag="-"'k'
ch_bin="ch""mod"
perm_777="7""77"

echo "==> Testing Python rules"
# 1. requests verify=False
cat > "$TEST_DIR/req_pos.py" << 'EOF'
import requests
requests.get("https://example.com", verify=False)
EOF
cat > "$TEST_DIR/req_neg.py" << 'EOF'
import requests
requests.get("https://example.com", verify=True)
requests.get("https://example.com")
EOF
check "ai-python-requests-verify-false matches positive" \
  assert_rule "ai-python-requests-verify-false" "$TEST_DIR/req_pos.py" 1
check "ai-python-requests-verify-false ignores negative" \
  assert_rule "ai-python-requests-verify-false" "$TEST_DIR/req_neg.py" 0

# 2. subprocess shell=True
cat > "$TEST_DIR/sub_pos.py" << 'EOF'
import subprocess
def run_cmd(user_input):
    subprocess.run(user_input, shell=True)
EOF
cat > "$TEST_DIR/sub_neg.py" << 'EOF'
import subprocess
subprocess.run("ls -la", shell=True)
subprocess.run(["ls", "-la"], shell=False)
EOF
check "ai-python-subprocess-shell-true matches positive" \
  assert_rule "ai-python-subprocess-shell-true" "$TEST_DIR/sub_pos.py" 1
check "ai-python-subprocess-shell-true ignores negative" \
  assert_rule "ai-python-subprocess-shell-true" "$TEST_DIR/sub_neg.py" 0

# 3. os.system
cat > "$TEST_DIR/os_pos.py" << 'EOF'
import os
def run_it(cmd):
    os.system(cmd)
EOF
cat > "$TEST_DIR/os_neg.py" << 'EOF'
import os
os.system("echo safe")
EOF
check "ai-python-os-system matches positive" \
  assert_rule "ai-python-os-system" "$TEST_DIR/os_pos.py" 1
check "ai-python-os-system ignores negative" \
  assert_rule "ai-python-os-system" "$TEST_DIR/os_neg.py" 0

# 4. eval/exec
cat > "$TEST_DIR/eval_pos.py" << 'EOF'
def run_code(user_code):
    eval(user_code)
EOF
cat > "$TEST_DIR/eval_neg.py" << 'EOF'
eval("1 + 1")
EOF
check "ai-python-eval-exec matches positive" \
  assert_rule "ai-python-eval-exec" "$TEST_DIR/eval_pos.py" 1
check "ai-python-eval-exec ignores negative" \
  assert_rule "ai-python-eval-exec" "$TEST_DIR/eval_neg.py" 0

# 5. yaml.load
cat > "$TEST_DIR/yaml_pos.py" << 'EOF'
import yaml
yaml.load(data)
EOF
cat > "$TEST_DIR/yaml_neg.py" << 'EOF'
import yaml
yaml.safe_load(data)
yaml.load(data, Loader=yaml.SafeLoader)
EOF
check "ai-python-yaml-unsafe-load matches positive" \
  assert_rule "ai-python-yaml-unsafe-load" "$TEST_DIR/yaml_pos.py" 1
check "ai-python-yaml-unsafe-load ignores negative" \
  assert_rule "ai-python-yaml-unsafe-load" "$TEST_DIR/yaml_neg.py" 0

# 6. pickle.load
cat > "$TEST_DIR/pickle_pos.py" << 'EOF'
import pickle
pickle.loads(data)
EOF
cat > "$TEST_DIR/pickle_neg.py" << 'EOF'
import pickle
pickle.dumps(data)
EOF
check "ai-python-pickle-load matches positive" \
  assert_rule "ai-python-pickle-load" "$TEST_DIR/pickle_pos.py" 1
check "ai-python-pickle-load ignores negative" \
  assert_rule "ai-python-pickle-load" "$TEST_DIR/pickle_neg.py" 0

# 7. sql injection
cat > "$TEST_DIR/sql_pos.py" << 'EOF'
def query(cur, uid):
    cur.execute(f"SELECT * FROM users WHERE id = {uid}")
EOF
cat > "$TEST_DIR/sql_neg.py" << 'EOF'
def query(cur, uid):
    cur.execute("SELECT * FROM users WHERE id = %s", (uid,))
EOF
check "ai-python-sql-injection matches positive" \
  assert_rule "ai-python-sql-injection" "$TEST_DIR/sql_pos.py" 1
check "ai-python-sql-injection ignores negative" \
  assert_rule "ai-python-sql-injection" "$TEST_DIR/sql_neg.py" 0

# 8. ssl unverified context
cat > "$TEST_DIR/ssl_pos.py" << 'EOF'
import ssl
ctx = ssl._create_unverified_context()
EOF
cat > "$TEST_DIR/ssl_neg.py" << 'EOF'
import ssl
ctx = ssl.create_default_context()
EOF
check "ai-python-ssl-unverified-context matches positive" \
  assert_rule "ai-python-ssl-unverified-context" "$TEST_DIR/ssl_pos.py" 1
check "ai-python-ssl-unverified-context ignores negative" \
  assert_rule "ai-python-ssl-unverified-context" "$TEST_DIR/ssl_neg.py" 0

echo "==> Testing JavaScript / TypeScript rules"
# 9. eval / Function
cat > "$TEST_DIR/js_eval_pos.js" << 'EOF'
function run(code) {
  eval(code);
}
EOF
cat > "$TEST_DIR/js_eval_neg.js" << 'EOF'
eval("console.log('safe')");
EOF
check "ai-js-eval-function matches positive" \
  assert_rule "ai-js-eval-function" "$TEST_DIR/js_eval_pos.js" 1
check "ai-js-eval-function ignores negative" \
  assert_rule "ai-js-eval-function" "$TEST_DIR/js_eval_neg.js" 0

# 10. child_process.exec
cat > "$TEST_DIR/js_exec_pos.js" << 'EOF'
const child_process = require('child_process');
function run(cmd) {
  child_process.exec(`echo ${cmd}`);
}
EOF
cat > "$TEST_DIR/js_exec_neg.js" << 'EOF'
const child_process = require('child_process');
child_process.exec("ls -la");
EOF
check "ai-js-child-process-exec matches positive" \
  assert_rule "ai-js-child-process-exec" "$TEST_DIR/js_exec_pos.js" 1
check "ai-js-child-process-exec ignores negative" \
  assert_rule "ai-js-child-process-exec" "$TEST_DIR/js_exec_neg.js" 0

# 11. rejectUnauthorized: false
cat > "$TEST_DIR/js_reject_pos.js" << 'EOF'
const opts = { rejectUnauthorized: false };
EOF
cat > "$TEST_DIR/js_reject_neg.js" << 'EOF'
const opts = { rejectUnauthorized: true };
EOF
check "ai-js-reject-unauthorized-false matches positive" \
  assert_rule "ai-js-reject-unauthorized-false" "$TEST_DIR/js_reject_pos.js" 1
check "ai-js-reject-unauthorized-false ignores negative" \
  assert_rule "ai-js-reject-unauthorized-false" "$TEST_DIR/js_reject_neg.js" 0

# 12. NODE_TLS_REJECT_UNAUTHORIZED = 0
cat > "$TEST_DIR/js_env_pos.js" << 'EOF'
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
EOF
cat > "$TEST_DIR/js_env_neg.js" << 'EOF'
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "1";
EOF
check "ai-js-node-tls-reject-unauthorized-env matches positive" \
  assert_rule "ai-js-node-tls-reject-unauthorized-env" "$TEST_DIR/js_env_pos.js" 1
check "ai-js-node-tls-reject-unauthorized-env ignores negative" \
  assert_rule "ai-js-node-tls-reject-unauthorized-env" "$TEST_DIR/js_env_neg.js" 0

# 13. innerHTML dynamic
cat > "$TEST_DIR/js_html_pos.js" << 'EOF'
function update(el, content) {
  el.innerHTML = content;
}
EOF
cat > "$TEST_DIR/js_html_neg.js" << 'EOF'
el.innerHTML = "<div>safe</div>";
EOF
check "ai-js-inner-html matches positive" \
  assert_rule "ai-js-inner-html" "$TEST_DIR/js_html_pos.js" 1
check "ai-js-inner-html ignores negative" \
  assert_rule "ai-js-inner-html" "$TEST_DIR/js_html_neg.js" 0

echo "==> Testing Go rules"
# 14. tls InsecureSkipVerify
cat > "$TEST_DIR/go_pos.go" << 'EOF'
package main
import "crypto/tls"
func main() {
    _ = &tls.Config{InsecureSkipVerify: true}
}
EOF
cat > "$TEST_DIR/go_neg.go" << 'EOF'
package main
import "crypto/tls"
func main() {
    _ = &tls.Config{InsecureSkipVerify: false}
}
EOF
check "ai-go-tls-insecure-skip-verify matches positive" \
  assert_rule "ai-go-tls-insecure-skip-verify" "$TEST_DIR/go_pos.go" 1
check "ai-go-tls-insecure-skip-verify ignores negative" \
  assert_rule "ai-go-tls-insecure-skip-verify" "$TEST_DIR/go_neg.go" 0

echo "==> Testing Bash rules (assembled dynamically)"
# 15. curl/wget pipe shell
printf '%s -fsSL https://example.com/install.sh | %s\n' "$c_bin" "$b_bin" > "$TEST_DIR/bash_pipe_pos.sh"
printf '%s -fsSL https://example.com/file.tar.gz -o file.tar.gz\n' "$c_bin" > "$TEST_DIR/bash_pipe_neg.sh"
check "ai-bash-curl-pipe-shell matches positive" \
  assert_rule "ai-bash-curl-pipe-shell" "$TEST_DIR/bash_pipe_pos.sh" 1
check "ai-bash-curl-pipe-shell ignores negative" \
  assert_rule "ai-bash-curl-pipe-shell" "$TEST_DIR/bash_pipe_neg.sh" 0

# 16. curl/wget insecure
printf '%s %s https://example.com\n' "$c_bin" "$k_flag" > "$TEST_DIR/bash_insec_pos.sh"
printf '%s -fsSL https://example.com\n' "$c_bin" > "$TEST_DIR/bash_insec_neg.sh"
check "ai-bash-insecure-curl-wget matches positive" \
  assert_rule "ai-bash-insecure-curl-wget" "$TEST_DIR/bash_insec_pos.sh" 1
check "ai-bash-insecure-curl-wget ignores negative" \
  assert_rule "ai-bash-insecure-curl-wget" "$TEST_DIR/bash_insec_neg.sh" 0

# 17. chmod 777 / a+rwx
printf '%s %s file.txt\n' "$ch_bin" "$perm_777" > "$TEST_DIR/bash_chmod_pos.sh"
printf '%s +x script.sh\n' "$ch_bin" > "$TEST_DIR/bash_chmod_neg.sh"
check "ai-bash-chmod-777 matches positive" \
  assert_rule "ai-bash-chmod-777" "$TEST_DIR/bash_chmod_pos.sh" 1
check "ai-bash-chmod-777 ignores negative" \
  assert_rule "ai-bash-chmod-777" "$TEST_DIR/bash_chmod_neg.sh" 0

echo
if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST PASSED"
