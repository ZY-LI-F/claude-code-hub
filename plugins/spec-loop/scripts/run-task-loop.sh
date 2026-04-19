#!/usr/bin/env bash
# run-task-loop.sh - Self-driving L2 loop for a single task in multi mode.
# Invokes codex for implement -> review -> fix -> test until the task
# converges or hits the inner-iteration cap. Designed to be run in parallel
# for multiple tasks (one subprocess per task, each in its own cwd).
#
# Usage: run-task-loop.sh <task_id>
#
# Reads from tasks.json:
#   - task_md       path to the task specification
#   - test_command  shell command used to validate task (optional)
#   - worktree      cwd for codex (falls back to CLAUDE_PROJECT_DIR)
#
# Writes under $(task_dir <task_id>):
#   task-state.json      {iter, status, ...}
#   iter-000/
#     impl-prompt.md, codex-impl.log, diff.patch
#     review-prompt.md, codex-review.md
#     test-output.log, test-results.json
#   iter-001/...
#
# Exit codes: 0 = task done, 1 = task failed (exhausted budget or error).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

TASK_ID="${1:?task_id required}"
MAX_INNER="${SPEC_LOOP_MAX_INNER_ITER:-10}"
TIMEOUT_SEC="${SPEC_LOOP_TASK_TIMEOUT_SECONDS:-1800}"
DIFF_CAP="${SPEC_LOOP_MAX_DIFF_BYTES:-204800}"

TASK_MD=$(tasks_get_field "$TASK_ID" task_md)
TEST_CMD=$(tasks_get_field "$TASK_ID" test_command)
WORKTREE=$(tasks_get_field "$TASK_ID" worktree)
CWD="${WORKTREE:-$CLAUDE_PROJECT_DIR}"
TASK_DIR=$(task_dir "$TASK_ID")

if [[ -z "$TASK_MD" || ! -f "$TASK_MD" ]]; then
  log_error "run-task-loop[$TASK_ID]: task.md missing ($TASK_MD)"
  tasks_append_error "$TASK_ID" "task.md missing: $TASK_MD"
  tasks_update "$TASK_ID" status failed
  exit 1
fi

mkdir -p "$TASK_DIR"
TASK_STATE="$TASK_DIR/task-state.json"

# Lazy init per-task state
if [[ ! -f "$TASK_STATE" ]]; then
  python3 - "$TASK_STATE" "$TASK_ID" <<'PY'
import json, sys, datetime
path, tid = sys.argv[1], sys.argv[2]
d = {"id": tid, "iter": 0, "status": "running",
     "created_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
with open(path, 'w') as f: json.dump(d, f, indent=2)
PY
fi

_task_state_set() {
  python3 - "$TASK_STATE" "$@" <<'PY'
import json, sys, datetime
path = sys.argv[1]; kv = sys.argv[2:]
with open(path) as f: d = json.load(f)
for i in range(0, len(kv), 2):
    k, v = kv[i], kv[i+1]
    try: v = int(v)
    except ValueError: pass
    d[k] = v
d['updated_at'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(path, 'w') as f: json.dump(d, f, indent=2)
PY
}

_run_codex() {
  # Usage: _run_codex <prompt_file> <log_file>
  local prompt="$1" log="$2"
  if ! command -v codex >/dev/null 2>&1; then
    echo "codex CLI not installed" >&2
    return 127
  fi
  ( cd "$CWD" && timeout "$TIMEOUT_SEC" bash -c "codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - < '$prompt'" ) > "$log" 2>&1
}

_build_impl_prompt() {
  local iter_dir="$1" prev_review="$2"
  cat > "$iter_dir/impl-prompt.md" <<EOF
# Task Implementation (multi-task mode)

You are implementing a single task in a parallel batch. Other tasks run in other
git worktrees; you MUST only touch files relevant to this task.

## Working directory

\`$CWD\`

## Task specification

$(cat "$TASK_MD")

## Previous review (if any)

$(if [[ -n "$prev_review" ]]; then echo "$prev_review"; else echo "(first iteration)"; fi)

## Rules
- Make only the minimum changes needed.
- Add or update tests so the acceptance criteria are covered.
- **Do** \`git add\` + \`git commit -m "[spec-loop] $TASK_ID: <short msg>"\` at the end.
- **Do NOT** modify files under \`.spec-loop/\`.
- If blocked, write a short note to \`$iter_dir/impl-blockers.md\` and exit.
EOF
}

_build_fix_prompt() {
  # v0.4: fix prompt uses the task's test-output.log as the ONLY context,
  # not a codex review. Tests are the truth source; a reviewer LLM rephrasing
  # failures just adds latency + false positives (see POST-MORTEM-v0.2.md B1/B2).
  local iter_dir="$1" prev_test_log="$2"
  local test_body
  test_body=$(head -c 50000 "$prev_test_log" 2>/dev/null || echo "(no prior test output)")
  cat > "$iter_dir/impl-prompt.md" <<EOF
# Task Fix Iteration

Same working directory / task as before. The previous attempt's tests
FAILED. Read the test output below, identify the root cause, and fix it.
Keep changes minimal — do not refactor unrelated code.

## Task

$(cat "$TASK_MD")

## Prior test output (truncated to 50 KB if longer)

\`\`\`
$test_body
\`\`\`

## Rules
- Make only the changes needed to make those tests pass.
- Commit with message prefix \`[spec-loop] $TASK_ID fix: ...\`.
- **Do NOT** edit \`.spec-loop/\` files.
EOF
}

# ---- Main loop ----
ITER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("iter",0))' "$TASK_STATE" | tr -d '\r')
ITER=${ITER:-0}

while (( ITER < MAX_INNER )); do
  ITER_DIR="$TASK_DIR/iter-$(printf '%03d' "$ITER")"
  mkdir -p "$ITER_DIR"
  _task_state_set iter "$ITER" status running

  # ---- Step 1: implement / fix ----
  PREV_ITER=$((ITER - 1))
  PREV_TEST_LOG="$TASK_DIR/iter-$(printf '%03d' "$PREV_ITER")/test-output.log"
  if (( ITER == 0 )); then
    _build_impl_prompt "$ITER_DIR" ""
  elif [[ -f "$PREV_TEST_LOG" ]]; then
    _build_fix_prompt "$ITER_DIR" "$PREV_TEST_LOG"
  else
    _build_impl_prompt "$ITER_DIR" ""
  fi

  _run_codex "$ITER_DIR/impl-prompt.md" "$ITER_DIR/codex-impl.log"
  CODEX_RC=$?
  # Multi-signal done check (v0.3): codex exec non-zero exit can still mean
  # progress if it produced commits (timeout hits right after the final
  # commit is a common failure mode). Only mark failed if there are *zero*
  # new commits on the task branch AND the working tree has no staged
  # changes.
  if [[ "$CODEX_RC" -ne 0 ]]; then
    local_commits=$( ( cd "$CWD" && git rev-list --count HEAD ^"$(git merge-base HEAD HEAD@{1} 2>/dev/null || echo HEAD)" 2>/dev/null ) || echo 0 )
    base_hash=""
    # Try to detect the branch's fork point from the main line
    base_hash=$( cd "$CWD" && git log --pretty=%H -1 --grep='^\[spec-loop\] T[0-9]' --invert-grep 2>/dev/null | head -1 )
    [[ -z "$base_hash" ]] && base_hash=$( cd "$CWD" && git rev-list --max-parents=0 HEAD | head -1 )
    new_commits=$( cd "$CWD" && git rev-list --count "${base_hash}..HEAD" 2>/dev/null || echo 0 )
    has_dirty=$( cd "$CWD" && git status --porcelain 2>/dev/null | head -1 )
    if (( new_commits > 0 )) || [[ -n "$has_dirty" ]]; then
      log_warn "run-task-loop[$TASK_ID] iter=$ITER: codex rc=$CODEX_RC but new_commits=$new_commits dirty=$([[ -n $has_dirty ]] && echo yes || echo no); continuing"
    else
      log_error "run-task-loop[$TASK_ID] iter=$ITER: codex implement failed with no commits"
      tasks_append_error "$TASK_ID" "codex implement failed at iter=$ITER (rc=$CODEX_RC, no commits)"
      _task_state_set status failed last_error "codex_implement_failed"
      tasks_update "$TASK_ID" status failed
      exit 1
    fi
  fi

  # Capture the diff for the record
  ( cd "$CWD" && git diff HEAD~1..HEAD 2>/dev/null || git diff HEAD 2>/dev/null ) > "$ITER_DIR/diff.patch" || true

  # ---- Step 2: test — the only convergence signal (v0.4) ----
  if [[ -z "$TEST_CMD" ]]; then
    # No test command configured — codex finished, assume done.
    log_info "run-task-loop[$TASK_ID] iter=$ITER: no test command; codex done -> task done"
    _task_state_set status done
    tasks_update "$TASK_ID" status done inner_iter "$ITER" completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit 0
  fi

  ( cd "$CWD" && timeout "$TIMEOUT_SEC" bash -c "$TEST_CMD" ) > "$ITER_DIR/test-output.log" 2>&1
  TRC=$?
  python3 - "$ITER_DIR/test-results.json" "$TRC" "$TEST_CMD" <<'PY'
import json, sys
path, rc, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
json.dump({"passed": rc == 0, "exit_code": rc, "command": cmd}, open(path, 'w'), indent=2)
PY

  if (( TRC == 0 )); then
    log_info "run-task-loop[$TASK_ID] iter=$ITER: tests PASS -> done"
    _task_state_set status done
    tasks_update "$TASK_ID" status done inner_iter "$ITER" completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit 0
  fi

  log_warn "run-task-loop[$TASK_ID] iter=$ITER: tests FAIL (rc=$TRC), iterating"
  ITER=$((ITER + 1))
done

# Budget exhausted
log_error "run-task-loop[$TASK_ID]: inner budget ($MAX_INNER) exhausted"
tasks_append_error "$TASK_ID" "inner_budget_exhausted iter=$MAX_INNER"
_task_state_set status failed last_error "inner_budget"
tasks_update "$TASK_ID" status failed inner_iter "$ITER"
exit 1
