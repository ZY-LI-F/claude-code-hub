---
description: "Start a multi-task spec-loop: Claude plans a task DAG, up to 3 tasks run in parallel per wave in isolated git worktrees, each task drives its own Codex implement→review→fix→test loop; after all tasks merge, Codex does up to 5 rounds of whole-project review→fix→test until converged."
argument-hint: "<one-line spec>"
---

You are starting a **multi-task spec-loop** (v0.2). This is the DAG-parallel
variant of `/spec-loop:spec-start` — for complex, multi-feature work where a
single task is too coarse. Single-task mode is still available at
`/spec-loop:spec-start` (unchanged).

## Architecture

```
L0  Claude Code (orchestrator)
L1  Wave scheduler       : topo-sorted waves, each wave runs <=3 tasks in parallel
      + global loop      : after all waves finish, codex does up to 5 rounds of
                           whole-project review → fix → test
L2  Single-task loop     : per-task codex implement→review→fix→test (self-driving)
```

## Boot sequence

1. **Initialize state**. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-spec-loop-multi.sh" \
     "$CLAUDE_SESSION_ID" \
     "$ARGUMENTS"
   ```
   This creates `.spec-loop/` with `mode=multi`, records `multi_base_commit`,
   detects the scenario, and puts phase in `task-planning`.

2. **Plan (Claude, L1 planner)**.
   - Consult the `spec-loop:requirements-analyst` agent to produce
     `.spec-loop/plan.md`.
   - Consult the `spec-loop:batch-planner` agent to populate
     `.spec-loop/tasks.json` from the plan. This agent is responsible for
     running `compute-waves.sh` to stamp the `wave` field.

3. **Kick off wave 1**. Set phase + run:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh" && state_set phase wave-running current_wave 1'
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-wave.sh" 1
   ```
   `run-wave.sh` creates a git worktree per task (branch
   `spec-loop/wave-1/task-TXX`), launches up to `max_parallel` codex
   subprocesses in parallel, waits, then merges the successful branches back
   onto the main branch (aborts on conflict and marks the task failed).

4. **Stop**. The Stop hook takes over. It reads `state.json` and:
   - If phase `wave-running` and wave tasks all terminal → advance to next
     wave or to `global-review` if all waves are complete.
   - If phase `global-review` → run `run-global-review.sh`, then consult
     `spec-loop:global-review-analyst` to decide `accept | fix | fail`.
   - `accept` → `global-testing`; `fix` → `run-global-fix.sh` then
     `global-testing`.
   - `global-testing` runs `run-global-test.sh`; on pass → `done`; on fail
     and `global_round < max_global_rounds` → bump round and re-review; else
     → `failed`.

## Budgets

| Variable | Default | Meaning |
|---|---|---|
| `SPEC_LOOP_MAX_PARALLEL` | 3 | Concurrent tasks per wave |
| `SPEC_LOOP_MAX_GLOBAL_ROUNDS` | 5 | Whole-project review/fix/test rounds |
| `SPEC_LOOP_MAX_INNER_ITER` | 10 | Per-task implement/review/fix cap |
| `SPEC_LOOP_TASK_TIMEOUT_SECONDS` | 1800 | Per-task codex wall-clock timeout |
| `SPEC_LOOP_MAX_WALL_SECONDS` | 18000 | Whole-loop wall-clock cap |

## Safety

- Each task runs in an isolated `git worktree` — never run another tool in
  the same repo while a wave is in flight.
- Tasks are atomic; on merge conflict the task is marked failed and left for
  the global round to sort out.
- Codex flags default to `--dangerously-bypass-approvals-and-sandbox`. For
  shared environments, set `SPEC_LOOP_CODEX_FLAGS=--sandbox=workspace-write`.

## If things get stuck

- `/spec-loop:spec-status` — read current state + tasks summary.
- `/spec-loop:spec-cancel` — nuke state and start fresh (commits remain in
  your working tree).

Now execute step 1 (setup) and proceed.
