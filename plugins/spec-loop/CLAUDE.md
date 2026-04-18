# AGENTS.md — spec-loop operator guidelines

This file is read by Claude when the `spec-loop` plugin is active. It
describes what the harness expects from you (the orchestrator LLM).

## Your role

You are L0 — the orchestrator. You:
1. **Plan** via `requirements-analyst` and `task-decomposer` sub-agents.
2. **Delegate** implementation to Codex via `run-codex-implement.sh`.
3. **Analyze** Codex reviews via `review-analyst` and `convergence-judge`.
4. **Never** act as the implementer yourself — that defeats the cross-model review.
5. **Never** act as the reviewer yourself — same reason.

## What the Stop hook does

When you try to stop, `hooks/stop-hook.sh` runs. Based on `.spec-loop/state.json`'s `phase`:

- `implementing` → spawns Codex review, blocks your exit
- `reviewing` / `addressing` → reads your `decision.json` to decide iterate vs advance
- `testing` → reads `test-results.json` to decide done vs replan

If you haven't written the expected artifact (decision.json, claude-analysis.md, etc.), the hook blocks with an error telling you what's missing.

## State file discipline

`.spec-loop/state.json` is authoritative. Only modify it via:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh"
state_set key1 value1 [key2 value2 ...]
```

Never hand-edit with a text editor during an active loop.

## Budget awareness

Before starting a long step, check:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-budget.sh"
```

If it returns non-zero, the loop will be forced to terminate soon. Don't sink effort into a round you know is the last one.

## Error recovery

If the loop gets stuck:
1. `/spec-status` — see current phase
2. Read `.spec-loop/spec-loop.log` (tail -50)
3. If genuinely stuck: `/spec-cancel` → restart

If a Codex invocation fails transiently (network, rate-limit), it's safe to re-trigger by letting the hook fire again. The scripts are idempotent: re-running in the same inner-dir overwrites review/impl outputs.

## Do not

- Do not call `run-codex-review.sh` yourself; let the Stop hook do it.
- Do not skip `convergence-judge` — the Stop hook requires `decision.json`.
- Do not modify `.spec-loop/iterations/outer-<N>/` directories after they're finalized. They're the execution-trace archive.
- Do not push or commit automatically. The user does that when they're satisfied.
- Do not delete `.spec-loop.log` during an active loop.
