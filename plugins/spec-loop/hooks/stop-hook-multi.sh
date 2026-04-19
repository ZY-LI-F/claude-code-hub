#!/usr/bin/env bash
# stop-hook-multi.sh - Phase machine for v0.2 multi-task mode.
# Sourced by hooks/stop-hook.sh when state.mode == "multi". Exposes one
# function: _multi_phase_machine, which returns the desired exit code.
#
# Relies on helpers and env vars defined by hooks/stop-hook.sh:
#   - state_get / state_set / log_{info,warn,error}
#   - PHASE, OUTER, INNER, PLUGIN_ROOT, SPEC_LOOP_LOG, SPEC_LOOP_DIR
#
# Additional sources:
#   - scripts/lib-state.sh (already sourced by stop-hook.sh)
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

_multi_phase_machine() {
  local phase
  phase=$(state_get phase)
  log_info "multi: phase=$phase"

  case "$phase" in
    # ---- Step A: planning & decomposition (Claude's job) ----
    task-planning)
      cat >&2 <<EOF
[spec-loop multi] phase=task-planning.
Please:
  1. Consult the requirements-analyst agent to write .spec-loop/plan.md.
  2. Consult the batch-planner agent to populate .spec-loop/tasks.json AND run
     \`bash "${PLUGIN_ROOT}/scripts/compute-waves.sh"\` (the agent does this).
  3. Set phase=wave-running and launch wave 1:
     bash -c 'source "${PLUGIN_ROOT}/scripts/lib-state.sh" && state_set phase wave-running current_wave 1'
     bash "${PLUGIN_ROOT}/scripts/run-wave.sh" 1
EOF
      return 2
      ;;

    # ---- Step B: wave execution (mostly automated by run-wave.sh) ----
    wave-running)
      # Distinguish three wave states: in-progress (running>0 → let background
      # run-wave.sh continue), not-started (pending>0 → nudge Claude to run
      # it), complete (all done/failed → advance).
      local current_wave max_wave
      current_wave=$(state_get current_wave); current_wave=${current_wave:-1}
      max_wave=$(tasks_max_wave 2>/dev/null || echo 0)
      local wave_log="${SPEC_LOOP_BATCHES_DIR}/wave-$(printf '%03d' "$current_wave")/wave.log"

      local running pending
      running=$(tasks_count_in_wave "$current_wave" | awk -F= '/^running=/{print $2}')
      pending=$(tasks_count_in_wave "$current_wave" | awk -F= '/^pending=/{print $2}')
      running=${running:-0}; pending=${pending:-0}

      # Wave in progress: allow the Stop so background run-wave.sh can finish.
      # Claude will be re-woken by the task-notification when run-wave exits.
      if (( running > 0 )); then
        log_info "multi: wave $current_wave in progress (running=$running); allow exit"
        cat >&2 <<EOF
[spec-loop multi] Wave $current_wave in progress (running=$running). Background run-wave.sh will continue; you will be re-woken when it finishes.
Wave log: $wave_log
EOF
        return 0
      fi

      # Ready to advance or nudge based on pending count
      if (( pending == 0 )); then
        # Wave done. Auto-rescue any "failed" tasks whose branch is viable,
        # then advance.
        local failed_count
        failed_count=$(tasks_count_in_wave "$current_wave" | awk -F= '/^failed=/{print $2}')
        failed_count=${failed_count:-0}
        if (( failed_count > 0 )); then
          while IFS= read -r fid; do
            fid="${fid%$'\r'}"
            [[ -z "$fid" ]] && continue
            log_info "multi: auto-rescue attempt for failed task $fid"
            if bash "${PLUGIN_ROOT}/scripts/rescue-task.sh" "$fid" >> "$SPEC_LOOP_LOG" 2>&1; then
              log_info "multi: $fid rescued automatically"
            else
              log_warn "multi: $fid could not be auto-rescued; remains failed"
            fi
          done < <(_py3 - "$SPEC_LOOP_TASKS" "$current_wave" <<'PY'
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
w = int(sys.argv[2])
for t in d.get('tasks', []):
    if t.get('wave') == w and t.get('status') == 'failed':
        print(t['id'])
PY
)
        fi

        if (( current_wave >= max_wave )); then
          log_info "multi: all waves complete; transitioning to global-review"
          state_set phase global-review global_round 1
          cat >&2 <<EOF
[spec-loop multi] ✓ All waves complete. Transitioning to global-review round 1.
Next: bash "${PLUGIN_ROOT}/scripts/run-global-review.sh"
Or run in background:
  setsid bash "${PLUGIN_ROOT}/scripts/run-global-review.sh" </dev/null > "${SPEC_LOOP_GLOBAL_DIR}/round-001-stdout.log" 2>&1 &
EOF
          return 2
        else
          local next=$((current_wave + 1))
          log_info "multi: wave $current_wave done; auto-launching wave $next in background"
          state_set current_wave "$next"
          local next_dir
          next_dir="${SPEC_LOOP_BATCHES_DIR}/wave-$(printf '%03d' "$next")"
          mkdir -p "$next_dir"
          # Auto-launch next wave in a detached session (survives hook exit).
          # If setsid is unavailable, fall back to `&` + disown.
          if command -v setsid >/dev/null 2>&1; then
            setsid bash "${PLUGIN_ROOT}/scripts/run-wave.sh" "$next" </dev/null \
              > "$next_dir/stdout.log" 2>&1 &
          else
            bash "${PLUGIN_ROOT}/scripts/run-wave.sh" "$next" </dev/null \
              > "$next_dir/stdout.log" 2>&1 &
          fi
          disown 2>/dev/null || true
          cat >&2 <<EOF
[spec-loop multi] ✓ Wave $current_wave complete. Wave $next launched in background (PID=$!).
Log: $next_dir/stdout.log
You'll be notified when it finishes.
EOF
          return 0  # let Stop complete so background can run freely
        fi
      else
        # Wave not yet executed (or interrupted). Nudge.
        cat >&2 <<EOF
[spec-loop multi] phase=wave-running, current_wave=$current_wave has $pending pending task(s).
Please run:
  bash "${PLUGIN_ROOT}/scripts/run-wave.sh" $current_wave
Wave log (if any): $wave_log
EOF
        return 2
      fi
      ;;

    # ---- Step C: whole-project review ----
    global-review)
      local round_dir round review_file
      round=$(state_get global_round); round=${round:-1}
      round_dir=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$round")
      review_file="$round_dir/codex-review.md"

      if [[ ! -f "$review_file" ]]; then
        cat >&2 <<EOF
[spec-loop multi] phase=global-review round=$round. Please run:
  bash "${PLUGIN_ROOT}/scripts/run-global-review.sh"
EOF
        return 2
      fi

      # Review exists; move to addressing (Claude analyzes)
      state_set phase global-addressing
      cat >&2 <<EOF
[spec-loop multi] Global review complete (round=$round). Next:
  1. Consult the global-review-analyst agent to produce:
       $round_dir/claude-analysis.md
       $round_dir/decision.json
  2. Stop again. This hook will read decision.json and advance.
EOF
      return 2
      ;;

    # ---- Step D: analyst decision ----
    global-addressing)
      local round round_dir decision_file action
      round=$(state_get global_round); round=${round:-1}
      round_dir=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$round")
      decision_file="$round_dir/decision.json"

      if [[ ! -f "$decision_file" ]]; then
        cat >&2 <<EOF
[spec-loop multi] Waiting for global-review-analyst to write:
  $decision_file
EOF
        return 2
      fi

      action=$(python3 - "$decision_file" <<'PY' | tr -d '\r'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("action","fix"))
except Exception:
    print("fix")
PY
)
      case "$action" in
        accept)
          log_info "multi: analyst accepted round $round; proceeding to global-testing"
          state_set phase global-testing
          cat >&2 <<EOF
[spec-loop multi] Analyst accepted round $round findings. Next:
  bash "${PLUGIN_ROOT}/scripts/run-global-test.sh"
EOF
          ;;
        fix)
          log_info "multi: analyst requests fixes for round $round"
          state_set phase global-fixing
          cat >&2 <<EOF
[spec-loop multi] Analyst decided to fix round $round findings. Next:
  bash "${PLUGIN_ROOT}/scripts/run-global-fix.sh"
Then stop to continue into global-testing.
EOF
          ;;
        fail)
          log_error "multi: analyst declared round $round unfixable; aborting"
          state_set phase failed exit_reason "global_review_fail"
          cat >&2 <<EOF
[spec-loop multi] 🚫 Analyst declared the delivery unfixable at round $round.
Terminating. See $round_dir/claude-analysis.md for rationale.
EOF
          return 0
          ;;
        *)
          log_warn "multi: unknown action '$action' in decision.json; treating as fix"
          state_set phase global-fixing
          ;;
      esac
      return 2
      ;;

    # ---- Step E: global fix (codex) ----
    global-fixing)
      local round round_dir log_file
      round=$(state_get global_round); round=${round:-1}
      round_dir=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$round")
      log_file="$round_dir/codex-fix.log"

      if [[ ! -f "$log_file" ]]; then
        cat >&2 <<EOF
[spec-loop multi] phase=global-fixing round=$round. Please run:
  bash "${PLUGIN_ROOT}/scripts/run-global-fix.sh"
EOF
        return 2
      fi

      # Fix has been applied — move to testing
      log_info "multi: global-fix done; moving to global-testing"
      state_set phase global-testing
      cat >&2 <<EOF
[spec-loop multi] Global fix applied (round=$round). Next:
  bash "${PLUGIN_ROOT}/scripts/run-global-test.sh"
EOF
      return 2
      ;;

    # ---- Step F: global testing (gate) ----
    global-testing)
      local round round_dir result_file
      round=$(state_get global_round); round=${round:-1}
      round_dir=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$round")
      result_file="$round_dir/test-results.json"

      if [[ ! -f "$result_file" ]]; then
        cat >&2 <<EOF
[spec-loop multi] phase=global-testing round=$round. Please run:
  bash "${PLUGIN_ROOT}/scripts/run-global-test.sh"
EOF
        return 2
      fi

      local passed
      passed=$(python3 - "$result_file" <<'PY' | tr -d '\r'
import json, sys
try: print("true" if json.load(open(sys.argv[1])).get("passed") else "false")
except Exception: print("false")
PY
)

      local max
      max=$(state_get max_global_rounds); max=${max:-5}

      if [[ "$passed" == "true" ]]; then
        log_info "multi: global round $round PASSED -> done"
        state_set phase done
        cat >&2 <<EOF
[spec-loop multi] ✓ All tests pass after global round $round. Loop done.
State: $SPEC_LOOP_DIR/state.json
EOF
        return 0
      fi

      if (( round >= max )); then
        log_error "multi: exhausted global round budget ($round >= $max); failing"
        state_set phase failed exit_reason "global_rounds_exhausted"
        cat >&2 <<EOF
[spec-loop multi] 🚫 Global rounds budget exhausted ($round/$max). Terminating.
Last round artifacts: $round_dir
EOF
        return 0
      fi

      # Next round
      local next=$((round + 1))
      log_warn "multi: global round $round failed; starting round $next"
      state_set phase global-review global_round "$next"
      cat >&2 <<EOF
[spec-loop multi] Global round $round tests failed. Starting round $next.
Next: bash "${PLUGIN_ROOT}/scripts/run-global-review.sh"
EOF
      return 2
      ;;

    done|failed)
      return 0
      ;;

    # Fall back to the single-mode phase machine for any unknown/legacy phase
    *)
      cat >&2 <<EOF
[spec-loop multi] Unknown phase '$phase' in multi mode.
Use /spec-loop:spec-status to inspect, or /spec-loop:spec-cancel to reset.
EOF
      return 2
      ;;
  esac
}
