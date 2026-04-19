# Post-mortem: v0.3 → v0.4 (tests-first + slice-based global review)

## What v0.3 got wrong

v0.3 auto-ran `run-codex-review.sh` after every codex implement and used
the reviewer's `VERDICT` line to gate convergence. In practice on the
PaperBanana project:

- **~90% of reviewer findings were false positives** produced by the
  "git diff HEAD only sees tracked files" bug. Codex repeatedly said
  "file X is not implemented" for files that existed but hadn't been
  `git add`-ed yet.
- **~70% of wall-clock time** was spent by Claude hand-writing
  `claude-analysis.md` reasoning down BLOCKING findings that weren't
  actually blocking.
- **Global review drifted into essay mode**. gpt-5-codex with a
  200 KB diff + long Chinese spec produced an 8054-line "complexity
  transfer ledger" methodology article, zero structured findings, no
  VERDICT line. The analyst agent had to evaluate the delivery
  independently every time — review was decorative.

## What v0.4 changes

### 1. Tests-first convergence (drop single-task codex review)

`run-task-loop.sh` no longer calls a review step. Flow is:

```
codex impl → pytest / npm test (the task's own test_command)
  pass → task done
  fail → codex fix (prompt = prior test-output.log as context) → test again
  budget exhausted → task failed
```

Dropped files: `scripts/run-codex-review.sh`, `scripts/analyze-review.sh`,
`agents/review-analyst.md`, `agents/convergence-judge.md`,
`docs/CONVERGENCE.md`.

The Stop hook's `implementing` phase now jumps straight to `testing`.
`reviewing` and `addressing` phases are gone from the single-mode
machine.

### 2. Slice-based global review

`run-global-review.sh` now fires one `codex exec` per slice (default:
`api-contracts`, `ui-integration`, `test-coverage`, `security`), each
with:

- Path-scoped diff, capped at 20 KB (was 200 KB whole-repo)
- Strict JSON output contract: `{slice, summary, findings:[{severity, title, location, rationale, fix}]}`
- No VERDICT field — Claude decides, not the LLM
- Optional `SPEC_LOOP_REVIEW_MODEL=gpt-5-codex-mini` for stricter
  format adherence

`spec-loop:global-review-analyst` agent reads the aggregated
`findings.json`, verifies each BLOCKING against the actual code, and
writes the final `decision.json`.

### 3. Auto `git add -N` on setup

Both `setup-spec-loop.sh` and `setup-spec-loop-multi.sh` now run
`git add -N -A -- ':!.spec-loop'` so subsequent `git diff HEAD`
snapshots include all untracked files. This single change eliminates
the largest class of reviewer false positive we observed in v0.2/v0.3.

## Command surface unchanged

v0.4 does **not** add new slash commands. The surface stays at 7
`/spec-loop:*` commands:

- `spec-start`, `multi-start`, `spec-status`, `spec-cancel`,
  `spec-replan`, `spec-rebind`, `spec-resume`.

Internal behaviour changed; UX doesn't.

## Code impact

- Removed: ~2 agents, 2 scripts, ~200 lines of smoke-test coverage for
  removed code, ~75 lines from `stop-hook.sh` (reviewing/addressing
  phase).
- Added: slice-based review plumbing in `run-global-review.sh`
  (~150 lines), auto git-add-N lines in both setup scripts (~4 lines),
  tests-first docs.
- Net: smaller surface, same capability.

## What v0.4 *doesn't* fix

- Flaky test gates (e.g. `test_battle_fans_out_models_without_replanning`
  3 s timeout on Windows) still cause outer-loop replans. Mitigation is
  project-side: widen the timeout in the test itself (`_wait_for` now
  defaults to 10 s on PaperBanana).
- Codex wall-clock drift (a single task taking >30 min because codex
  decides to think hard). The multi-signal done check added in v0.3
  already ignores the timeout if codex produced commits, which covers
  most of it.
- Windows open-with dialogs for extensionless binaries on the PATH.
  Project-side fix: ship a `.cmd` shim.

## Key lesson (again)

**Tests are the authoritative signal; reviewer LLMs are a suggestion
layer.** v0.2 half-realised this with the tests-first shortcut in
`run-task-loop`; v0.4 finishes the refactor by removing the reviewer
from the gating path entirely. Review still exists for end-of-wave
whole-project triage, but its output is structured findings Claude
judges, not a VERDICT string the machine trusts.
