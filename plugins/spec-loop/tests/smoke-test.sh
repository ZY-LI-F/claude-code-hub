#!/usr/bin/env bash
# smoke-test.sh - Verify spec-loop's core wiring without invoking Codex or Claude.
# Runs state-machine transitions manually and checks each script's outputs.
#
# Usage: bash tests/smoke-test.sh
# Exit 0 if all checks pass; non-zero otherwise.

set -uo pipefail

# ---- Colors ----
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
PASS_COUNT=0
FAIL_COUNT=0

# check <desc> <cmd...> - evaluates command, expects exit 0
check() {
  local desc="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    echo -e "  ${GREEN}✓${RESET} $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${RESET} $desc"
    echo -e "${YELLOW}   output:${RESET}"
    printf '%s\n' "$out" | sed 's/^/      /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# check_eq <desc> <actual> <expected>
check_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✓${RESET} $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${RESET} $desc"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# check_file <desc> <path>
check_file() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo -e "  ${GREEN}✓${RESET} $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${RESET} $desc (missing: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# check_exit <desc> <expected_code> <cmd...>
check_exit() {
  local desc="$1" expected="$2"; shift 2
  local rc
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ $rc -eq $expected ]]; then
    echo -e "  ${GREEN}✓${RESET} $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${RESET} $desc (expected exit $expected, got $rc)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---- Setup: fake project dir ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SMOKE_DIR=$(mktemp -d -t spec-loop-smoke.XXXXXX)
trap "rm -rf '$SMOKE_DIR'" EXIT

export CLAUDE_PROJECT_DIR="$SMOKE_DIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export SPEC_LOOP_MAX_INNER_ITER=3
export SPEC_LOOP_MAX_OUTER_ITER=2

cd "$SMOKE_DIR"
git init -q
git config user.email smoke@test.local
git config user.name Smoke
echo "# Smoke" > README.md
git add . && git commit -qm "init"

echo
echo "=== spec-loop smoke test ==="
echo "  Plugin:  $PLUGIN_ROOT"
echo "  Sandbox: $SMOKE_DIR"
echo

# -----------------------------------------------------------
# 1. lib-state.sh sourcing and init
# -----------------------------------------------------------
echo "[1/8] lib-state.sh & state init"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

if ! state_exists; then
  echo -e "  ${GREEN}✓${RESET} state does not exist initially"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${RESET} state already exists"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

state_init "smoke-session-1"
check_file "state_init created state.json" "$SPEC_LOOP_STATE"
check_eq   "session_id is stored" "$(state_get session_id)" "smoke-session-1"
check_eq   "phase defaults to idle" "$(state_get phase)" "idle"

# -----------------------------------------------------------
# 2. Atomic state_set
# -----------------------------------------------------------
echo "[2/8] state_set transitions"
state_set phase implementing inner_iter 0 outer_iter 1
check_eq "phase updated"       "$(state_get phase)"       "implementing"
check_eq "inner_iter updated"  "$(state_get inner_iter)"  "0"
check_eq "outer_iter updated"  "$(state_get outer_iter)"  "1"

# -----------------------------------------------------------
# 3. detect-scenario.sh
# -----------------------------------------------------------
echo "[3/8] scenario detection"
check_eq "CRUD spec → crud" \
  "$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "Add POST /api/users endpoint with validation using http route")" \
  "crud"
check_eq "Algo spec → algorithm" \
  "$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "Write a function that given an array returns the sort order. Handle edge cases.")" \
  "algorithm"
check_eq "Bugfix spec → bugfix" \
  "$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "Fix the bug where login fails with 500 error on empty password and broken session")" \
  "bugfix"
check_eq "Vague spec → generic" \
  "$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "Make the thing better")" \
  "generic"

# -----------------------------------------------------------
# 4. setup-spec-loop.sh end-to-end
# -----------------------------------------------------------
echo "[4/8] setup-spec-loop.sh"
rm -rf "$SPEC_LOOP_DIR"
bash "${PLUGIN_ROOT}/scripts/setup-spec-loop.sh" "smoke-session-2" \
    "Add POST /api/users endpoint with JSON body validation via http route" >/dev/null
check_file "setup created state.json" "$SPEC_LOOP_STATE"
check_file "setup captured spec"      "$SPEC_LOOP_SPEC"
check_eq   "setup detected crud"      "$(state_get scenario)" "crud"
check_eq   "setup phase=planning"     "$(state_get phase)"    "planning"

# -----------------------------------------------------------
# 5. run-tests.sh framework detection (v0.4: review steps removed)
# -----------------------------------------------------------
echo "[5/6] run-tests.sh framework detection"
INNER_DIR="${SPEC_LOOP_ITER_DIR}/outer-001/inner/iter-000"
mkdir -p "$INNER_DIR"
state_set phase testing outer_iter 1 inner_iter 0
OUTER_DIR="${SPEC_LOOP_ITER_DIR}/outer-001"
mkdir -p "$OUTER_DIR"
bash "${PLUGIN_ROOT}/scripts/run-tests.sh" >/dev/null 2>&1 || true
check_file "test-results.json written" "$OUTER_DIR/test-results.json"
FW1=$(_json_field "$OUTER_DIR/test-results.json" framework)
check_eq "framework=none (no project files)" "$FW1" "none"

# Create pyproject + passing test
cat > "$SMOKE_DIR/pyproject.toml" <<'EOF'
[project]
name = "smoke"
version = "0.0.1"
EOF
mkdir -p "$SMOKE_DIR/tests"
cat > "$SMOKE_DIR/tests/test_trivial.py" <<'EOF'
def test_passes():
    assert 1 + 1 == 2
EOF

if command -v pytest >/dev/null 2>&1; then
  bash "${PLUGIN_ROOT}/scripts/run-tests.sh" >/dev/null 2>&1 || true
  FW2=$(_json_field "$OUTER_DIR/test-results.json" framework)
  PASSED=$(_json_field "$OUTER_DIR/test-results.json" passed)
  check_eq "pytest detected"   "$FW2"    "pytest"
  check_eq "tests passed"      "$PASSED" "True"
else
  echo -e "  ${YELLOW}○${RESET} pytest not installed; skipping pytest integration check"
fi

# -----------------------------------------------------------
# 8. check-budget.sh
# -----------------------------------------------------------
echo "[8/8] check-budget.sh"
state_set outer_iter 0 inner_iter 0
check_exit "fresh state: within budget (exit 0)" 0 \
  bash "${PLUGIN_ROOT}/scripts/check-budget.sh"

state_set inner_iter 3   # == max
check_exit "inner exhausted → exit 1" 1 \
  bash "${PLUGIN_ROOT}/scripts/check-budget.sh"

state_set inner_iter 0 outer_iter 2   # == max
check_exit "outer exhausted → exit 2" 2 \
  bash "${PLUGIN_ROOT}/scripts/check-budget.sh"

# -----------------------------------------------------------
# 9. Stop-hook hard brakes (integration test)
# -----------------------------------------------------------
echo "[9/9] stop-hook hard brakes"

# 9a. Inner budget tripwire
state_init "smoke-session-hardbrake"
state_set phase implementing outer_iter 1 inner_iter 3   # inner == MAX_INNER (3)
set +e
echo '{"session_id":"smoke-session-hardbrake","stop_hook_active":false}' \
  | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>/tmp/sl-stderr
RC=$?
set -e
check_exit "inner-budget → hook exit 2" 2 bash -c "exit $RC"
check_eq   "inner-budget → phase=testing"          "$(state_get phase)"       "testing"
check_eq   "inner-budget → exit_reason"            "$(state_get exit_reason)" "inner_budget"

# 9b. Outer budget tripwire (terminal)
state_set phase implementing outer_iter 2 inner_iter 0 exit_reason ""
echo '{"session_id":"smoke-session-hardbrake","stop_hook_active":false}' \
  | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>/tmp/sl-stderr || true
check_eq "outer-budget → phase=failed"             "$(state_get phase)"       "failed"
check_eq "outer-budget → exit_reason"              "$(state_get exit_reason)" "outer_budget"

# 9c. Oscillation tripwire (1-based semantics: streak >= MAX_OSCILLATION_STREAK)
# Smoke test sets MAX_OSCILLATION_STREAK=5 (the default), so streak=5 trips.
export SPEC_LOOP_MAX_OSCILLATION_STREAK=5
state_init "smoke-session-osc"
state_set phase implementing outer_iter 1 inner_iter 1 review_hash_streak 5
set +e
echo '{"session_id":"smoke-session-osc","stop_hook_active":false}' \
  | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>/tmp/sl-stderr
RC=$?
set -e
check_exit "oscillation → hook exit 2" 2 bash -c "exit $RC"
check_eq   "oscillation → phase=testing"           "$(state_get phase)"       "testing"
check_eq   "oscillation → exit_reason"             "$(state_get exit_reason)" "oscillation"

# 9c-bonus: Verify streak below threshold does NOT trip oscillation brake.
state_init "smoke-session-osc-below"
state_set phase implementing outer_iter 1 inner_iter 1 review_hash_streak 4
set +e
echo '{"session_id":"smoke-session-osc-below","stop_hook_active":false}' \
  | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>/tmp/sl-stderr
set -e
OSC_REASON=$(state_get exit_reason)
if [[ "$OSC_REASON" != "oscillation" ]]; then
  echo -e "  ${GREEN}✓${RESET} oscillation-below-threshold → brake NOT tripped (exit_reason='$OSC_REASON')"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${RESET} oscillation-below-threshold → brake erroneously tripped at streak=4"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 9d. Wall-clock tripwire (simulate by backdating created_at)
state_init "smoke-session-wall"
export SPEC_LOOP_MAX_WALL_SECONDS=60
python3 - "$SPEC_LOOP_STATE" <<'PY'
import json, datetime, sys
p = sys.argv[1]
d = json.load(open(p))
past = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=300)
d['created_at'] = past.strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump(d, open(p, 'w'), indent=2)
PY
state_set phase implementing outer_iter 1 inner_iter 0
echo '{"session_id":"smoke-session-wall","stop_hook_active":false}' \
  | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>/tmp/sl-stderr || true
check_eq "wall-clock → phase=failed"               "$(state_get phase)"       "failed"
check_eq "wall-clock → exit_reason"                "$(state_get exit_reason)" "wall_clock_exceeded"
unset SPEC_LOOP_MAX_WALL_SECONDS

# -----------------------------------------------------------
# 10. Security & robustness (new)
# -----------------------------------------------------------
echo "[10/10] security & robustness"

# 10a. Injection: state_set with a value containing single quotes and $(...)
state_init "smoke-injection"
EVIL="hello'; DROP TABLE users; --"
EVIL2='value with $(rm -rf /) and `id` backticks'
state_set current_task "$EVIL"
check_eq "single-quote injection survives round-trip" "$(state_get current_task)" "$EVIL"
state_set scenario "$EVIL2"
check_eq "\$() and backticks survive round-trip" "$(state_get scenario)" "$EVIL2"
# Verify no side effect (would crash before fix)
check_file "state.json still valid JSON" "$SPEC_LOOP_STATE"
if python3 - "$SPEC_LOOP_STATE" <<'PY'
import json, sys
json.load(open(sys.argv[1]))
PY
then
  echo -e "  ${GREEN}✓${RESET} state.json parseable after injection attempts"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${RESET} state.json corrupted after injection"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# (v0.4: removed 10b large-diff-cap, 10c heredoc-exec safety, which exercised
#  run-codex-review.sh. The script was deleted in v0.4 — review is now
#  slice-based and lives in run-global-review.sh.)

# 10d. Testing-phase nudge counter: N+1 stops with no tests → phase=failed
state_init "smoke-stuck"
# Clean any residue from earlier tests (e.g. test 7 wrote test-results.json here)
rm -rf "${SPEC_LOOP_ITER_DIR}/outer-001"
mkdir -p "${SPEC_LOOP_ITER_DIR}/outer-001"
state_set phase testing outer_iter 1 inner_iter 0
export SPEC_LOOP_MAX_TESTING_NUDGES=3
for i in 1 2 3 4; do
  echo '{"session_id":"smoke-stuck","stop_hook_active":false}' \
    | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>&1 || true
done
check_eq "stuck-testing → phase=failed"        "$(state_get phase)"       "failed"
check_eq "stuck-testing → exit_reason"         "$(state_get exit_reason)" "stuck_in_testing"
unset SPEC_LOOP_MAX_TESTING_NUDGES

# 10e. Replan clears streak (test-driven outer-iter transition resets oscillation counters)
state_init "smoke-replan"
TEST_OUTER="${SPEC_LOOP_ITER_DIR}/outer-001"
mkdir -p "$TEST_OUTER"
echo '{"passed": false, "framework": "pytest", "failures": ["t1"]}' > "$TEST_OUTER/test-results.json"
state_set phase testing outer_iter 1 inner_iter 0 review_hash_streak 4 last_review_hash "abcd1234"
echo '{"session_id":"smoke-replan","stop_hook_active":false}' \
  | bash "${PLUGIN_ROOT}/hooks/stop-hook.sh" >/dev/null 2>&1 || true
check_eq "replan: outer_iter incremented"   "$(state_get outer_iter)"          "2"
check_eq "replan: phase=planning"           "$(state_get phase)"               "planning"
check_eq "replan: review_hash_streak reset" "$(state_get review_hash_streak)"  "0"
check_eq "replan: last_review_hash reset"   "$(state_get last_review_hash)"    ""

# 10f. detect-scenario.sh word-boundary (no false positives on "prefix" / "apache")
check_eq "word-boundary: 'prefix' does NOT match 'fix'" \
  "$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "Add prefix validation to input")" \
  "generic"
check_eq "word-boundary: 'apache' does NOT match 'api'" \
  "$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "Configure apache web server")" \
  "generic"

# -----------------------------------------------------------
# Summary
# -----------------------------------------------------------
echo
echo "=========================================="
echo -e "  ${GREEN}Passed: $PASS_COUNT${RESET}"
if (( FAIL_COUNT > 0 )); then
  echo -e "  ${RED}Failed: $FAIL_COUNT${RESET}"
else
  echo -e "  ${GREEN}Failed: $FAIL_COUNT${RESET}"
fi
echo "=========================================="

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
