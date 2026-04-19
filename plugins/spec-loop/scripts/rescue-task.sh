#!/usr/bin/env bash
# rescue-task.sh - Standardised flow to rescue a task whose per-task loop
# ended in `failed` but whose branch actually contains viable commits.
#
# Steps:
#   1. Locate the task's branch.
#   2. Merge it into the current branch (abort + report on conflict).
#   3. Run the task's test_command on main worktree.
#   4. On pass: tasks_update status=done, archive review as deferred,
#      clean up worktree and branch.
#   5. On fail: print failing test names and leave state as-is.
#
# Usage: rescue-task.sh <task_id> [--no-test]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

TASK_ID="${1:?task_id required}"
NO_TEST=0
if [[ "${2:-}" == "--no-test" ]]; then NO_TEST=1; fi

cd "$CLAUDE_PROJECT_DIR"

# Find the wave this task belongs to so we can derive the branch name.
WAVE=$(tasks_get_field "$TASK_ID" wave)
if [[ -z "$WAVE" ]]; then
  echo "rescue-task[$TASK_ID]: task not found in tasks.json" >&2
  exit 2
fi
BR="spec-loop/wave-${WAVE}/task-${TASK_ID}"
WT=$(tasks_get_field "$TASK_ID" worktree)

if ! git show-ref --quiet "refs/heads/${BR}"; then
  echo "rescue-task[$TASK_ID]: branch ${BR} not found (already merged or cleaned up?)" >&2
  exit 2
fi

echo "[rescue] merging ${BR}"
if ! git merge --no-ff --no-edit "$BR"; then
  git merge --abort 2>/dev/null || true
  # Cherry-pick fallback: list files changed on the branch, cherry-pick
  # non-conflicting ones, file conflicting ones as deferred.
  mapfile -t CHANGED < <(git diff --name-only "HEAD..${BR}")
  CONFLICTS=()
  CLEAN=()
  for f in "${CHANGED[@]}"; do
    if ! git show "${BR}:${f}" >/dev/null 2>&1; then continue; fi
    # Is this file unchanged on HEAD (then clean) or different (conflict risk)?
    if git diff --quiet "HEAD" -- "$f" 2>/dev/null; then
      CLEAN+=("$f")
    elif ! git ls-tree HEAD "$f" >/dev/null 2>&1; then
      CLEAN+=("$f")  # new file not on HEAD
    else
      CONFLICTS+=("$f")
    fi
  done
  if (( ${#CLEAN[@]} > 0 )); then
    echo "[rescue] cherry-picking ${#CLEAN[@]} non-overlapping file(s) from ${BR}"
    for f in "${CLEAN[@]}"; do
      git checkout "$BR" -- "$f" || true
    done
    git add -A >/dev/null 2>&1 || true
  fi
  if (( ${#CONFLICTS[@]} > 0 )); then
    mkdir -p "$SPEC_LOOP_GLOBAL_DIR"
    {
      echo ""
      echo "## ${TASK_ID} — conflicting files (deferred)"
      echo ""
      echo "These files also exist on main with different content, so they were"
      echo "not auto-merged. Global-review phase should decide integration:"
      echo ""
      for f in "${CONFLICTS[@]}"; do echo "- \`$f\`"; done
    } >> "$SPEC_LOOP_GLOBAL_DIR/deferred-from-waves.md"
    echo "[rescue] ${#CONFLICTS[@]} file(s) recorded as deferred"
  fi
  git commit -m "rescue(${TASK_ID}): cherry-pick non-overlapping files from ${BR}" >/dev/null 2>&1 || true
fi

# Run test_command (narrow) unless asked to skip.
TEST_CMD=$(tasks_get_field "$TASK_ID" test_command)
if (( NO_TEST == 0 )) && [[ -n "$TEST_CMD" ]]; then
  echo "[rescue] running: $TEST_CMD"
  set +e
  bash -c "$TEST_CMD" 2>&1 | tail -20
  TRC=${PIPESTATUS[0]}
  set -e
  if (( TRC != 0 )); then
    echo "[rescue] tests failed (exit=$TRC). Task not marked done; human intervention required."
    exit 1
  fi
fi

# Mark done + archive per-task review if any
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tasks_update "$TASK_ID" status done completed_at "$TS"
TDIR=$(task_dir "$TASK_ID")
if [[ -f "$TDIR/task-state.json" ]]; then
  # Archive last review as deferred, if it was NEEDS_CHANGES
  LAST_VERDICT=$(_py3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("last_verdict",""))' "$TDIR/task-state.json" 2>/dev/null || echo "")
  if [[ "$LAST_VERDICT" == "NEEDS_CHANGES" ]]; then
    LAST_ITER=$(ls -1d "$TDIR"/iter-* 2>/dev/null | sort | tail -1)
    if [[ -n "$LAST_ITER" && -f "$LAST_ITER/codex-review.md" ]]; then
      mkdir -p "$SPEC_LOOP_GLOBAL_DIR"
      cp "$LAST_ITER/codex-review.md" "$SPEC_LOOP_GLOBAL_DIR/deferred-${TASK_ID}-review.md"
      echo "[rescue] archived review to deferred-${TASK_ID}-review.md"
    fi
  fi
fi

# Cleanup worktree + branch
if [[ -n "$WT" && -d "$WT" ]]; then
  git worktree remove --force "$WT" 2>/dev/null || true
fi
git branch -D "$BR" 2>/dev/null || true

log_info "rescue-task[$TASK_ID]: done"
echo "[rescue] $TASK_ID rescued: merged + tested + marked done."
