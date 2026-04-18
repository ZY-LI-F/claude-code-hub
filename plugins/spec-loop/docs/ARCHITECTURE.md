# spec-loop Architecture

A nested-loop coding harness that pairs Claude Code (planner/analyst) with
Codex CLI (implementer/reviewer) and uses the test suite as the outer-loop gate.

## Inspirations

- **claude-review-loop** (Hamel Husain) — Stop-hook mechanism for auto-triggering Codex review
- **claude-codex** (Z-M-Huang, archived) — multi-agent role division (requirements-gatherer, planner, reviewer, implementer)
- **Meta-Harness** (Lee et al., 2026, arXiv:2603.28052) — filesystem-as-memory for iterative harness optimization; full execution traces available to the proposer
- **ralph-loop** (Anthropic official) — session_id guard and atomic state-file updates

## Three-layer loop

```
┌──────────────────────────────────────────────────────────────────┐
│  L0  Orchestrator (Claude Code main session)                     │
│  Drives the whole thing via the Stop hook + slash commands       │
└──────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────┐
│  L1  Outer loop — test-driven                                    │
│                                                                  │
│    requirements-analyst writes plan.md                           │
│                │                                                 │
│                ▼                                                 │
│    [L2 inner loop runs until convergence]                        │
│                │                                                 │
│                ▼                                                 │
│    run-tests.sh → test-results.json                              │
│                │                                                 │
│         pass?  ├── yes ──► phase=done                            │
│                └── no  ──► phase=planning, outer_iter++          │
└──────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────┐
│  L2  Inner loop — code-review-analyze-revise                     │
│                                                                  │
│    task-decomposer writes task.md                                │
│                │                                                 │
│                ▼                                                 │
│    run-codex-implement.sh  (Codex session A)                     │
│                │                                                 │
│                ▼                                                 │
│    Stop hook fires                                               │
│                │                                                 │
│                ▼                                                 │
│    run-codex-review.sh  (Codex session B, independent)           │
│                │                                                 │
│                ▼                                                 │
│    review-analyst reads review, applies fixes                    │
│                │                                                 │
│                ▼                                                 │
│    convergence-judge writes decision.json                        │
│                │                                                 │
│         converged?                                               │
│                ├── yes ──► phase=testing (return to L1)          │
│                └── no  ──► inner_iter++, back to implement       │
└──────────────────────────────────────────────────────────────────┘
```

## Why two Codex sessions?

Separate `codex exec` invocations for implementation vs review prevent
self-endorsement. The reviewer has no memory of the implementer's
reasoning and judges the diff on its merits. This matches the
producer-reviewer pattern validated in production by claude-codex and
claude-review-loop.

## State model

Everything lives under `.spec-loop/` in the project root:

```
.spec-loop/
├── spec.md                      original requirement (immutable)
├── plan.md                      current plan (rewritten on replan)
├── state.json                   authoritative state machine
├── spec-loop.log                timestamped audit log
├── deferred.md                  findings explicitly deferred
└── iterations/
    ├── outer-001/
    │   ├── test-results.json
    │   └── inner/
    │       ├── iter-000/
    │       │   ├── task.md
    │       │   ├── impl-prompt.md
    │       │   ├── codex-impl.log
    │       │   ├── diff.patch
    │       │   ├── review-prompt.md
    │       │   ├── codex-review.md
    │       │   ├── review-summary.json
    │       │   ├── claude-analysis.md
    │       │   └── decision.json
    │       └── iter-001/
    │           └── ...
    └── outer-002/
        └── ...
```

This filesystem layout is deliberately Meta-Harness-inspired: any future
"optimize the harness itself" step has complete execution traces available.

## Phase state machine

```
idle
  │ setup-spec-loop.sh
  ▼
planning ────────────────────┐
  │ requirements-analyst     │ (on replan from testing)
  │ task-decomposer          │
  ▼                          │
implementing                 │
  │ run-codex-implement.sh   │
  ▼                          │
reviewing                    │
  │ (codex review done)      │
  ▼                          │
addressing                   │
  │ review-analyst           │
  │ convergence-judge        │
  ├── not converged ─► implementing (inner_iter++)
  ▼ converged                │
testing                      │
  │ run-tests.sh             │
  ├── fail ──► planning ─────┘ (outer_iter++)
  └── pass ──► done
```

Two terminal states not shown: `failed` (budget exhausted) and `cancelled` (user ran `/spec-cancel`).

## Safety rails (five-layer hard brakes)

The Stop hook enforces five termination conditions. Every termination writes
`exit_reason` to `state.json`, an ERROR/WARN line to `spec-loop.log`, and a
human-readable explanation to stderr (which Claude sees when exit code is 2).

| Layer | Trigger | Default | Action | exit_reason |
|---|---|---|---|---|
| 1. Wall-clock | `now - created_at > MAX_WALL_SECONDS` | 18000s (5h) | `phase=failed`, exit 0 | `wall_clock_exceeded` |
| 2. Oscillation | `review_hash_streak >= MAX_OSCILLATION_STREAK` | 5 (1-based: 5+ identical reviews) | `phase=testing`, exit 2 | `oscillation` |
| 3. Inner budget | `inner_iter >= MAX_INNER_ITER` | 10 | `phase=testing`, exit 2 | `inner_budget` |
| 4. Outer budget | `outer_iter >= MAX_OUTER_ITER` | 3 | `phase=failed`, exit 0 | `outer_budget` |
| 5. Stuck in testing | `testing_phase_nudges > MAX_TESTING_NUDGES` | 3 (fails on 4th nudge) | `phase=failed`, exit 0 | `stuck_in_testing` |

Layers 1, 4, and 5 are **terminal** (phase=failed, human must intervene).
Layers 2 and 3 are **escalations** — the L1 test gate runs; if tests pass
unexpectedly the loop completes normally, otherwise replan kicks in
(bounded by layer 4).

**With defaults, maximum code-review-revise cycles = 10 × 3 = 30**, or
5 hours of wall-clock, whichever comes first. Every cycle's full trace
is preserved under `.spec-loop/iterations/` for post-mortem.

### Other rails (not termination but important)

- **Session-id guard** in the Stop hook: the hook only acts when fired from the session that initialized the loop. Prevents cross-session interference if you have multiple Claude Code sessions in the same project.
- **stop_hook_active guard**: if Claude Code's own runaway protection kicks in, we don't re-block and cause an infinite pong.
- **Atomic state writes with flock**: temp file + rename, wrapped in a file lock (`flock` on Linux, `mkdir`-based fallback on systems without flock). Prevents half-written JSON and concurrent hook races.
- **Shell-injection-proof state I/O**: `state_get`/`state_set` pass paths and values via Python's `sys.argv`, not via string interpolation into Python source. Values containing `'`, `$(...)`, backticks, or newlines round-trip safely.
- **Heredoc-injection-proof prompt building**: review prompts for Codex are constructed in Python, not bash heredocs. Task specs and diffs containing `$(...)` or backticks are *not* executed.
- **Diff size cap**: review prompts truncate diffs beyond `SPEC_LOOP_MAX_DIFF_BYTES` (default 200KB) to stay under ARG_MAX and keep reviews focused.
- **Portable crypto**: fingerprint uses `sha256sum` on Linux, `shasum -a 256` on macOS, Python `hashlib` as last-resort fallback.
- **Sandbox choice**: `$SPEC_LOOP_CODEX_FLAGS` defaults to `--dangerously-bypass-approvals-and-sandbox`. **Only use in isolated environments.** Safer alternative: `--sandbox workspace-write`.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `SPEC_LOOP_MAX_INNER_ITER` | 10 | Inner-loop iteration cap |
| `SPEC_LOOP_MAX_OUTER_ITER` | 3 | Outer-loop iteration cap |
| `SPEC_LOOP_MAX_WALL_SECONDS` | 18000 | Wall-clock budget (5h) |
| `SPEC_LOOP_MAX_OSCILLATION_STREAK` | 5 | 1-based: trip at 5+ identical reviews |
| `SPEC_LOOP_MAX_TESTING_NUDGES` | 3 | Fail the loop after 4th nudge without tests running |
| `SPEC_LOOP_MAX_DIFF_BYTES` | 204800 | Diff size cap for review prompt |
| `SPEC_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex exec` |
| `CLAUDE_PROJECT_DIR` | (set by Claude Code) | Project root |
| `CLAUDE_PLUGIN_ROOT` | (set by Claude Code) | Plugin install dir |
