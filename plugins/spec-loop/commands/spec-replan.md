---
description: Manually trigger a replan — useful when you want to revise the plan without waiting for a test failure.
---

Force the spec-loop into planning phase for a new outer iteration.

Run:

```bash
bash -c '
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh"
if ! state_exists; then
  echo "No active spec-loop. Run /spec-start first."
  exit 1
fi
CURRENT=$(state_get outer_iter); CURRENT=${CURRENT:-0}
NEXT=$((CURRENT + 1))
state_set phase planning outer_iter "$NEXT" inner_iter 0 review_hash_streak 0 last_review_hash ""
mkdir -p "${SPEC_LOOP_ITER_DIR}/outer-$(printf %03d $NEXT)"
echo "Transitioned to outer_iter=$NEXT, phase=planning."
echo "Existing plan.md is preserved — edit or rewrite it."
'
```

Then:
1. Read `.spec-loop/plan.md` and any `.spec-loop/iterations/outer-<N-1>/test-results.json`.
2. Invoke the `requirements-analyst` agent to produce a revised plan.
3. Proceed with task decomposition and set phase back to `implementing`.
