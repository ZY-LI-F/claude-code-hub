#!/usr/bin/env bash
# setup-spec-loop-multi.sh - Initialize .spec-loop/ in multi-task mode.
# Sibling of setup-spec-loop.sh (which stays the legacy single-task entry).
#
# Usage:
#   setup-spec-loop-multi.sh <session_id> <spec_text> [flags...]
#
# Flags (all optional, all override their SPEC_LOOP_* env defaults):
#   --no-review           shorthand for --max-inner=1 --rounds=0
#                         (生成代码后不进行 review/fix 内层迭代，也不做 global review)
#   --rounds=N            global review/fix/test 最大轮次 (default 5)
#   --max-inner=N         单 task 内 implement→review→fix 最大迭代 (default 10)
#   --parallel=N          每 wave 并发 task 上限 (default 3)
#
# Auto-backup: 如检测到 .spec-loop/ 仍含 plan.md/tasks.json/spec.md 但
# state 已为终态 (done/failed/idle)，会先把这三个文件复制到
# .spec-loop.backup-<UTC ts>/ 再 init，避免覆盖丢失。

set -euo pipefail

POSITIONAL=()
FLAG_NO_REVIEW=0
FLAG_ROUNDS=""
FLAG_MAX_INNER=""
FLAG_PARALLEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-review)         FLAG_NO_REVIEW=1; shift ;;
    --rounds=*)          FLAG_ROUNDS="${1#*=}"; shift ;;
    --rounds)            FLAG_ROUNDS="$2"; shift 2 ;;
    --max-inner=*)       FLAG_MAX_INNER="${1#*=}"; shift ;;
    --max-inner)         FLAG_MAX_INNER="$2"; shift 2 ;;
    --parallel=*)        FLAG_PARALLEL="${1#*=}"; shift ;;
    --parallel)          FLAG_PARALLEL="$2"; shift 2 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
SESSION_ID="${POSITIONAL[0]:-}"
SPEC_TEXT="${POSITIONAL[1]:-}"

# 如果 session_id 缺省，回退到 $CLAUDE_SESSION_ID env；再缺省时存空字符串
# 让 stop-hook.session_matches 走"接受任何 session"分支（bootstrap 模式）。
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="${CLAUDE_SESSION_ID:-}"
fi

if (( FLAG_NO_REVIEW )); then
  [[ -z "$FLAG_MAX_INNER" ]] && FLAG_MAX_INNER=1
  [[ -z "$FLAG_ROUNDS"    ]] && FLAG_ROUNDS=0
fi

# Push parsed flags into env so state_init() and downstream scripts pick them up.
[[ -n "$FLAG_ROUNDS"    ]] && export SPEC_LOOP_MAX_GLOBAL_ROUNDS="$FLAG_ROUNDS"
[[ -n "$FLAG_MAX_INNER" ]] && export SPEC_LOOP_MAX_INNER_ITER="$FLAG_MAX_INNER"
[[ -n "$FLAG_PARALLEL"  ]] && export SPEC_LOOP_MAX_PARALLEL="$FLAG_PARALLEL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

if [[ -z "$SPEC_TEXT" ]]; then
  cat >&2 <<EOF
Usage: $0 [<session_id>] <spec_text> [--no-review] [--rounds=N] [--max-inner=N] [--parallel=N]
  session_id 可省略（缺省读 \$CLAUDE_SESSION_ID env；仍空时存空，hook 接受任意 session）。
EOF
  exit 1
fi

# Auto-backup plan/tasks/spec before any potential overwrite. If .spec-loop/
# exists with terminal state, those three files would be silently replaced by
# the new init — back them up so user can recover.
if state_exists && [[ -d "$SPEC_LOOP_DIR" ]]; then
  BK_DIR="${SPEC_LOOP_DIR}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  for f in plan.md tasks.json spec.md state.json; do
    src="$SPEC_LOOP_DIR/$f"
    [[ -f "$src" ]] || continue
    mkdir -p "$BK_DIR"
    cp -p "$src" "$BK_DIR/$f" 2>/dev/null || true
  done
  if [[ -d "$BK_DIR" ]]; then
    echo "[spec-loop] backed up plan/tasks/spec to: $BK_DIR" >&2
  fi
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
  max_inner_iter: ${SPEC_LOOP_MAX_INNER_ITER:-10}
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
