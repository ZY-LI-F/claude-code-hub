# Installing spec-loop

## Prerequisites

```bash
# Required
node --version       # >= 18
claude --version     # Claude Code CLI installed and authenticated
python3 --version    # for JSON state handling
git --version        # for diff capture

# Required for real loops (optional for smoke test)
codex --version      # OpenAI Codex CLI; install: npm install -g @openai/codex
```

Claude Code install (if not already done):
```bash
npm install -g @anthropic-ai/claude-code
claude login
```

Codex CLI install:
```bash
npm install -g @openai/codex
codex login   # or set OPENAI_API_KEY
```

## Install spec-loop (three steps)

### 1. Unpack the tarball

```bash
# Assuming you downloaded spec-loop-marketplace.tar.gz
tar xzf spec-loop-marketplace.tar.gz
cd spec-loop-marketplace
```

You should see:
```
spec-loop-marketplace/
├── .claude-plugin/marketplace.json
└── plugins/spec-loop/
    ├── .claude-plugin/plugin.json
    ├── hooks/
    ├── scripts/
    ├── commands/
    ├── agents/
    ├── templates/
    ├── docs/
    └── tests/
```

### 2. Verify the plugin works (smoke test)

Run **before** installing into Claude Code to catch any environment issues early:

```bash
bash plugins/spec-loop/tests/smoke-test.sh
```

Expected output ends with:
```
==========================================
  Passed: 27  (or 29 if pytest is installed)
  Failed: 0
==========================================
```

If failures appear, fix them before proceeding — they'll also fail inside Claude Code.

### 3. Register as a Claude Code marketplace and install

Launch Claude Code:

```bash
claude
```

Then inside the Claude Code session, run these slash commands:

```
/plugin marketplace add /absolute/path/to/spec-loop-marketplace
```

Example on macOS/Linux:
```
/plugin marketplace add /Users/you/spec-loop-marketplace
```

Example on Windows (PowerShell/WSL):
```
/plugin marketplace add C:\Users\you\spec-loop-marketplace
```

Then install the plugin:

```
/plugin install spec-loop@claude-code-hub
```

Claude Code will copy the plugin into its cache and activate it.

Restart or reload:
```
/reload-plugins
```

### 4. Verify activation

```
/plugin list
```

You should see `spec-loop` in the Installed tab. The registered commands are:
- `/spec-loop:spec-start`
- `/spec-loop:spec-status`
- `/spec-loop:spec-cancel`
- `/spec-loop:spec-replan`

> ⚠️ Because of how Claude Code namespaces plugin commands, you may need to use the full `/spec-loop:spec-start` form. The bare `/spec-start` only works inside the plugin's own context.

## First run

In any project directory where you want to use spec-loop:

```bash
cd /path/to/your/project
claude
```

Inside Claude Code:

```
/spec-loop:spec-start Write an is_prime(n: int) -> bool function that handles n<=1, with pytest tests covering 0/1/2/small primes/composites and a large prime.
```

Claude will:
1. Initialize `.spec-loop/` in your project
2. Detect scenario: `algorithm`
3. Produce `plan.md` and first `task.md`
4. Run `codex exec` to implement
5. When you try to stop, the Stop hook triggers `codex exec` review
6. You're asked to analyze the review and address findings
7. Convergence judged → tests run → done (or replan)

## Environment knobs

Set these before launching `claude` if you want different defaults:

```bash
# Sandbox (default is danger-full-access per your setup choice)
export SPEC_LOOP_CODEX_FLAGS="--dangerously-bypass-approvals-and-sandbox"
# Safer alternative for shared repos:
# export SPEC_LOOP_CODEX_FLAGS="--sandbox workspace-write"

# Budgets
export SPEC_LOOP_MAX_INNER_ITER=5
export SPEC_LOOP_MAX_OUTER_ITER=3
export SPEC_LOOP_MAX_WALL_SECONDS=7200
```

## Uninstall

```
/plugin uninstall spec-loop@claude-code-hub
/plugin marketplace remove claude-code-hub
```

## Troubleshooting

### "plugin not found after install"
Clear the plugin cache and reinstall:
```bash
rm -rf ~/.claude/plugins/cache
```
Then run `/plugin install` again.

### "Stop hook doesn't fire"
Check `~/.claude/plugins/cache/claude-code-hub/spec-loop/<version>/hooks/hooks.json` exists — Claude Code copies the plugin on install, so your working directory changes won't take effect until you reinstall.

For iterative development on the plugin itself, every edit requires:
```
/plugin marketplace update claude-code-hub
```

### "commands not showing in autocomplete"
Plugin commands don't show in autocomplete until you type the full name. The text turns blue once Claude Code recognizes it.

### state.json corruption
Rare but possible if the Stop hook was killed mid-write. Recover:
```bash
cd your-project
mv .spec-loop/state.json .spec-loop/state.json.broken
# then manually `/spec-loop:spec-start` again
```

All execution traces in `.spec-loop/iterations/` are preserved.
