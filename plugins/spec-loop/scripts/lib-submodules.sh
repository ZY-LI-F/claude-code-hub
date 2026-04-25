#!/usr/bin/env bash
# lib-submodules.sh - Submodule support for spec-loop multi-task mode.
#
# Background: spec-loop creates a git worktree per task. By default
# `git worktree add` does NOT initialize submodules — the worktree's
# submodule git store lives at .git/worktrees/<wt>/modules/<sub>/. When
# the worktree is destroyed, that store is gone, and any commits made
# inside the submodule become unreachable orphans even though the
# superproject branch references them. This breaks merge-back.
#
# This library fixes that by:
#   1. (init)  initializing submodules in each worktree with shared object
#              alternates pointing to the parent submodule's object store +
#              adding a `parent` remote.
#   2. (push)  before destroying a worktree, pushing each modified submodule's
#              HEAD to the parent submodule as a tagged ref
#              `refs/spec-loop/wave-<N>/<TID>`.
#   3. (merge) replacing the cherry-pick fallback with a custom merge that
#              detects gitlink (160000) changes, cherry-picks the task's
#              submodule commits onto the current submodule HEAD, and creates
#              one fresh pointer commit per task on main.
#
# Public API:
#   sl_list_submodules
#   sl_init_submodules_in_worktree <worktree_abs_path>
#   sl_push_submodule_commits_to_parent <worktree> <wave> <tid>
#   sl_custom_merge_task <wave> <tid> <branch>  -> 0 success | 1 conflict | 2 noop
#   sl_cleanup_wave_refs <wave>

# Resolve the on-disk git directory for a submodule (handles `gitdir:` files).
sl_resolve_git_dir() {
  local subpath="$1"
  if [[ -d "$subpath/.git" ]]; then
    printf '%s\n' "$subpath/.git"
    return 0
  fi
  if [[ -f "$subpath/.git" ]]; then
    local line
    line=$(head -1 "$subpath/.git" 2>/dev/null)
    line="${line#gitdir: }"
    if [[ "$line" = /* ]]; then
      printf '%s\n' "$line"
    else
      # Resolve relative path against subpath
      printf '%s\n' "$(cd "$subpath" && cd "$line" && pwd)"
    fi
    return 0
  fi
  return 1
}

# Print one submodule path per line (relative to superproject root).
sl_list_submodules() {
  ( cd "$CLAUDE_PROJECT_DIR" && \
    git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null \
      | awk '{print $2}' ) | tr -d '\r'
}

# Initialize submodules inside a worktree with object alternates pointing
# to the parent's submodule store + a `parent` remote for push-back.
# Args: <worktree_abs_path>
sl_init_submodules_in_worktree() {
  local wt="$1"
  [[ -d "$wt" ]] || { log_warn "sl_init_submodules_in_worktree: $wt missing"; return 1; }

  local subs=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && subs+=("$s")
  done < <(sl_list_submodules)
  (( ${#subs[@]} == 0 )) && return 0

  for sub in "${subs[@]}"; do
    local parent_sub_git
    parent_sub_git=$(sl_resolve_git_dir "$CLAUDE_PROJECT_DIR/$sub") || {
      log_warn "sl_init: cannot resolve parent .git for $sub"
      continue
    }

    # Resolve submodule NAME from .gitmodules (key 'submodule.<name>.path = <sub>')
    local subname
    subname=$( cd "$wt" && \
      git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null \
      | awk -v p="$sub" '$2 == p {print $1}' \
      | sed -E 's/^submodule\.//; s/\.path$//' \
      | head -1 )
    [[ -z "$subname" ]] && subname="$sub"

    # CORRECT order for URL override:
    #   1. `git submodule init` — copies URL from .gitmodules to repo config.
    #   2. `git config submodule.<name>.url <parent>` — overrides post-init.
    #   3. `git submodule update` — clones using the overridden URL.
    # If we set the config BEFORE init, the init step happily overwrites it
    # back to the .gitmodules URL.
    ( cd "$wt" && git submodule init -- "$sub" >/dev/null 2>&1 ) || true
    ( cd "$wt" && git config "submodule.${subname}.url" "$parent_sub_git" ) >/dev/null 2>&1 || true
    # `submodule sync` propagates the URL into the submodule's own remote.
    ( cd "$wt" && git submodule sync --recursive -- "$sub" >/dev/null 2>&1 ) || true
    # Now do the actual checkout
    if ! ( cd "$wt" && git submodule update --recursive -- "$sub" >/dev/null 2>&1 ); then
      log_warn "sl_init: 'submodule update' failed for $sub in $wt — codex may retry; alternates+parent-remote will still be set up if dir exists"
    fi

    # If the submodule dir/.git is still missing, we cannot continue with
    # alternates / remote setup. Fall through; codex's own init may rescue it
    # later but our push-back step won't have a `parent` remote then.
    if [[ ! -e "$wt/$sub/.git" ]]; then
      log_warn "sl_init: $wt/$sub/.git missing after init; skipping alternates+remote"
      continue
    fi

    local wt_sub_git
    wt_sub_git=$(sl_resolve_git_dir "$wt/$sub") || {
      log_warn "sl_init: cannot resolve .git for $wt/$sub"
      continue
    }

    # Set up object alternates so any object created in the worktree's
    # submodule is also reachable from the parent submodule store.
    if [[ -d "$parent_sub_git/objects" ]]; then
      mkdir -p "$wt_sub_git/objects/info"
      # Replace existing alternates entry for parent (idempotent).
      grep -v -F "$parent_sub_git/objects" "$wt_sub_git/objects/info/alternates" 2>/dev/null \
        > "$wt_sub_git/objects/info/alternates.tmp" || true
      printf '%s\n' "$parent_sub_git/objects" >> "$wt_sub_git/objects/info/alternates.tmp"
      mv -f "$wt_sub_git/objects/info/alternates.tmp" "$wt_sub_git/objects/info/alternates"
    fi

    # Add `parent` remote for push-back. URL is the parent submodule's git dir.
    # Best-effort but log the actual outcome so we can debug.
    ( cd "$wt/$sub" && git remote remove parent ) >/dev/null 2>&1 || true
    if ( cd "$wt/$sub" && git remote add parent "$parent_sub_git" ) >/dev/null 2>&1; then
      log_info "sl_init: added 'parent' remote in $wt/$sub -> $parent_sub_git"
    else
      # Already exists with same URL (after the remove failed) — set-url instead.
      ( cd "$wt/$sub" && git remote set-url parent "$parent_sub_git" ) >/dev/null 2>&1 || \
        log_warn "sl_init: could not configure 'parent' remote in $wt/$sub"
    fi
  done
  return 0
}

# Push the worktree's submodule HEAD(s) into the parent submodule under a
# named ref. Should be called BEFORE worktree removal. Prints lines
# "<sub>:<sha>" for each submodule that diverges from the parent.
# Args: <worktree> <wave> <tid>
sl_push_submodule_commits_to_parent() {
  local wt="$1" wave="$2" tid="$3"
  local subs=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && subs+=("$s")
  done < <(sl_list_submodules)
  (( ${#subs[@]} == 0 )) && return 0

  for sub in "${subs[@]}"; do
    [[ -d "$wt/$sub" ]] || continue
    sl_resolve_git_dir "$wt/$sub" >/dev/null 2>&1 || continue

    local wt_head
    wt_head=$( cd "$wt/$sub" && git rev-parse HEAD 2>/dev/null ) || continue
    [[ -z "$wt_head" ]] && continue

    # Compare to the gitlink the worktree's superproject branch records.
    # If the worktree never advanced the submodule, skip — nothing to push.
    local recorded
    recorded=$( cd "$wt" && git ls-tree HEAD -- "$sub" 2>/dev/null | awk '{print $3}' )
    [[ "$wt_head" == "$recorded" ]] || true   # always push if head is non-trivial
    # Even if recorded matches, push if it differs from PARENT submodule HEAD —
    # otherwise the parent has no way to reach the commit later.
    local parent_head
    parent_head=$( cd "$CLAUDE_PROJECT_DIR/$sub" 2>/dev/null && git rev-parse HEAD 2>/dev/null ) || parent_head=""
    if [[ "$wt_head" == "$parent_head" ]]; then
      continue
    fi

    # Make sure `parent` remote is configured. If sl_init bailed early
    # (init failure) we fix it here. This makes push-back self-sufficient.
    local parent_sub_git_local
    parent_sub_git_local=$(sl_resolve_git_dir "$CLAUDE_PROJECT_DIR/$sub") || parent_sub_git_local=""
    if [[ -n "$parent_sub_git_local" ]]; then
      if ! ( cd "$wt/$sub" && git remote get-url parent >/dev/null 2>&1 ); then
        ( cd "$wt/$sub" && git remote add parent "$parent_sub_git_local" ) >/dev/null 2>&1 || \
          ( cd "$wt/$sub" && git remote set-url parent "$parent_sub_git_local" ) >/dev/null 2>&1 || true
      fi
    fi

    local ref="refs/spec-loop/wave-${wave}/${tid}"
    if ( cd "$wt/$sub" && git push -q parent "HEAD:${ref}" 2>>"$SPEC_LOOP_LOG" ); then
      printf '%s:%s\n' "$sub" "$wt_head"
      log_info "sl_push: pushed $sub @ $wt_head -> parent ${ref}"
    else
      log_warn "sl_push: failed to push $sub from $wt to parent ${ref}"
    fi
  done
}

# Custom-merge a task that may have submodule-pointer conflicts.
# Walks the diff between current main HEAD and <branch>:
#   - For non-gitlink files, copy them from branch (cherry-pick by checkout).
#   - For gitlink files (submodule pointers), enter the parent submodule,
#     cherry-pick the task's commits onto the CURRENT submodule HEAD (which
#     may already include earlier tasks from the same wave), producing a new
#     submodule HEAD. Then `git add <sub>` to bump pointer.
# Finally make ONE commit on main.
# Args: <wave> <tid> <branch>
# Returns: 0 success, 1 conflict (left repo dirty for forensics), 2 no-op.
sl_custom_merge_task() {
  local wave="$1" tid="$2" br="$3"
  cd "$CLAUDE_PROJECT_DIR" || return 1

  # Diff list relative to current main
  local changes=()
  while IFS= read -r f; do
    f="${f%$'\r'}"
    [[ -n "$f" ]] && changes+=("$f")
  done < <( git diff --name-only "HEAD..${br}" 2>/dev/null )

  if (( ${#changes[@]} == 0 )); then
    log_info "sl_custom_merge[$tid]: no changes to integrate"
    return 2
  fi

  # Classify
  local sub_changes=() file_changes=()
  for f in "${changes[@]}"; do
    local mode_a mode_b
    mode_a=$( git ls-tree HEAD -- "$f" 2>/dev/null | awk '{print $1}' )
    mode_b=$( git ls-tree "$br"  -- "$f" 2>/dev/null | awk '{print $1}' )
    if [[ "$mode_a" == "160000" || "$mode_b" == "160000" ]]; then
      sub_changes+=("$f")
    else
      file_changes+=("$f")
    fi
  done

  # Apply non-gitlink files
  for f in "${file_changes[@]}"; do
    [[ -z "$f" ]] && continue
    if [[ -n "$( git ls-tree "$br" -- "$f" 2>/dev/null )" ]]; then
      git checkout "$br" -- "$f" 2>>"$SPEC_LOOP_LOG" || {
        log_warn "sl_custom_merge[$tid]: cannot checkout $f from $br"
      }
    else
      # File deleted on branch
      git rm -f -- "$f" 2>>"$SPEC_LOOP_LOG" || true
    fi
  done

  # For each submodule with gitlink change, enter the parent submodule and
  # cherry-pick the task's commits onto the current submodule HEAD.
  for sub in "${sub_changes[@]}"; do
    [[ -z "$sub" ]] && continue
    local task_sha
    task_sha=$( git ls-tree "$br" -- "$sub" 2>/dev/null | awk '{print $3}' )
    if [[ -z "$task_sha" ]]; then
      log_warn "sl_custom_merge[$tid]: $sub has no SHA on branch — skipping"
      continue
    fi

    # Make sure the parent submodule has the commit reachable. The push step
    # in sl_push_submodule_commits_to_parent should have made it so.
    if ! ( cd "$CLAUDE_PROJECT_DIR/$sub" && git cat-file -e "$task_sha" 2>/dev/null ); then
      log_error "sl_custom_merge[$tid]: $sub commit $task_sha NOT in parent submodule store; aborting"
      return 1
    fi

    # Compute the new submodule HEAD: cherry-pick task's commits onto current.
    # Current pointer (before integrating this task) is what main currently
    # records for this submodule.
    local cur_pointer
    cur_pointer=$( git ls-tree HEAD -- "$sub" 2>/dev/null | awk '{print $3}' )
    if [[ -z "$cur_pointer" ]]; then
      log_error "sl_custom_merge[$tid]: cannot read current pointer for $sub"
      return 1
    fi

    # Identify task's NEW commits (those not in cur_pointer)
    local new_commits=()
    while IFS= read -r c; do
      [[ -n "$c" ]] && new_commits+=("$c")
    done < <( cd "$CLAUDE_PROJECT_DIR/$sub" && \
              git rev-list --reverse "${cur_pointer}..${task_sha}" 2>/dev/null )

    if (( ${#new_commits[@]} == 0 )); then
      log_info "sl_custom_merge[$tid]: $sub already in sync (no new commits)"
      continue
    fi

    # Stage on a temporary branch in parent submodule
    local tmp_branch="spec-loop/integ/wave-${wave}/${tid}"
    ( cd "$CLAUDE_PROJECT_DIR/$sub" && git checkout -B "$tmp_branch" "$cur_pointer" >/dev/null 2>&1 ) || {
      log_error "sl_custom_merge[$tid]: cannot create temp branch in $sub"
      return 1
    }

    local cp_ok=1
    for c in "${new_commits[@]}"; do
      if ! ( cd "$CLAUDE_PROJECT_DIR/$sub" && \
             git cherry-pick --allow-empty --keep-redundant-commits "$c" >/dev/null 2>>"$SPEC_LOOP_LOG" ); then
        ( cd "$CLAUDE_PROJECT_DIR/$sub" && git cherry-pick --abort 2>/dev/null )
        cp_ok=0
        break
      fi
    done

    if (( ! cp_ok )); then
      log_error "sl_custom_merge[$tid]: cherry-pick conflict in submodule $sub"
      # Leave parent submodule on tmp_branch for forensics
      return 1
    fi

    # The submodule's HEAD is now the integrated commit; staging the path
    # in the superproject picks up the new SHA.
    git add -- "$sub" 2>>"$SPEC_LOOP_LOG" || {
      log_error "sl_custom_merge[$tid]: git add $sub failed"
      return 1
    }
  done

  # Stage all the file_changes we already wrote
  for f in "${file_changes[@]}"; do
    git add -- "$f" >/dev/null 2>&1 || true
  done

  if git diff --cached --quiet; then
    log_warn "sl_custom_merge[$tid]: nothing staged"
    return 2
  fi

  if ! git commit -m "spec-loop wave-${wave} integrate ${tid}" >/dev/null 2>>"$SPEC_LOOP_LOG"; then
    log_error "sl_custom_merge[$tid]: commit on main failed"
    return 1
  fi
  log_info "sl_custom_merge[$tid]: integrated ${#sub_changes[@]} submodule(s) + ${#file_changes[@]} file(s)"
  return 0
}

# Cleanup parent-submodule refs for a wave (after successful integration).
sl_cleanup_wave_refs() {
  local wave="$1"
  local subs=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && subs+=("$s")
  done < <(sl_list_submodules)
  for sub in "${subs[@]}"; do
    [[ -d "$CLAUDE_PROJECT_DIR/$sub/.git" || -f "$CLAUDE_PROJECT_DIR/$sub/.git" ]] || continue
    ( cd "$CLAUDE_PROJECT_DIR/$sub" && \
      git for-each-ref --format='%(refname)' "refs/spec-loop/wave-${wave}/" 2>/dev/null | \
      while read -r r; do git update-ref -d "$r" >/dev/null 2>&1; done ) || true
  done
}
