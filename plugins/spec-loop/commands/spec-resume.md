---
description: "Re-enter a spec-loop that tripped a safety rail (wall-clock, inner budget, paused). Keeps all completed waves / rounds; resets the clock; sets phase to the first non-terminal step."
argument-hint: ""
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/spec-resume.sh"
```

`spec-resume` recomputes the first non-terminal wave (from tasks.json) and
puts the loop back onto it. For already-all-waves-done state, it inspects
`.spec-loop/global/round-NNN/` artifacts and re-enters `global-review`,
`global-fixing`, `global-testing`, or `done` depending on what's present.

Unlike `/spec-loop:spec-cancel` this does NOT delete any state — safe to
run any time the loop looks stuck.
