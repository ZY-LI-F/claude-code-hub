---
description: Start a spec-loop — Claude plans, Codex implements & reviews, tests gate the outer loop.
argument-hint: "<requirement description>"
---

You are starting a **spec-loop**: a nested-loop harness where you are the orchestrator (L0 + L1 analysis/judgment) and Codex is the worker (L2 implementation + review).

## Boot sequence

1. **Initialize state**. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-spec-loop.sh" "$CLAUDE_SESSION_ID" "$ARGUMENTS"
   ```
   This creates `.spec-loop/` under the project root, captures the spec, and auto-detects the scenario.

2. **Read context**. View:
   - `.spec-loop/spec.md` — the raw requirement
   - `.spec-loop/state.json` — current state (scenario detected)
   - `${CLAUDE_PLUGIN_ROOT}/docs/ARCHITECTURE.md` — how the harness works
   - the scenario template at `${CLAUDE_PLUGIN_ROOT}/templates/task-<scenario>.md`

3. **Plan phase (L1 — you are the analyst)**. Consult the `requirements-analyst` agent to produce `.spec-loop/plan.md` with:
   - Requirement summary (in your words)
   - Acceptance criteria (how we'll know it's done)
   - Test plan (what tests will gate the outer loop)
   - Task breakdown — ordered list of atomic tasks

4. **Decompose**. Consult the `task-decomposer` agent. For the first task, write the detailed task spec to:
   `.spec-loop/iterations/outer-001/inner/iter-000/task.md`
   and update state:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh" && \
            state_set phase implementing \
                      current_task ".spec-loop/iterations/outer-001/inner/iter-000/task.md"'
   ```

5. **Delegate to Codex**. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex-implement.sh" ".spec-loop/iterations/outer-001/inner/iter-000"
   ```
   This produces a code change in the working tree and writes `codex-impl.log`.

6. **Stop**. When you finish this turn, the **Stop hook** fires and will automatically trigger a Codex review. You'll be woken up again to address the feedback. Don't try to run the review yourself — let the hook do it.

## Loop contract (read carefully)

The Stop hook manages the L2 inner loop. On each wake-up it will tell you what phase you're in and what it expects next. Your obligations:

- When woken after **Codex review**, consult `review-analyst`, make fixes, then write `.spec-loop/iterations/outer-<N>/inner/iter-<M>/claude-analysis.md`.
- Before stopping, consult `convergence-judge` and write `decision.json` with `{"converged": bool, "reasoning": "..."}`. The hook needs this to decide iterate-vs-advance.
- When moved to **testing phase**, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-tests.sh"`, then stop. The hook will read test results and either declare success or kick off a replan.

## Safety reminders

- `SPEC_LOOP_MAX_INNER_ITER=10`, `SPEC_LOOP_MAX_OUTER_ITER=3` by default (up to 30 code-review cycles total, or 5 hours wall-clock). Override via env vars if needed.
- Codex runs with `--dangerously-bypass-approvals-and-sandbox` by default. **Only use in isolated environments.** Override via `SPEC_LOOP_CODEX_FLAGS=--sandbox=workspace-write`.
- Never edit `.spec-loop/state.json` by hand unless recovering from a stuck loop — use `state_set` via `lib-state.sh`.

Now execute step 1 (setup), then proceed.
