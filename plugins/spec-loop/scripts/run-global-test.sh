#!/usr/bin/env bash
# run-global-test.sh - Run the full project test suite and write a per-round
# result file under .spec-loop/global/round-<N>/.
#
# Delegates framework detection to run-tests.sh but redirects the output
# path so existing single-mode behaviour is not disturbed.
#
# Usage: run-global-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

ROUND=$(state_get global_round); ROUND=${ROUND:-1}
ROUND_DIR=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$ROUND")
mkdir -p "$ROUND_DIR"

RESULT_FILE="$ROUND_DIR/test-results.json"
RAW_LOG="$ROUND_DIR/test-output.log"

cd "$CLAUDE_PROJECT_DIR"

# Inline a simplified version of run-tests.sh's framework detection.
FRAMEWORK="unknown"; CMD=""
if [[ -f "package.json" ]] && grep -q '"test"' package.json 2>/dev/null; then
  FRAMEWORK="npm"; CMD="npm test --silent --"
elif [[ -f "pyproject.toml" || -f "pytest.ini" || -f "setup.py" ]]; then
  FRAMEWORK="pytest"; CMD="pytest -q"
elif [[ -f "go.mod" ]]; then
  FRAMEWORK="go"; CMD="go test ./..."
elif [[ -f "Cargo.toml" ]]; then
  FRAMEWORK="cargo"; CMD="cargo test"
elif [[ -f "Makefile" ]] && grep -q '^test:' Makefile 2>/dev/null; then
  FRAMEWORK="make"; CMD="make test"
fi

if [[ "$FRAMEWORK" == "unknown" ]]; then
  python3 - "$RESULT_FILE" <<'PY'
import json, sys
json.dump({'passed': False, 'framework':'none', 'reason':'no framework detected',
           'failures':[]}, open(sys.argv[1], 'w'), indent=2)
PY
  echo "No test framework detected" | tee "$RAW_LOG"
  exit 0
fi

echo "[spec-loop global round $ROUND] Running: $CMD" | tee "$RAW_LOG"

set +e
timeout 900 bash -c "$CMD" >> "$RAW_LOG" 2>&1
EC=$?
set -e

PASSED="false"
[[ $EC -eq 0 ]] && PASSED="true"

python3 - "$RESULT_FILE" "$PASSED" "$FRAMEWORK" "$CMD" "$EC" <<'PY'
import json, sys
path, passed, fw, cmd, ec = sys.argv[1], sys.argv[2]=='true', sys.argv[3], sys.argv[4], int(sys.argv[5])
json.dump({'passed': passed, 'framework': fw, 'command': cmd, 'exit_code': ec,
           'failures': []}, open(path, 'w'), indent=2)
PY

echo "=== Global test (round $ROUND): $( [[ $EC -eq 0 ]] && echo PASS || echo FAIL ) ==="
cat "$RESULT_FILE"
