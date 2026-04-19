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
#   task-state.json      {iter, last_verdict, status, ...}
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
d = {"id": tid, "iter": 0, "status": "running", "last_verdict": "",
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

_build_review_prompt() {
  local iter_dir="$1"
  local diff
  diff=$(cd "$CWD" && git diff HEAD~1..HEAD 2>/dev/null | head -c "$DIFF_CAP")
  [[ -z "$diff" ]] && diff=$(cd "$CWD" && git diff HEAD 2>/dev/null | head -c "$DIFF_CAP")
  cat > "$iter_dir/review-prompt.md" <<EOF
# Code Review (multi-task mode)

You are an independent reviewer for a single parallel task. Be strict and
concrete. Review only the diff below against the task spec.

## Task

$(cat "$TASK_MD")

## Diff

\`\`\`diff
$diff
\`\`\`

## Output format

For each finding, use this block:
\`\`\`
<SEVERITY>: <title> — <file:line>
  Rationale: ...
  Fix: ...
\`\`\`
Severities: BLOCKING, IMPORTANT, NIT.

End with exactly one line: \`VERDICT: APPROVED\` or \`VERDICT: NEEDS_CHANGES\`.
EOF
}

_build_fix_prompt() {
  local iter_dir="$1" prev_review_file="$2"
  cat > "$iter_dir/impl-prompt.md" <<EOF
# Task Fix Iteration (multi-task mode)

Same working directory / task as before. Address ALL findings in the prior
review. Re-run any tests you touched.

## Task

$(cat "$TASK_MD")

## Prior review to address

$(cat "$prev_review_file")

## Rules
- Minimal fix; don't refactor unrelated code.
- Commit with message prefix \`[spec-loop] $TASK_ID fix: ...\`.
- **Do NOT** edit \`.spec-loop/\` files.
EOF
}

# ---- Main loop ----
ITER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("iter",0))' "$TASK_STATE")
ITER=${ITER:-0}

while (( ITER < MAX_INNER )); do
  ITER_DIR="$TASK_DIR/iter-$(printf '%03d' "$ITER")"
  mkdir -p "$ITER_DIR"
  _task_state_set iter "$ITER" status running

  # ---- Step 1: implement / fix ----
  PREV_REVIEW=""
  PREV_ITER=$((ITER - 1))
  PREV_REVIEW_FILE="$TASK_DIR/iter-$(printf '%03d' "$PREV_ITER")/codex-review.md"
  if (( ITER == 0 )); then
    _build_impl_prompt "$ITER_DIR" ""
  elif [[ -f "$PREV_REVIEW_FILE" ]]; then
    _build_fix_prompt "$ITER_DIR" "$PREV_REVIEW_FILE"
  else
    _build_impl_prompt "$ITER_DIR" ""
  fi

  if ! _run_codex "$ITER_DIR/impl-prompt.md" "$ITER_DIR/codex-impl.log"; then
    log_error "run-task-loop[$TASK_ID] iter=$ITER: codex implement failed"
    tasks_append_error "$TASK_ID" "codex implement failed at iter=$ITER"
    _task_state_set status failed last_error "codex_implement_failed"
    tasks_update "$TASK_ID" status failed
    exit 1
  fi

  # Capture the diff for the record
  ( cd "$CWD" && git diff HEAD~1..HEAD 2>/dev/null || git diff HEAD 2>/dev/null ) > "$ITER_DIR/diff.patch" || true

  # ---- Step 2: review ----
  _build_review_prompt "$ITER_DIR"
  if ! _run_codex "$ITER_DIR/review-prompt.md" "$ITER_DIR/codex-review.md"; then
    log_warn "run-task-loop[$TASK_ID] iter=$ITER: codex review failed; assuming NEEDS_CHANGES"
    echo "VERDICT: NEEDS_CHANGES" > "$ITER_DIR/codex-review.md"
  fi

  VERDICT="NEEDS_CHANGES"
  if grep -qE '^VERDICT:\s*APPROVED' "$ITER_DIR/codex-review.md"; then
    VERDICT="APPROVED"
  fi
  _task_state_set last_verdict "$VERDICT"

  # ---- Step 3: test (only when review approves) ----
  if [[ "$VERDICT" == "APPROVED" ]]; then
    if [[ -n "$TEST_CMD" ]]; then
      ( cd "$CWD" && timeout "$TIMEOUT_SEC" bash -c "$TEST_CMD" ) > "$ITER_DIR/test-output.log" 2>&1
      TRC=$?
      python3 - "$ITER_DIR/test-results.json" "$TRC" "$TEST_CMD" <<'PY'
import json, sys
path, rc, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
json.dump({"passed": rc == 0, "exit_code": rc, "command": cmd}, open(path, 'w'), indent=2)
PY
      if (( TRC == 0 )); then
        log_info "run-task-loop[$TASK_ID] iter=$ITER: PASS"
        _task_state_set status done
        tasks_update "$TASK_ID" status done inner_iter "$ITER" completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        exit 0
      else
        log_warn "run-task-loop[$TASK_ID] iter=$ITER: tests FAILED, continuing loop"
      fi
    else
      # No test command: approve = done
      log_info "run-task-loop[$TASK_ID] iter=$ITER: APPROVED, no test command -> done"
      _task_state_set status done
      tasks_update "$TASK_ID" status done inner_iter "$ITER" completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      exit 0
    fi
  fi

  ITER=$((ITER + 1))
done

# Budget exhausted
log_error "run-task-loop[$TASK_ID]: inner budget ($MAX_INNER) exhausted"
tasks_append_error "$TASK_ID" "inner_budget_exhausted iter=$MAX_INNER"
_task_state_set status failed last_error "inner_budget"
tasks_update "$TASK_ID" status failed inner_iter "$ITER"
exit 1
