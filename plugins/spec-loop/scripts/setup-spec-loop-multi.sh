#!/usr/bin/env bash
# setup-spec-loop-multi.sh - Initialize .spec-loop/ in multi-task mode.
# Sibling of setup-spec-loop.sh (which stays the legacy single-task entry).
#
# Usage: setup-spec-loop-multi.sh <session_id> <spec_text>

set -euo pipefail

SESSION_ID="${1:-}"
SPEC_TEXT="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

if [[ -z "$SESSION_ID" || -z "$SPEC_TEXT" ]]; then
  echo "Usage: $0 <session_id> <spec_text>" >&2
  exit 1
fi

if state_exists; then
  EXISTING_PHASE=$(state_get phase)
  if [[ "$EXISTING_PHASE" != "done" && "$EXISTING_PHASE" != "failed" && "$EXISTING_PHASE" != "idle" ]]; then
    cat >&2 <<EOF
[spec-loop] A spec-loop is already active (phase=$EXISTING_PHASE).
Run /spec-loop:spec-cancel first, or /spec-loop:spec-status to see progress.
EOF
    exit 1
  fi
fi

state_init "$SESSION_ID" multi

# Record the base commit for multi_base_commit (used by global review diff)
BASE=$(cd "$CLAUDE_PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "")
[[ -n "$BASE" ]] && state_set multi_base_commit "$BASE"

# Persist spec
atomic_write "$SPEC_LOOP_SPEC" "$SPEC_TEXT"

# Scenario detection (reuse existing helper)
SCENARIO="generic"
if [[ -x "${PLUGIN_ROOT}/scripts/detect-scenario.sh" ]]; then
  SCENARIO=$(bash "${PLUGIN_ROOT}/scripts/detect-scenario.sh" "$SPEC_TEXT" 2>/dev/null || echo "generic")
fi
state_set scenario "$SCENARIO"

# Transition to task-planning: Claude will now run requirements-analyst + batch-planner
state_set phase task-planning

# Initialize empty tasks.json skeleton (batch-planner will populate it)
tasks_init_empty

mkdir -p "$SPEC_LOOP_BATCHES_DIR" "$SPEC_LOOP_GLOBAL_DIR"

# v0.4: intent-to-add untracked files so subsequent `git diff HEAD` snapshots
# see them (fixes the long-standing "BLOCKING: file X not implemented" false
# positives that made per-task review useless in v0.2/v0.3).
( cd "$CLAUDE_PROJECT_DIR" && git add -N -A -- ':!.spec-loop' 2>/dev/null ) || true

log_info "setup-spec-loop-multi: session=$SESSION_ID scenario=$SCENARIO base=$BASE"
cat <<EOF
[spec-loop] multi-mode initialized.
  session: $SESSION_ID
  scenario: $SCENARIO
  mode: multi
  max_parallel: ${SPEC_LOOP_MAX_PARALLEL:-3}
  max_global_rounds: ${SPEC_LOOP_MAX_GLOBAL_ROUNDS:-5}
  base_commit: ${BASE:-<none>}
  spec: $SPEC_LOOP_SPEC
  tasks: $SPEC_LOOP_TASKS
  state: $SPEC_LOOP_STATE

Next:
  1. Consult requirements-analyst to write plan.md
  2. Consult batch-planner to populate tasks.json + run compute-waves.sh
  3. Set phase=wave-running and invoke run-wave.sh for wave 1
EOF
