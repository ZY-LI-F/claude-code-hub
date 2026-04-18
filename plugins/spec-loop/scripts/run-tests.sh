#!/usr/bin/env bash
# run-tests.sh - Auto-detect and run the project's test suite
# Writes <outer_dir>/test-results.json with {passed: bool, failures: [...]}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

OUTER_DIR=$(current_outer_dir)
RESULT_FILE="${OUTER_DIR}/test-results.json"
RAW_LOG="${OUTER_DIR}/test-output.log"
mkdir -p "$OUTER_DIR"

cd "$CLAUDE_PROJECT_DIR"

# ---- Framework detection ----
FRAMEWORK="unknown"
CMD=""
if [[ -f "package.json" ]]; then
  if grep -q '"test"' package.json 2>/dev/null; then
    FRAMEWORK="npm"
    CMD="npm test --silent --"
  elif [[ -f "pnpm-lock.yaml" ]]; then
    FRAMEWORK="pnpm"; CMD="pnpm test"
  fi
fi
[[ "$FRAMEWORK" == "unknown" && -f "pyproject.toml" ]] && { FRAMEWORK="pytest"; CMD="pytest -q"; }
[[ "$FRAMEWORK" == "unknown" && -f "pytest.ini" ]] && { FRAMEWORK="pytest"; CMD="pytest -q"; }
[[ "$FRAMEWORK" == "unknown" && -f "setup.py"  ]] && { FRAMEWORK="pytest"; CMD="pytest -q"; }
[[ "$FRAMEWORK" == "unknown" && -f "go.mod"    ]] && { FRAMEWORK="go";     CMD="go test ./..."; }
[[ "$FRAMEWORK" == "unknown" && -f "Cargo.toml" ]] && { FRAMEWORK="cargo"; CMD="cargo test"; }
[[ "$FRAMEWORK" == "unknown" && -f "Makefile"  ]] && grep -q '^test:' Makefile 2>/dev/null && { FRAMEWORK="make"; CMD="make test"; }

if [[ "$FRAMEWORK" == "unknown" ]]; then
  log_warn "No test framework detected; skipping tests"
  # Path comes via argv so we do not shell-interpolate into Python source.
  python3 - "$RESULT_FILE" <<'PY'
import json, sys
json.dump({'passed': False, 'framework': 'none',
           'reason': 'no test framework detected',
           'failures': []},
          open(sys.argv[1], 'w'), indent=2)
PY
  echo "No test framework detected. Looking for: package.json+test script, pyproject.toml, go.mod, Cargo.toml, or Makefile with test target."
  exit 0
fi

log_info "Running tests: framework=$FRAMEWORK cmd=$CMD"
echo "[spec-loop] Running: $CMD" | tee "$RAW_LOG"

set +e
timeout 600 bash -c "$CMD" >> "$RAW_LOG" 2>&1
EXIT_CODE=$?
set -e

PASSED="false"
[[ $EXIT_CODE -eq 0 ]] && PASSED="true"

# Extract failure lines (framework-specific rough heuristics).
# All runtime values pass via argv — no shell interpolation into Python source.
FAILURES_JSON=$(python3 - "$RAW_LOG" "$FRAMEWORK" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        text = f.read()
except Exception:
    text = ""

framework = sys.argv[2]
fails = []
if framework == "pytest":
    fails = re.findall(r'^FAILED\s+(.+)$', text, re.MULTILINE)[:20]
elif framework in ("npm", "pnpm"):
    fails = re.findall(r'^\s*(?:✗|FAIL|AssertionError)\s+(.+)$', text, re.MULTILINE)[:20]
elif framework == "go":
    fails = re.findall(r'^--- FAIL:\s+(.+)$', text, re.MULTILINE)[:20]
elif framework == "cargo":
    fails = re.findall(r'^test\s+(\S+)\s+\.\.\.\s+FAILED', text, re.MULTILINE)[:20]

print(json.dumps(fails))
PY
)

python3 - "$RESULT_FILE" "$PASSED" "$FRAMEWORK" "$CMD" "$EXIT_CODE" "$FAILURES_JSON" "$RAW_LOG" <<'PY'
import json, sys
out, passed, fw, cmd, exit_code, failures_json, log_path = sys.argv[1:8]
json.dump({
    'passed': passed == 'true',
    'framework': fw,
    'command': cmd,
    'exit_code': int(exit_code),
    'failures': json.loads(failures_json),
    'log_path': log_path,
}, open(out, 'w'), indent=2)
PY

log_info "Tests complete: passed=$PASSED exit=$EXIT_CODE"
echo
echo "=== Test Result ==="
cat "$RESULT_FILE"
