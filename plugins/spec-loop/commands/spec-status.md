---
description: Show current spec-loop status (phase, iterations, recent findings).
---

Run:

```bash
bash -c '
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh"
if ! state_exists; then
  echo "No active spec-loop in this project."
  exit 0
fi
echo "=== spec-loop status ==="
echo "Phase:        $(state_get phase)"
echo "Scenario:     $(state_get scenario)"
echo "Outer iter:   $(state_get outer_iter) / ${SPEC_LOOP_MAX_OUTER_ITER}"
echo "Inner iter:   $(state_get inner_iter) / ${SPEC_LOOP_MAX_INNER_ITER}"
echo "Osc. streak:  $(state_get review_hash_streak)"
echo "Current task: $(state_get current_task)"
echo "Updated at:   $(state_get updated_at)"
echo
echo "=== Recent log (last 20 lines) ==="
tail -n 20 "${SPEC_LOOP_LOG}" 2>/dev/null || echo "(no log yet)"
echo
echo "=== Iterations directory ==="
if [[ -d "${SPEC_LOOP_ITER_DIR}" ]]; then
  find "${SPEC_LOOP_ITER_DIR}" -maxdepth 4 -type f -name "*.md" -o -name "*.json" 2>/dev/null | sort
fi
'
```

Then briefly summarize for the user:
- What phase we're in
- What artifacts exist
- What the next expected action is (implementing? addressing review? waiting for tests?)
