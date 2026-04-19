#!/usr/bin/env bash
# spec-status.sh - Mode-aware status snapshot. Replaces the inline bash in
# commands/spec-status.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

if ! state_exists; then
  echo "No active spec-loop in this project."
  exit 0
fi

MODE=$(state_mode)
PHASE=$(state_get phase)
EXIT_REASON=$(state_get exit_reason)

echo "=== spec-loop status ==="
echo "Mode:          $MODE"
echo "Phase:         $PHASE${EXIT_REASON:+ (exit: $EXIT_REASON)}"
echo "Scenario:      $(state_get scenario)"
echo "Updated:       $(state_get updated_at)"

if [[ "$MODE" == "multi" ]]; then
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"
  MAX=$(tasks_max_wave 2>/dev/null || echo 0)
  CUR=$(state_get current_wave); CUR=${CUR:-0}
  GR=$(state_get global_round); GR=${GR:-0}
  MGR=$(state_get max_global_rounds); MGR=${MGR:-5}
  echo "Current wave:  $CUR / $MAX"
  echo "Global round:  $GR / $MGR"
  echo
  echo "=== per-wave progress ==="
  if tasks_exists; then
    for (( w=1; w<=MAX; w++ )); do
      stats=$(tasks_count_in_wave "$w" 2>/dev/null | tr '\n' ' ')
      echo "  wave $w: $stats"
    done
    echo
    echo "=== tasks ==="
    _py3 - "$SPEC_LOOP_TASKS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d.get('tasks', []):
    print(f"  w{t.get('wave','?'):>2} | {t.get('id',''):>4} | {t.get('status','?'):<8} | {t.get('title','')[:60]}")
PY
  fi
else
  echo "Outer iter:   $(state_get outer_iter) / ${SPEC_LOOP_MAX_OUTER_ITER}"
  echo "Inner iter:   $(state_get inner_iter) / ${SPEC_LOOP_MAX_INNER_ITER}"
  echo "Osc. streak:  $(state_get review_hash_streak)"
  echo "Current task: $(state_get current_task)"
fi

echo
echo "=== live codex subprocesses ==="
if command -v tasklist >/dev/null 2>&1; then
  tasklist 2>/dev/null | grep -i codex | awk '{print "  "$1" pid="$2}' | head -5
elif command -v ps >/dev/null 2>&1; then
  ps -ef 2>/dev/null | grep -iE "codex|run-task-loop|run-wave" | grep -v grep | head -5
fi
if [[ -z "$(tasklist 2>/dev/null | grep -i codex)" && -z "$(ps -ef 2>/dev/null | grep -i codex | grep -v grep)" ]]; then
  echo "  (none)"
fi

echo
echo "=== recent log (last 15 lines) ==="
tail -n 15 "${SPEC_LOOP_LOG}" 2>/dev/null || echo "(no log yet)"

if [[ "$MODE" == "multi" ]]; then
  echo
  echo "=== global rounds artifacts ==="
  if [[ -d "$SPEC_LOOP_GLOBAL_DIR" ]]; then
    find "$SPEC_LOOP_GLOBAL_DIR" -maxdepth 2 -type f \( -name "*.md" -o -name "*.json" \) 2>/dev/null | sort | head -20
  fi
fi
