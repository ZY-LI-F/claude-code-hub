# Plugins

Each subdirectory here is a standalone [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins). The repo's `.claude-plugin/marketplace.json` lists them under `plugins[]`, so installing the marketplace exposes everything in this directory as `/plugin install <name>@claude-code-hub`.

## Current plugins

### [`spec-loop`](spec-loop/)

Nested-loop coding harness: Claude plans the task and judges convergence, Codex does implementation and review (separate sessions — no self-endorsement), the project's test suite gates the outer loop, and hooks enforce iteration / wall-clock / oscillation budgets.

- Install: `/plugin install spec-loop@claude-code-hub`
- Commands: `/spec-loop:spec-start`, `/spec-loop:spec-status`, `/spec-loop:spec-cancel`, `/spec-loop:spec-replan`
- Requires: Node ≥18, `codex` CLI, Python 3.7+
- Docs: [`spec-loop/README.md`](spec-loop/README.md), [`spec-loop/INSTALL.md`](spec-loop/INSTALL.md)
- Smoke test: `bash spec-loop/tests/smoke-test.sh`

## Adding a new plugin

1. Create `plugins/<plugin-name>/` with:
   - `.claude-plugin/plugin.json` — see minimal schema below.
   - `README.md` — at minimum: what it does, install command, command list, dependencies.
   - `LICENSE` — only if derivative / upstream attribution is needed; otherwise the root MIT applies.
2. Append an entry to `.claude-plugin/marketplace.json`:
   ```json
   {
     "name": "<plugin-name>",
     "description": "One-liner — what does it do.",
     "version": "0.1.0",
     "source": "./plugins/<plugin-name>",
     "category": "development",
     "homepage": "https://github.com/ZY-LI-F/claude-code-hub"
   }
   ```
3. Add a row to the table in [`../README.md`](../README.md) and to the section list above.
4. Validate before committing:
   ```bash
   claude plugin validate .                    # marketplace
   claude plugin validate plugins/<plugin-name>    # plugin
   ```

### Minimal `plugin.json`

```json
{
  "name": "<plugin-name>",
  "version": "0.1.0",
  "description": "One-line description.",
  "author": { "name": "<your-name>" }
}
```

Claude Code auto-discovers `commands/`, `agents/`, and `hooks/hooks.json` by convention — **do not** declare them explicitly in `plugin.json` or validation will fail.

### Conventions used in this repo

- **Hooks**: place in `hooks/`, register in `hooks/hooks.json`. Use absolute helper-script paths via `${CLAUDE_PLUGIN_ROOT}`, not relative paths.
- **Commands**: one `.md` per command in `commands/`. Filename becomes the command name (namespaced as `<plugin>:<name>`).
- **Agents**: one `.md` per agent in `agents/` with standard Claude Code frontmatter.
- **Shell scripts**: `set -euo pipefail` at top (or `-uo` if tolerating nonzero exits on purpose, like a test runner). Use `<<'PY'` + argv for any embedded Python; never interpolate shell variables into Python source. See `spec-loop/scripts/lib-state.sh` for a reference state layer.
- **Cross-platform**: export `PYTHONUTF8=1` in any shared library a plugin sources — Python on Windows defaults to cp1252/cp936 and breaks on non-ASCII file I/O.
- **Smoke test**: every plugin ships `tests/smoke-test.sh` that exercises the main flow without invoking the LLM or any paid API.
