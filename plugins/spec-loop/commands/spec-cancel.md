---
description: Cancel the active spec-loop and release the Stop hook.
---

Run:

```bash
bash -c '
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh"
if state_exists; then
  # Archive the state file instead of deleting (for debugging)
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mv "${SPEC_LOOP_STATE}" "${SPEC_LOOP_DIR}/state.json.cancelled.${ts}"
  echo "Spec-loop cancelled. State archived to state.json.cancelled.${ts}"
else
  echo "No active spec-loop to cancel."
fi
'
```

Then tell the user: "spec-loop cancelled. You can start a new one with `/spec-start`."
