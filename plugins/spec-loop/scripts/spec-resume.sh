#!/usr/bin/env bash
# spec-resume.sh - Re-enter a paused / failed-due-to-safety-rail spec-loop.
# Resets the wall-clock origin and, for multi mode, computes the first
# non-terminal wave/round and puts phase back on the happy path.
#
# Does NOT:
#  - restart already-done waves
#  - re-merge already-merged branches
#  - reset task statuses

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

if ! state_exists; then
  echo "spec-resume: no .spec-loop/ here" >&2
  exit 1
fi

PHASE=$(state_get phase)
MODE=$(state_mode)
EXIT_REASON=$(state_get exit_reason)

NEW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
state_set created_at "$NEW_TS" exit_reason "" testing_phase_nudges 0

if [[ "$MODE" != "multi" ]]; then
  # Single-task mode: clear failed/done to the previous live phase guess.
  if [[ "$PHASE" == "failed" ]]; then
    state_set phase implementing
    echo "[spec-resume] single-mode: phase failed -> implementing (wall clock reset)"
  else
    echo "[spec-resume] single-mode: phase=$PHASE (clock reset only)"
  fi
  exit 0
fi

# Multi mode: find the first non-terminal wave.
if ! tasks_exists; then
  echo "spec-resume: tasks.json missing; cannot compute resume point" >&2
  exit 1
fi

MAX_WAVE=$(tasks_max_wave)
FIRST_NON_TERMINAL=0
for (( w=1; w<=MAX_WAVE; w++ )); do
  stats=$(tasks_count_in_wave "$w")
  done_c=$(echo "$stats" | awk -F= '/^done=/{print $2}')
  failed_c=$(echo "$stats" | awk -F= '/^failed=/{print $2}')
  total=$(echo "$stats" | awk -F= '{sum+=$2} END{print sum}')
  if (( done_c + failed_c < total )); then
    FIRST_NON_TERMINAL=$w
    break
  fi
done

if (( FIRST_NON_TERMINAL == 0 )); then
  # All waves terminal; resume into whatever global phase we were in.
  case "$PHASE" in
    failed|done)
      # If a decision.json at the current round is accept, go to testing;
      # else go to review.
      ROUND=$(state_get global_round); ROUND=${ROUND:-1}
      (( ROUND < 1 )) && ROUND=1
      RD=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$ROUND")
      if [[ -f "$RD/test-results.json" ]]; then
        passed=$(_py3 -c 'import json,sys; print("y" if json.load(open(sys.argv[1])).get("passed") else "n")' "$RD/test-results.json")
        if [[ "$passed" == "y" ]]; then
          state_set phase done
          echo "[spec-resume] global round $ROUND already passed → phase=done"
          exit 0
        else
          NEXT=$((ROUND + 1))
          state_set phase global-review global_round "$NEXT"
          echo "[spec-resume] global round $ROUND tests failed → next round=$NEXT (global-review)"
          exit 0
        fi
      elif [[ -f "$RD/decision.json" ]]; then
        action=$(_py3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("action","fix"))' "$RD/decision.json")
        case "$action" in
          accept) state_set phase global-testing; echo "[spec-resume] decision=accept → global-testing" ;;
          fix) state_set phase global-fixing; echo "[spec-resume] decision=fix → global-fixing" ;;
          fail) state_set phase failed; echo "[spec-resume] decision=fail → failed (terminal)" ;;
          *) state_set phase global-review; echo "[spec-resume] unknown action → global-review" ;;
        esac
      else
        state_set phase global-review global_round "${ROUND:-1}"
        echo "[spec-resume] no global artifacts for round $ROUND → global-review"
      fi
      ;;
    *)
      state_set phase "$PHASE"
      echo "[spec-resume] in $PHASE already, clock reset only"
      ;;
  esac
else
  state_set phase wave-running current_wave "$FIRST_NON_TERMINAL"
  echo "[spec-resume] resume point: wave $FIRST_NON_TERMINAL"
  echo "Next: bash \"${PLUGIN_ROOT}/scripts/run-wave.sh\" $FIRST_NON_TERMINAL"
fi
