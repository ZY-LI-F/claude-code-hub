# Convergence Rules

The L2 inner loop exits when `convergence-judge` writes `decision.json` with `converged: true`.
The judgment uses a layered decision tree documented here so behavior is predictable and auditable.

## Hard convergence (preferred path)

All three must hold:
1. **Review verdict**: Codex returned `VERDICT: APPROVED`.
2. **Zero blocking**: No `BLOCKING:` issues in the review.
3. **No unresolved fixes**: `claude-analysis.md` has no pending `accept` dispositions.

This is the normal exit condition when the iteration actually succeeded.

## Oscillation exit (forced)

Tracked via `review_hash_streak` in `state.json`. The fingerprint is
`sha256(sort(grep -iE '^(BLOCKING|IMPORTANT):' review.md))` truncated to 16 chars.

**1-based semantics**: `review_hash_streak` is the count of consecutive identical reviews.

- Streak = 1: first review with this exact issue set.
- Streak = 2: second identical review.
- Streak = 3-4: same issues persisting — tolerated, giving room for legitimate recurrence (a fix introducing a regression that re-exposes the issue, etc.).
- Streak ≥ `SPEC_LOOP_MAX_OSCILLATION_STREAK` (default 5): **5 or more consecutive identical reviews**. The Stop hook force-escalates to L1 (testing will either pass — unlikely — or fail and trigger replan).

Why 5 and not 2? With the relaxed inner budget of 10 iterations, issues can legitimately recur for 2-3 iterations. Five in a row is the minimum that strongly suggests "this inner loop fundamentally cannot make progress on this task." If you want tighter detection, set `SPEC_LOOP_MAX_OSCILLATION_STREAK=3`.

A **soft warning** is appended to the review file starting at streak `SPEC_LOOP_MAX_OSCILLATION_STREAK - 2` (default 3), giving Claude two iterations of notice to change approach before the hard brake fires.

## Budget exit (forced)

`inner_iter + 1 >= SPEC_LOOP_MAX_INNER_ITER`. Default max is 10 (env-overridable).

At this point we converge and let the outer-loop tests be the final arbiter. Tests passing → done. Tests failing → replan.

## Why not just trust the Codex VERDICT?

Because Codex reviews have two known failure modes:
- **Sycophantic approvals** — Codex sometimes stamps APPROVED on a diff that still has issues, especially when the diff is long. Claude's `review-analyst` cross-checks by reading the diff and spec directly.
- **Treadmill of nits** — Codex can cycle through style nits forever. Rule 3 (budget) stops this.

## Logged signals

Every decision writes:
- `decision.json` — the verdict and reasoning
- `state.json.updated_at` — timestamp of the transition
- `spec-loop.log` — INFO line with outcome

These let you reconstruct why the loop converged (or didn't) when debugging.
