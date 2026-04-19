---
description: "Rebind the current Claude Code session id into the active spec-loop state.json. Use after restarting Claude Code mid-loop — otherwise the Stop hook's session guard will silently allow exit and the loop won't advance."
argument-hint: ""
---

Run this exact shell when `spec-loop:spec-status` shows a stale session id
or when the Stop hook never seems to fire after a Claude Code restart:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/spec-rebind.sh" "$CLAUDE_SESSION_ID"
```

This writes the current session id into `.spec-loop/state.json` so the
Stop hook's `session_matches` guard starts passing again. No other state
is touched; the loop resumes from whatever phase it was in.

If `$CLAUDE_SESSION_ID` is empty in your shell (rare), pass the session
id explicitly — it's the base name of the most-recently-modified jsonl
under `~/.claude/projects/<encoded-project-path>/`.
