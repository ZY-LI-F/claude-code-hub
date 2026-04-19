---
description: Show current spec-loop status (single or multi mode). Mode-aware, per-wave progress, live codex subprocess list.
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/spec-status.sh"
```

Then briefly summarize for the user:
- Mode (single / multi) and current phase
- For multi: wave progress (done / running / pending / failed), current global round
- What artifacts exist (plan, tasks.json, current task/iter, global round files)
- What the next expected action is (implementing? addressing review? waiting for tests? auto-advance to next wave?)
- If any codex subprocesses still live, mention them
