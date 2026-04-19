# spec-loop v0.2 — Multi-Task Parallel Architecture

v0.2 is a superset of v0.1: single-task mode (`/spec-loop:spec-start`) is
preserved unchanged. A new **multi-task mode** (`/spec-loop:multi-start`)
adds a L1 scheduler that fans out up to `max_parallel` atomic tasks per wave
and finishes with a whole-project review/fix/test loop. Inspired by the
`harness` skill's task DAG and by the existing spec-loop L2 code-review loop.

## When to use which

| Scenario | Mode | Entry |
|---|---|---|
| Single feature, bug fix, one-file refactor | single | `/spec-loop:spec-start` |
| Multi-component delivery, many tests, parallelizable tasks | multi | `/spec-loop:multi-start` |

## Layered model (multi mode)

```
L0  Claude Code                              (orchestrator)
        │
        ▼
L1a Wave scheduler                            (new in v0.2)
     · tasks.json = DAG of atomic tasks
     · compute-waves.sh → wave=1..N, each ≤ max_parallel
     · run-wave.sh: git worktree per task, bash & + wait, merge on success
        │
        ▼ (each wave spawns)
L2  Single-task self-driving loop             (new, wraps L2 primitives)
     · run-task-loop.sh
     · codex implement → codex review → [fix] → task test_command
     · repeats up to MAX_INNER_ITER
        │
        ▼ (all waves done)
L1b Global review loop                        (new in v0.2)
     · codex reviews the whole diff vs multi_base_commit
     · global-review-analyst triages → accept | fix | fail
     · codex applies fixes (if needed)
     · run-global-test.sh gates the round
     · repeats up to MAX_GLOBAL_ROUNDS
        │
        ▼
    done | failed
```

## State machine (multi)

```
task-planning
   ↓ (requirements-analyst + batch-planner done)
wave-running  ──(wave done; more waves remain)──► wave-running (next wave)
   ↓ (last wave done)
global-review
   ↓ (codex review file exists)
global-addressing
   ├── accept ──► global-testing
   ├── fix    ──► global-fixing ──► global-testing
   └── fail   ──► failed
global-testing
   ├── pass ──► done
   └── fail + round<max ──► global-review (round++)
   └── fail + round=max ──► failed
```

Pass-through phases (same as single mode):
- `idle`, `done`, `failed`
- Hard-brake phases (oscillation/budget) reuse the same layered safety rails
  as single mode.

## Filesystem layout (multi)

```
.spec-loop/
├── spec.md                original requirement
├── plan.md                planner output
├── tasks.json             DAG (new in v0.2)
├── state.json             mode, phase, current_wave, global_round, …
├── spec-loop.log
├── batches/               per-wave artifacts (new)
│   └── wave-001/
│       ├── wave.log
│       ├── task-T01.log    run-task-loop.sh stdout
│       └── task-T01/
│           ├── worktree/             git worktree (cleaned on success)
│           ├── task.md
│           ├── task-state.json       per-task L2 state
│           ├── iter-000/
│           │   ├── impl-prompt.md
│           │   ├── codex-impl.log
│           │   ├── diff.patch
│           │   ├── review-prompt.md
│           │   ├── codex-review.md
│           │   ├── test-output.log
│           │   └── test-results.json
│           └── iter-001/...
└── global/                            whole-project rounds (new)
    └── round-001/
        ├── review-prompt.md
        ├── codex-review.md
        ├── diff.patch
        ├── claude-analysis.md
        ├── decision.json
        ├── fix-prompt.md
        ├── codex-fix.log
        ├── test-output.log
        └── test-results.json
```

## tasks.json schema

See `scripts/lib-tasks.sh` header for the full schema. Required fields per
task: `id, title, depends_on, wave, status, task_md, test_command`.
`status` progresses: `pending → running → done | failed`.

## Parallelism mechanics

1. `compute-waves.sh` groups tasks into waves: start with indegree==0,
   take up to `max_parallel`, then unlock dependents.
2. `run-wave.sh` creates one git worktree per in-wave task
   (`spec-loop/wave-N/task-TXX` branch from `multi_base_commit`).
3. `bash &` + `wait` semaphore caps concurrent codex subprocesses.
4. On task success, its branch is merged back onto the main branch via
   `git merge --no-ff --no-edit`. On conflict, the merge is aborted and the
   task is marked `failed` — the global loop handles the leftover diff.
5. Worktrees for `done` tasks are removed; failed task worktrees stay for
   forensic inspection.

## Global loop mechanics

1. `run-global-review.sh` builds the diff `multi_base_commit..HEAD` and asks
   codex to produce a structured review ending in a `VERDICT` line.
2. `spec-loop:global-review-analyst` agent reads the review, writes
   `claude-analysis.md` + `decision.json` (`action: accept|fix|fail`).
3. On `fix`, `run-global-fix.sh` re-enters codex with the review as context;
   codex commits the patch.
4. `run-global-test.sh` runs the whole project test suite and writes
   `test-results.json`.
5. Pass → `phase=done`. Fail and `round < max_global_rounds` → `round++`,
   new review. Fail and at budget → `phase=failed`.

## Budgets

| Variable | Default | Scope |
|---|---|---|
| `SPEC_LOOP_MAX_PARALLEL` | 3 | wave concurrency |
| `SPEC_LOOP_MAX_GLOBAL_ROUNDS` | 5 | global review/fix/test rounds |
| `SPEC_LOOP_MAX_INNER_ITER` | 10 | per-task implement/review iterations |
| `SPEC_LOOP_TASK_TIMEOUT_SECONDS` | 1800 | per `codex exec` wall-clock |
| `SPEC_LOOP_MAX_WALL_SECONDS` | 18000 | outer wall-clock (shared with v0.1) |

## Compatibility

- Existing `state.json` files (no `mode` field) are treated as
  `mode=single`. All v0.1 commands and scripts behave unchanged.
- `stop-hook.sh` dispatches by `state_mode()`; the single-mode path is the
  original code, byte-identical except for the new dispatch preamble.

## Known limitations (v0.2 initial cut)

- Merge conflicts between parallel tasks fall through to the global loop
  without being surfaced upstream to Claude before termination.
- `run-wave.sh` blocks the caller's Bash tool for the full wave duration;
  if a wave exceeds the Claude Bash tool's 600 s limit, launch it via
  `run_in_background` and poll `tasks.json`.
- `git worktree` requires a clean working tree in the main repo at wave
  launch; uncommitted changes outside `.spec-loop/` may break the merge
  step.
