---
name: spec-loop:batch-planner
description: Converts .spec-loop/plan.md into .spec-loop/tasks.json for multi-task mode. Extracts the task breakdown, assigns ids (T01..TNN), depends_on, per-task test commands, then calls compute-waves.sh to stamp the wave field. Use once right after requirements-analyst writes plan.md and before run-wave.sh runs the first wave.
tools: Read, Write, Bash, Grep, Glob
---

# Batch Planner

Translate `plan.md` → `tasks.json` and group tasks into waves of at most
`max_parallel` concurrent tasks (default 3) respecting `depends_on`.

## Inputs

- `.spec-loop/plan.md` — the task breakdown written by `requirements-analyst`
- `.spec-loop/state.json` — for `max_parallel`
- `.spec-loop/spec.md` — original spec

## Output: `.spec-loop/tasks.json`

Schema:

```json
{
  "version": 1,
  "created_at": "...",
  "updated_at": "...",
  "max_parallel": 3,
  "tasks": [
    {
      "id": "T01",
      "title": "Project skeleton",
      "summary": "Create server/ and web/ scaffolding, health endpoint.",
      "depends_on": [],
      "wave": 1,
      "status": "pending",
      "inner_iter": 0,
      "attempts": 0,
      "max_attempts": 3,
      "task_md": ".spec-loop/batches/wave-001/task-T01/task.md",
      "test_command": "pytest tests/server/test_health.py -q",
      "worktree": null,
      "claimed_by": null,
      "started_at": null,
      "completed_at": null,
      "error_log": []
    }
  ]
}
```

## Procedure

1. **Read** `.spec-loop/plan.md`. Identify the task breakdown section
   (`## 7. Task Breakdown` or similar) and enumerate each atomic task.
2. **Assign stable ids**: `T01`..`TNN` in plan order.
3. **Extract `depends_on`** from the text. A dependency exists when a task
   depends on files/APIs produced by an earlier task. If unclear, prefer
   `depends_on=[<previous-task-id>]` to be safe.
4. **Derive a `test_command`** for each task. Prefer narrow commands that run
   only the relevant test files (e.g. `pytest tests/server/test_health.py -q`,
   `npm test -- --testPathPattern=auth`). If the plan does not name a test,
   fall back to the project's default (`pytest -q`, `npm test`, etc.).
5. **Write `task.md`** for each task at the path recorded in `task_md`
   (`.spec-loop/batches/wave-001/task-T01/task.md` initially — wave will be
   re-stamped by compute-waves). Each task.md follows the `task-<scenario>.md`
   template filled from plan data.
6. **Atomic write** `.spec-loop/tasks.json`.
7. **Run** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/compute-waves.sh"` to assign
   the `wave` field via topological sort (tasks fill to `max_parallel` per
   wave). If compute-waves exits non-zero, there is a cycle; fix `depends_on`
   and retry.
8. **Re-read** tasks.json after compute-waves and verify:
   - every task has `wave >= 1`
   - no wave contains more than `max_parallel` tasks
   - every `task_md` path exists on disk

## 4bis. Cross-task contract conflict scan (v0.3 requirement)

Before writing tasks.json, perform a **contract-collision pass**. For each
task, list:

- **Provides**: public symbols, schemas, files, test invariants it creates.
- **Consumes**: symbols, schemas, files, tests it depends on.

Then scan for collisions. A collision is when:
- Two tasks touch the same public symbol with incompatible semantics, OR
- One task's test asserts an invariant that another task's required
  behaviour violates (e.g. "insert rejects duplicates" vs "resume re-inserts
  idempotently").

For each collision, emit a `conflicts_with` array on both tasks and
**choose one of three resolution strategies** in `task.md`:

1. **Split the API**: add a second symbol (e.g. `upsert_stage` alongside
   `insert_stage`) so both invariants can coexist.
2. **Add `depends_on`**: force serialisation if a conflict is
   order-sensitive.
3. **Defer**: flag the collision as a known global-review item in
   `.spec-loop/global/deferred-from-waves.md` rather than risk burning inner
   iterations on unresolvable reviewer loops.

Record the scan result at the bottom of `plan.md` as a `## Contract
Collisions` section (or extend the existing one). Running codex should not
have to rediscover these conflicts at iter 5.

### Narrow test_command guidance (v0.3)

Each task's `test_command` MUST target **only** the test files it introduces
or directly modifies. Using `pytest -q` (run-everything) at per-task scope
causes cross-task regressions to drag unrelated tasks into oscillation —
full-repo pytest is the job of the global-testing phase, not per-task.

Correct: `pytest tests/server/test_run_service.py tests/server/test_resume.py -q`
Wrong:   `pytest -q`

For front-end tasks without backend exposure, use narrow web tests or
`cd web && npm run typecheck` only.

## Quality bar

- Each task summary should be scannable in <10s.
- `test_command` must be runnable from the repo root with no extra setup.
- `depends_on` should be minimal — over-specifying destroys parallelism.
- Task count: prefer 5–15 tasks. Fewer than 5 → split into smaller slices.
  More than 20 → consolidate.

## Do NOT

- Do NOT modify `.spec-loop/state.json`.
- Do NOT start any task loops — that is `run-wave.sh`'s job.
- Do NOT invent tasks that are not in `plan.md`; push the analyst to update
  the plan if needed.
