#!/usr/bin/env bash
# check-budget.sh - Enforce iteration/time budgets
# Usage: check-budget.sh
# Exit codes:
#   0 = within budget
#   1 = inner iter budget exhausted (escalate to L1)
#   2 = outer iter budget exhausted (abort)
#   3 = wall-clock budget exhausted (abort)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

state_exists || { echo "no active loop"; exit 0; }

OUTER=$(state_get outer_iter); OUTER=${OUTER:-0}
INNER=$(state_get inner_iter); INNER=${INNER:-0}
CREATED=$(state_get created_at)

# Wall-clock budget (default 18000s = 5 hours; see lib-state.sh)
: "${SPEC_LOOP_MAX_WALL_SECONDS:=18000}"

if [[ -n "$CREATED" ]]; then
  # Pass timestamp via argv and force UTC on the parsed datetime so `.timestamp()`
  # does not silently assume local time (which would skew ELAPSED by the TZ offset).
  CREATED_EPOCH=$(python3 - "$CREATED" <<'PY'
import sys, datetime
try:
    s = sys.argv[1]
    dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print(0)
PY
)
  NOW_EPOCH=$(date -u +%s)
  ELAPSED=$((NOW_EPOCH - CREATED_EPOCH))
  if (( CREATED_EPOCH > 0 && ELAPSED > SPEC_LOOP_MAX_WALL_SECONDS )); then
    echo "wall-clock budget exceeded: ${ELAPSED}s > ${SPEC_LOOP_MAX_WALL_SECONDS}s"
    exit 3
  fi
fi

if (( OUTER >= SPEC_LOOP_MAX_OUTER_ITER )); then
  echo "outer budget exhausted: $OUTER >= $SPEC_LOOP_MAX_OUTER_ITER"
  exit 2
fi

if (( INNER >= SPEC_LOOP_MAX_INNER_ITER )); then
  echo "inner budget exhausted: $INNER >= $SPEC_LOOP_MAX_INNER_ITER"
  exit 1
fi

echo "within budget: outer=$OUTER/$SPEC_LOOP_MAX_OUTER_ITER inner=$INNER/$SPEC_LOOP_MAX_INNER_ITER"
exit 0
