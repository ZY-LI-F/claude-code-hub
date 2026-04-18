# spec-loop

A Claude Code plugin that runs a **nested-loop coding harness**:
Claude Code plans and analyzes, Codex implements and reviews, the test suite gates the outer loop.

Inspired by [claude-review-loop](https://github.com/hamelsmu/claude-review-loop), [claude-codex](https://github.com/Z-M-Huang/claude-codex), and the [Meta-Harness paper](https://arxiv.org/abs/2603.28052) (Lee et al., 2026).

## What it does

```
spec  →  plan  →  ┌── task ─→ Codex implement ─→ Codex review ─→ Claude analyze ─→ iterate?
                  │                                                                   │
                  └────────────────  [L2 inner loop, up to 5×]  ────────────────────┘
                                                │ converged
                                                ▼
                                           run tests
                                                │
                                     pass? ────┴──── fail? ─→ replan ─→ [L1 outer loop, up to 3×]
                                                                             │
                                                                             ▼
                                                                            done
```

You describe a requirement. spec-loop plans it, delegates to Codex, Codex reviews its own work, Claude cross-checks the review, fixes land, tests run, tests gate completion.

## Requirements

- [Claude Code](https://claude.ai/code) CLI
- [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- `python3` (for JSON state handling — no `jq` dependency)
- `git` (for diff capture)
- A supported test framework: pytest, npm test, go test, cargo test, or a `Makefile` with a `test` target

## Install

```bash
# From a local checkout
claude --plugin-dir /path/to/spec-loop

# From GitHub (once published)
claude plugin install spec-loop@github:<your-handle>/spec-loop
```

## Usage

```bash
# Start a loop
/spec-start Implement a fibonacci(n) function with edge-case handling and pytest tests.

# Check progress at any time
/spec-status

# Manually force a replan (rare — usually the test gate does this automatically)
/spec-replan

# Bail out
/spec-cancel
```

Then let Claude work. The Stop hook orchestrates the loop — you mostly watch.

## Configuration

All env vars; override before invoking `claude`:

| Variable | Default | Meaning |
|---|---|---|
| `SPEC_LOOP_MAX_INNER_ITER` | `10` | Max code-review-revise cycles per task |
| `SPEC_LOOP_MAX_OUTER_ITER` | `3` | Max test-driven replans (10×3=30 cycles total) |
| `SPEC_LOOP_MAX_WALL_SECONDS` | `18000` | Overall wall-clock budget (5 hours) |
| `SPEC_LOOP_MAX_OSCILLATION_STREAK` | `5` | 1-based: force L1 escalation at 5+ consecutive identical reviews |
| `SPEC_LOOP_MAX_TESTING_NUDGES` | `3` | Max "please run tests" reminders before declaring loop stuck |
| `SPEC_LOOP_MAX_DIFF_BYTES` | `204800` | Diff size cap for review prompt (truncates beyond 200KB) |
| `SPEC_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags for `codex exec` |

### Sandbox warning

The default `SPEC_LOOP_CODEX_FLAGS` grants Codex full access to run any
command. **Only use in isolated environments** (container, VM, disposable
worktree). For shared or production repos, override:

```bash
export SPEC_LOOP_CODEX_FLAGS="--sandbox workspace-write"
```

## How it handles your three scenario types

| Scenario | Detected by | Task template emphasis |
|---|---|---|
| **CRUD / API / UI** | keywords: endpoint, route, form, ui, api... | interface contracts, HTTP codes, integration tests |
| **algorithm / script** | keywords: algorithm, compute, given an array... | edge cases, complexity, property-based tests |
| **bug fix / refactor** | keywords: bug, fix, regression, refactor... | RCA-first, minimality, regression test required |
| **generic** | fallback | acceptance criteria + tests |

Detection is heuristic; you can override by editing `.spec-loop/state.json`'s `scenario` field right after `/spec-start` if you disagree with the auto-detection.

## Smoke test

A ~50-line smoke test is in `tests/smoke-test.sh`. It exercises the state machine and hook dispatch without needing a real Codex invocation. Run it after install to verify the harness itself is wired correctly:

```bash
bash tests/smoke-test.sh
```

## File layout

```
spec-loop/                           ← this plugin
├── .claude-plugin/plugin.json
├── hooks/
│   ├── hooks.json
│   ├── stop-hook.sh                 ← L2 state machine
│   └── post-test-hook.sh
├── scripts/
│   ├── lib-state.sh                 ← shared state lib
│   ├── setup-spec-loop.sh
│   ├── run-codex-implement.sh       ← Codex session A
│   ├── run-codex-review.sh          ← Codex session B
│   ├── analyze-review.sh
│   ├── run-tests.sh                 ← framework auto-detect
│   ├── detect-scenario.sh
│   └── check-budget.sh
├── commands/
│   ├── spec-start.md
│   ├── spec-status.md
│   ├── spec-cancel.md
│   └── spec-replan.md
├── agents/
│   ├── requirements-analyst.md
│   ├── task-decomposer.md
│   ├── review-analyst.md
│   └── convergence-judge.md
├── templates/
│   ├── task-crud.md
│   ├── task-algorithm.md
│   ├── task-bugfix.md
│   ├── task-generic.md
│   └── review-schema.md
├── docs/
│   ├── ARCHITECTURE.md              ← read this to understand the design
│   └── CONVERGENCE.md
├── tests/smoke-test.sh
├── AGENTS.md
├── CLAUDE.md                        ← symlink → AGENTS.md
├── LICENSE                          ← MIT
└── README.md
```

Runtime artifacts (inside user projects):

```
<project>/.spec-loop/
├── spec.md
├── plan.md
├── state.json
├── spec-loop.log
└── iterations/outer-NNN/inner/iter-MMM/
    ├── task.md            ← decomposed task for Codex
    ├── codex-impl.log
    ├── diff.patch
    ├── codex-review.md
    ├── review-summary.json
    ├── claude-analysis.md
    └── decision.json
```

## Credits and license

- Stop-hook mechanism inspired by Hamel Husain's [claude-review-loop](https://github.com/hamelsmu/claude-review-loop).
- Multi-agent role design inspired by Z-M-Huang's [claude-codex](https://github.com/Z-M-Huang/claude-codex).
- Filesystem-as-memory principle from [Meta-Harness](https://arxiv.org/abs/2603.28052).
- Session-id guard and atomic state patterns from Anthropic's official [ralph-wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum).

MIT licensed. See `LICENSE`.
