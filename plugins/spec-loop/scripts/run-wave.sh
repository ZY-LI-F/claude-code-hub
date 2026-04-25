#!/usr/bin/env bash
# run-wave.sh - Execute a single wave: fan out <= max_parallel task loops in
# parallel (each in its own git worktree), wait for them, merge their commits
# back to the main branch, and clean up.
#
# Usage: run-wave.sh <wave_num>
# Writes per-wave logs under .spec-loop/batches/wave-<N>/.
# Updates tasks.json (status) and state.json (current_wave).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-submodules.sh"

# Detect if the project uses git submodules — only then do the extra work.
SL_HAS_SUBMODULES=0
if [[ -f "$CLAUDE_PROJECT_DIR/.gitmodules" ]] && \
   git -C "$CLAUDE_PROJECT_DIR" config --file .gitmodules --get-regexp 'submodule\..*\.path' >/dev/null 2>&1; then
  SL_HAS_SUBMODULES=1
fi

WAVE="${1:?wave number required}"
MAX_PAR=$(state_get max_parallel); MAX_PAR=${MAX_PAR:-3}
WAVE_DIR=$(printf '%s/wave-%03d' "$SPEC_LOOP_BATCHES_DIR" "$WAVE")
mkdir -p "$WAVE_DIR"
WAVE_LOG="$WAVE_DIR/wave.log"

state_set current_wave "$WAVE"

# Gather task ids in this wave (not done/failed).
# Strip any stray CR (Windows Python stdout) that snuck through.
TASK_IDS=()
while IFS= read -r tid; do
  tid="${tid%$'\r'}"
  tid="${tid//[[:space:]]/}"
  [[ -n "$tid" ]] && TASK_IDS+=("$tid")
done < <(tasks_pending_in_wave "$WAVE")

if (( ${#TASK_IDS[@]} == 0 )); then
  log_info "run-wave[$WAVE]: no pending tasks — skipping"
  echo "Wave $WAVE: nothing to do"
  exit 0
fi

log_info "run-wave[$WAVE]: launching ${#TASK_IDS[@]} task(s) (max_parallel=$MAX_PAR)"
echo "[spec-loop] Wave $WAVE tasks: ${TASK_IDS[*]}" | tee -a "$WAVE_LOG"

# Base commit: current HEAD of main worktree
cd "$CLAUDE_PROJECT_DIR"
BASE_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ -z "$BASE_HEAD" ]]; then
  log_error "run-wave: not a git repo or no HEAD"
  echo "ERROR: project must be a git repo with at least one commit" >&2
  exit 2
fi
echo "[spec-loop] base HEAD: $BASE_HEAD" | tee -a "$WAVE_LOG"

# ---- Create worktree + branch per task ----
declare -A TASK_WORKTREE
declare -A TASK_BRANCH
for tid in "${TASK_IDS[@]}"; do
  TDIR=$(task_dir "$tid")
  mkdir -p "$TDIR"
  WT="$TDIR/worktree"
  BR="spec-loop/wave-${WAVE}/task-${tid}"
  # If worktree exists, remove it first (stale from previous run)
  if [[ -d "$WT" ]]; then
    git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
    git branch -D "$BR" 2>/dev/null || true
  fi
  if ! git worktree add -B "$BR" "$WT" "$BASE_HEAD" >> "$WAVE_LOG" 2>&1; then
    log_error "run-wave[$WAVE]: failed to create worktree for $tid"
    tasks_update "$tid" status failed
    tasks_append_error "$tid" "worktree_create_failed"
    continue
  fi
  # Initialize submodules in the worktree with shared object alternates +
  # `parent` remote so commits inside submodules survive worktree removal.
  if (( SL_HAS_SUBMODULES )); then
    sl_init_submodules_in_worktree "$WT" >> "$WAVE_LOG" 2>&1 || \
      log_warn "run-wave[$WAVE]: submodule init failed for $tid (continuing)"
  fi
  TASK_WORKTREE["$tid"]="$WT"
  TASK_BRANCH["$tid"]="$BR"
  tasks_update "$tid" worktree "$WT" status running started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
done

# ---- Launch in parallel with semaphore ----
PIDS=()
TIDS_IN_ORDER=()
RUNNING=0
for tid in "${TASK_IDS[@]}"; do
  [[ -z "${TASK_WORKTREE[$tid]:-}" ]] && continue
  while (( RUNNING >= MAX_PAR )); do
    # Wait for any child to finish
    wait -n 2>/dev/null || wait
    RUNNING=$((RUNNING - 1))
  done
  (
    bash "${PLUGIN_ROOT}/scripts/run-task-loop.sh" "$tid" \
      >> "$WAVE_DIR/task-${tid}.log" 2>&1
  ) &
  PIDS+=("$!")
  TIDS_IN_ORDER+=("$tid")
  RUNNING=$((RUNNING + 1))
  log_info "run-wave[$WAVE]: launched $tid (pid=$!)"
done

# Wait for remaining
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done
log_info "run-wave[$WAVE]: all subprocess finished"

# ---- Pre-merge: push each successful task's submodule commits into parent ----
# This makes the worktree-side submodule HEADs reachable from the parent
# submodule store BEFORE the worktrees are deleted later. Without this step,
# the inner submodule commits are orphaned on worktree removal and the
# superproject branch ends up referencing dangling SHAs.
if (( SL_HAS_SUBMODULES )); then
  for tid in "${TIDS_IN_ORDER[@]}"; do
    ST=$(tasks_get_field "$tid" status)
    WT="${TASK_WORKTREE[$tid]:-}"
    [[ "$ST" == "done" && -n "$WT" && -d "$WT" ]] || continue
    sl_push_submodule_commits_to_parent "$WT" "$WAVE" "$tid" >> "$WAVE_LOG" 2>&1 || \
      log_warn "run-wave[$WAVE]: submodule push-back failed for $tid"
  done
fi

# ---- Merge each worktree's branch back to main branch ----
cd "$CLAUDE_PROJECT_DIR"
MAIN_BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "main")
FAILED_MERGES=()
for tid in "${TIDS_IN_ORDER[@]}"; do
  ST=$(tasks_get_field "$tid" status)
  WT="${TASK_WORKTREE[$tid]:-}"
  BR="${TASK_BRANCH[$tid]:-}"
  if [[ "$ST" != "done" ]]; then
    log_warn "run-wave[$WAVE]: skip merge for $tid (status=$ST)"
    continue
  fi
  if [[ -z "$BR" ]]; then
    continue
  fi
  echo "[merge] $tid branch=$BR" | tee -a "$WAVE_LOG"

  # Two paths:
  # 1. No submodules in the project — try plain `git merge`, fall back to
  #    file-level cherry-pick of non-overlapping files (legacy behavior).
  # 2. Submodules present — go straight to `sl_custom_merge_task` which
  #    handles gitlink (160000) entries by cherry-picking the submodule's
  #    inner commits onto the current submodule HEAD.
  if (( SL_HAS_SUBMODULES )); then
    if sl_custom_merge_task "$WAVE" "$tid" "$BR" >> "$WAVE_LOG" 2>&1; then
      log_info "run-wave[$WAVE]: integrated $tid (submodule-aware)"
    else
      RC=$?
      if (( RC == 2 )); then
        log_info "run-wave[$WAVE]: $tid was a no-op (no diff)"
      else
        log_error "run-wave[$WAVE]: submodule-aware merge failed for $tid (rc=$RC)"
        # Roll back any partial state
        git reset --hard HEAD >> "$WAVE_LOG" 2>&1 || true
        tasks_update "$tid" status failed
        tasks_append_error "$tid" "submodule_merge_conflict"
        FAILED_MERGES+=("$tid")
      fi
    fi
  elif git merge --no-ff --no-edit "$BR" >> "$WAVE_LOG" 2>&1; then
    log_info "run-wave[$WAVE]: merged $tid"
  else
    # Merge conflict (no submodules): legacy cherry-pick fallback.
    git merge --abort 2>/dev/null || true
    log_warn "run-wave[$WAVE]: merge conflict for $tid; attempting cherry-pick fallback"
    mapfile -t CHANGED < <(git diff --name-only "HEAD..${BR}" 2>/dev/null)
    CLEAN_COUNT=0
    CONFLICT_FILES=()
    for f in "${CHANGED[@]}"; do
      f="${f%$'\r'}"
      [[ -z "$f" ]] && continue
      if git ls-tree HEAD "$f" >/dev/null 2>&1; then
        if ! git diff --quiet "HEAD" "${BR}" -- "$f" 2>/dev/null; then
          CONFLICT_FILES+=("$f")
          continue
        fi
      fi
      git checkout "$BR" -- "$f" >>"$WAVE_LOG" 2>&1 && CLEAN_COUNT=$((CLEAN_COUNT+1))
    done
    if (( CLEAN_COUNT > 0 )); then
      git add -A >/dev/null 2>&1 || true
      git commit -m "wave-${WAVE} fallback(${tid}): cherry-pick non-overlapping files" >>"$WAVE_LOG" 2>&1 || true
      log_warn "run-wave[$WAVE]: cherry-picked $CLEAN_COUNT file(s) from $tid; ${#CONFLICT_FILES[@]} conflict file(s) deferred"
      if (( ${#CONFLICT_FILES[@]} > 0 )); then
        mkdir -p "$SPEC_LOOP_GLOBAL_DIR"
        {
          echo ""
          echo "## $tid — conflicting files (wave $WAVE)"
          echo ""
          for cf in "${CONFLICT_FILES[@]}"; do echo "- \`$cf\`"; done
        } >> "$SPEC_LOOP_GLOBAL_DIR/deferred-from-waves.md"
      fi
      tasks_update "$tid" status done completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      log_error "run-wave[$WAVE]: cherry-pick found 0 clean files for $tid; marking failed"
      tasks_update "$tid" status failed
      tasks_append_error "$tid" "merge_conflict_no_clean_files"
      FAILED_MERGES+=("$tid")
    fi
  fi
done

# Cleanup parent-submodule integration refs so they don't accumulate.
if (( SL_HAS_SUBMODULES )); then
  sl_cleanup_wave_refs "$WAVE" >> "$WAVE_LOG" 2>&1 || true
fi

# ---- Cleanup worktrees (optional: keep on failure for forensics) ----
for tid in "${TIDS_IN_ORDER[@]}"; do
  WT="${TASK_WORKTREE[$tid]:-}"
  BR="${TASK_BRANCH[$tid]:-}"
  ST=$(tasks_get_field "$tid" status)
  # Keep failed worktrees for debugging
  if [[ "$ST" == "done" && -d "$WT" ]]; then
    git worktree remove --force "$WT" >> "$WAVE_LOG" 2>&1 || true
    git branch -D "$BR" >> "$WAVE_LOG" 2>&1 || true
  fi
done

# Summary
{
  echo "=== Wave $WAVE summary ==="
  tasks_count_by_status
  if (( ${#FAILED_MERGES[@]} > 0 )); then
    echo "merge_conflicts: ${FAILED_MERGES[*]}"
  fi
} | tee -a "$WAVE_LOG"

# Exit code: 0 if every task in this wave is done, 1 otherwise
for tid in "${TASK_IDS[@]}"; do
  ST=$(tasks_get_field "$tid" status)
  if [[ "$ST" != "done" ]]; then
    exit 1
  fi
done
exit 0
