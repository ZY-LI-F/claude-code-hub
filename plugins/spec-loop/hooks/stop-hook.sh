#!/usr/bin/env bash
# stop-hook.sh - L2 inner loop engine for spec-loop
#
# Fires when Claude Code is about to stop. Reads state, dispatches phase,
# decides exit 0 (allow stop) vs exit 2 (block with stderr feedback to Claude).

set -euo pipefail

# ---- Locate plugin root ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${CLAUDE_PLUGIN_ROOT:=$PLUGIN_ROOT}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

# ---- Helper functions (avoid heredoc-in-$()-with-|| parse issues) ----

# Extract a field from a JSON string on stdin. Prints empty on error.
json_field_from_stdin() {
  local field="$1"
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get(sys.argv[1], "")
    if isinstance(v, bool):
        print("True" if v else "False")
    else:
        print(v)
except Exception:
    pass
' "$field" 2>/dev/null || true
}

# Parse ISO-8601 timestamp to epoch. Prints 0 on error.
iso_to_epoch() {
  python3 -c '
import sys, datetime
try:
    s = sys.argv[1]
    dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print(0)
' "$1" 2>/dev/null || echo 0
}

# Read a boolean field from a JSON file. Prints "true" or "false".
json_bool_field() {
  local path="$1" field="$2"
  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print("true" if d.get(sys.argv[2], False) else "false")
except Exception:
    print("false")
' "$path" "$field" 2>/dev/null || echo "false"
}

# ---- Read hook input ----
HOOK_INPUT="$(cat || true)"
INCOMING_SESSION=$(printf '%s' "$HOOK_INPUT" | json_field_from_stdin session_id)
STOP_HOOK_ACTIVE=$(printf '%s' "$HOOK_INPUT" | json_field_from_stdin stop_hook_active)

# No state file → nothing to do
state_exists || exit 0

# Session mismatch → don't interfere with other Claude Code sessions
if ! session_matches "$INCOMING_SESSION"; then
  log_info "stop-hook: session mismatch ($INCOMING_SESSION); allowing exit"
  exit 0
fi

# stop_hook_active guard: don't re-block if Claude Code has already forced past us
if [[ "$STOP_HOOK_ACTIVE" == "True" || "$STOP_HOOK_ACTIVE" == "true" ]]; then
  log_warn "stop-hook: stop_hook_active=true, allowing exit to avoid runaway"
  exit 0
fi

# ---- Dispatch state ----
PHASE=$(state_get phase)
OUTER=$(state_get outer_iter); OUTER=${OUTER:-0}
INNER=$(state_get inner_iter); INNER=${INNER:-0}
log_info "stop-hook: phase=$PHASE outer=$OUTER inner=$INNER"

# ============================================================
# Hard budget checks (4 layers, in order of severity)
# ============================================================

# ---- Layer 1: Wall-clock budget (terminal) ----
: "${SPEC_LOOP_MAX_WALL_SECONDS:=18000}"
CREATED=$(state_get created_at)
if [[ -n "$CREATED" ]]; then
  CREATED_EPOCH=$(iso_to_epoch "$CREATED")
  NOW_EPOCH=$(date -u +%s)
  ELAPSED=$((NOW_EPOCH - CREATED_EPOCH))
  if (( CREATED_EPOCH > 0 && ELAPSED > SPEC_LOOP_MAX_WALL_SECONDS )); then
    log_error "Wall-clock budget exceeded: ${ELAPSED}s > ${SPEC_LOOP_MAX_WALL_SECONDS}s"
    state_set phase failed exit_reason "wall_clock_exceeded"
    cat >&2 <<EOF
[spec-loop] ⏱  Wall-clock budget exceeded (${ELAPSED}s > ${SPEC_LOOP_MAX_WALL_SECONDS}s).
Loop terminated. State: .spec-loop/state.json (phase=failed, exit_reason=wall_clock_exceeded)
See .spec-loop/spec-loop.log and .spec-loop/iterations/ for execution trace.
EOF
    exit 0
  fi
fi

# ---- Layer 2: Oscillation (escalates to L1 testing) ----
STREAK=$(state_get review_hash_streak); STREAK=${STREAK:-0}
: "${SPEC_LOOP_MAX_OSCILLATION_STREAK:=5}"
if (( STREAK >= SPEC_LOOP_MAX_OSCILLATION_STREAK )); then
  log_warn "Oscillation streak=$STREAK >= threshold=${SPEC_LOOP_MAX_OSCILLATION_STREAK}; forcing L1"
  state_set phase testing \
            inner_iter 0 \
            review_hash_streak 0 \
            last_review_hash "" \
            testing_phase_nudges 0 \
            exit_reason "oscillation"
  cat >&2 <<EOF
[spec-loop] 🔁 Oscillation detected ($STREAK consecutive reviews with identical issues).
L2 inner loop cannot make progress on this task. Forcing L1 test gate.
Please run: bash ${PLUGIN_ROOT}/scripts/run-tests.sh
If tests also fail, the outer loop will replan with this evidence.
EOF
  exit 2
fi

# ---- Layer 3: Inner iteration cap (escalates to L1 testing) ----
if (( INNER >= SPEC_LOOP_MAX_INNER_ITER )); then
  log_warn "Inner iteration limit reached ($SPEC_LOOP_MAX_INNER_ITER); forcing L1"
  state_set phase testing \
            inner_iter 0 \
            review_hash_streak 0 \
            last_review_hash "" \
            testing_phase_nudges 0 \
            exit_reason "inner_budget"
  cat >&2 <<EOF
[spec-loop] 🛑 Inner loop hit MAX_INNER_ITER=${SPEC_LOOP_MAX_INNER_ITER}.
Transitioning to L1 outer loop: please run the test suite now.
  bash ${PLUGIN_ROOT}/scripts/run-tests.sh
EOF
  exit 2
fi

# ---- Layer 4: Outer iteration cap (terminal) ----
if (( OUTER >= SPEC_LOOP_MAX_OUTER_ITER )); then
  log_error "Outer iteration limit reached ($SPEC_LOOP_MAX_OUTER_ITER); giving up"
  state_set phase failed exit_reason "outer_budget"
  cat >&2 <<EOF
[spec-loop] 🚫 Outer loop hit MAX_OUTER_ITER=${SPEC_LOOP_MAX_OUTER_ITER}.
Loop terminated after $OUTER test-driven replans. Human intervention required.
Final state: .spec-loop/state.json (phase=failed, exit_reason=outer_budget)
Review execution trace:  ls -1 .spec-loop/iterations/
EOF
  exit 0
fi

# ============================================================
# Mode dispatch (v0.2)
# ============================================================
MODE=$(state_mode)
log_info "stop-hook: mode=$MODE"
if [[ "$MODE" == "multi" ]]; then
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/hooks/stop-hook-multi.sh"
  _multi_phase_machine
  exit $?
fi

# ============================================================
# Phase machine (single-task legacy, unchanged)
# ============================================================
case "$PHASE" in
  idle)
    exit 0
    ;;

  implementing)
    # v0.4: tests-first. After codex impl finishes we go directly to L1
    # testing — no separate reviewing / addressing phase, no codex review
    # step. Run-tests.sh is the gate; a failing suite triggers a replan.
    ensure_inner_dir
    log_info "Phase=implementing -> transitioning to L1 testing"
    state_set phase testing testing_phase_nudges 0
    cat >&2 <<EOF
[spec-loop L2] Implementation complete. Next: run the test gate.
  bash ${PLUGIN_ROOT}/scripts/run-tests.sh
EOF
    exit 2
    ;;

  testing)
    OUTER_DIR=$(current_outer_dir)
    TEST_FILE="${OUTER_DIR}/test-results.json"

    if [[ ! -f "$TEST_FILE" ]]; then
      # Nudge counter prevents "tell Claude to run tests → Claude stops without
      # running them → repeat" death spiral from silently burning budget.
      NUDGES=$(state_get testing_phase_nudges); NUDGES=${NUDGES:-0}
      NUDGES=$((NUDGES + 1))
      state_set testing_phase_nudges "$NUDGES"
      : "${SPEC_LOOP_MAX_TESTING_NUDGES:=3}"

      if (( NUDGES > SPEC_LOOP_MAX_TESTING_NUDGES )); then
        log_error "Stuck in testing phase: $NUDGES nudges without tests executing"
        state_set phase failed exit_reason "stuck_in_testing"
        cat >&2 <<EOF
[spec-loop] 🚫 Stuck in testing phase: nudged $NUDGES times and tests still haven't run.
Loop cannot progress without test evidence. Terminating.
State: phase=failed, exit_reason=stuck_in_testing
To resume: run tests manually and restart the loop, or /spec-cancel + /spec-start.
EOF
        exit 0
      fi

      cat >&2 <<EOF
[spec-loop L1] Tests haven't run yet for outer iter $OUTER (nudge ${NUDGES}/${SPEC_LOOP_MAX_TESTING_NUDGES}).
Please run: bash ${PLUGIN_ROOT}/scripts/run-tests.sh
EOF
      exit 2
    fi

    # Tests have run — reset nudge counter
    state_set testing_phase_nudges 0

    PASSED=$(json_bool_field "$TEST_FILE" passed)

    if [[ "$PASSED" == "true" ]]; then
      log_info "All tests pass! Loop complete."
      state_set phase done
      cat >&2 <<EOF
[spec-loop] ✓ All tests passed. Spec-loop complete at outer_iter=$OUTER, inner_iter=$INNER.
Summary: ${SPEC_LOOP_DIR}/state.json
EOF
      exit 0
    else
      NEXT_OUTER=$((OUTER + 1))
      log_warn "Tests failed. Starting outer iter=$NEXT_OUTER (replan)"
      state_set phase planning \
                outer_iter "$NEXT_OUTER" \
                inner_iter 0 \
                review_hash_streak 0 \
                last_review_hash "" \
                testing_phase_nudges 0
      cat >&2 <<EOF
[spec-loop L1] Tests failed at outer iter $OUTER.
Starting outer iter $NEXT_OUTER: please replan based on test failures.
Failures: ${TEST_FILE}
Use the \`requirements-analyst\` agent to incorporate failure evidence into plan.md,
then set phase=implementing to start the next L2 loop.
EOF
      exit 2
    fi
    ;;

  planning)
    cat >&2 <<EOF
[spec-loop] Still in planning phase. When plan.md is ready, set phase=implementing:
  bash -c 'source "${PLUGIN_ROOT}/scripts/lib-state.sh" && state_set phase implementing'
EOF
    exit 2
    ;;

  done|failed)
    exit 0
    ;;

  *)
    log_warn "Unknown phase: $PHASE; allowing exit"
    exit 0
    ;;
esac
