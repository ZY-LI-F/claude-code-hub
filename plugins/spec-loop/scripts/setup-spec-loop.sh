#!/usr/bin/env bash
# setup-spec-loop.sh - Initialize a spec-loop session
# Usage: setup-spec-loop.sh <session_id> <spec_text>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

SESSION_ID="${1:-}"
SPEC_TEXT="${2:-}"

if [[ -z "$SESSION_ID" || -z "$SPEC_TEXT" ]]; then
  echo "Usage: $0 <session_id> <spec_text>" >&2
  exit 1
fi

if state_exists; then
  EXISTING_PHASE=$(state_get phase)
  if [[ "$EXISTING_PHASE" != "done" && "$EXISTING_PHASE" != "failed" && "$EXISTING_PHASE" != "idle" ]]; then
    cat >&2 <<EOF
[spec-loop] A spec-loop is already active (phase=$EXISTING_PHASE).
Run /spec-cancel first, or /spec-status to see progress.
EOF
    exit 1
  fi
fi

# Fresh init
state_init "$SESSION_ID"

# Persist spec
atomic_write "$SPEC_LOOP_SPEC" "$SPEC_TEXT"

# Detect scenario (P4)
SCENARIO="generic"
if [[ -x "${PLUGIN_ROOT}/scripts/detect-scenario.sh" ]]; then
  SCENARIO=$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "$SPEC_TEXT" 2>/dev/null || echo "generic")
fi

# Move to planning phase
state_set phase planning scenario "$SCENARIO" outer_iter 1 inner_iter 0

# Initial outer iter dir
mkdir -p "$(current_outer_dir)"

log_info "Spec-loop initialized: session=$SESSION_ID scenario=$SCENARIO"

cat <<EOF
✓ spec-loop initialized
  session: $SESSION_ID
  scenario: $SCENARIO
  spec: $SPEC_LOOP_SPEC
  state: $SPEC_LOOP_STATE
EOF
