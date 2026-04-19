# Post-mortem: spec-loop v0.2 on PaperBanana frontend rebuild

**Date**: 2026-04-19
**Delivery**: 11/11 tasks merged, all 37 tests pass, global review round 1
accepted. ~10 hours wall-clock (ran on Windows + Git Bash + Python 3.13 +
Codex CLI 0.121 via gpt-5.4).

## 1. Data points

| Metric | Value |
|---|---|
| Plan size | 11 tasks, 12 acceptance criteria, 7 waves |
| Tasks merged one-shot | 5/11 (T01 T03 T04 T07 T09 T11) |
| Tasks needing manual rescue | 4/11 (T02 T05 T08 T10) |
| Plugin bug fixes during the run | 6 commits + cache resyncs |
| Global review rounds | 1/5 (codex drifted, analyst independent) |
| Wall-clock budget trips | 1 (false positive — loop actually converged) |

## 2. Problem classification

### A. Bugs (blocked progress)

| # | Bug | Root cause |
|---|---|---|
| A1 | Stop hook never fired | `hooks.json` wrote `"matcher": "*"` on the Stop event; Stop is not a tool event and does not accept `matcher`. |
| A2 | Session-id guard silently allowed exit | `session_matches` needed state.json and Stop-hook input to match, but Claude Code session id rotates on restart with no rebind path. |
| A3 | Windows CRLF poisoned bash variables | Python `print()` writes `\r\n` on Windows text-mode stdout. Values round-tripping through `$(python3 …)` or `while read` carried `\r`. Branch names like `spec-loop/wave-2/task-T02\r` → git refuses "T02?" as a valid ref; `tasks_update "T02\r"` → "task not found". |
| A4 | "Choose app to open pytest" dialog | Extensionless `pytest` shim in `~/bin` triggered Windows file-association when Codex (Node) resolved it via CreateProcess. |
| A5 | Codex 1 MB context overflow | `_build_fix_prompt` inlined the full accumulated review into every fix iteration; by iter 5 the prompt exceeded 1048576 chars and codex aborted. |
| A6 | Stop hook re-launched a running wave | `tasks_pending_in_wave` counted `running` as pending → hook asked Claude to run `run-wave.sh N` again mid-wave. |

### B. Design deficiencies (degrade happy path)

| # | Deficiency | Impact |
|---|---|---|
| B1 | **Review-first convergence gate** | A NEEDS_CHANGES verdict kept iterating even when the task's own tests already passed (T02 iter 4 had 10/10 pytest green; reviewer kept pushing an architecture nit). |
| B2 | **`codex exec` exit-code is the only done signal** | `timeout 1800` on T05 hit right after codex wrote its final commit → non-zero exit → run-task-loop marked failed, but `git log branch..HEAD` had 1 valid commit. |
| B3 | **`test_command` too coarse** | Frontend tasks (T07/T08/T10) ran `pytest -q` → any cross-task regression (T03 vs T05 `insert_stage` contract) dragged every later front-end task into a loop it could not fix. |
| B4 | **batch-planner ignores cross-task contracts** | Plan had "T03 rejects duplicate inserts" and "T05 resumes → re-inserts" without flagging the collision. Codex burned 10 iterations thrashing between the two camps before merges revealed the real fix (`upsert_stage` alongside `insert_stage`). |
| B5 | **Merge-conflict handler = abort+fail** | Any same-file touch between parallel tasks (T07 vs T08 on `Generate.tsx`) ended as a failed task, even when most of the diff was non-overlapping. |
| B6 | **Schema mixes single and multi fields** | multi-mode state still maintained `outer_iter / inner_iter / review_hash_streak / testing_phase_nudges` that no multi-mode branch read. |
| B7 | **Wave advancement is manual** | Each wave completion required Claude to `state_set current_wave N+1`; the hook only printed a nudge. |
| B8 | **Wall-clock rail is blind to human pauses** | 18000 s hard limit counts wall time, not codex time — hitting `failed` state after a long debug session forces manual state_set to recover. |

### C. Operational friction

| # | Problem | Impact |
|---|---|---|
| C1 | tasks.json lags behind per-task task-state.json | stop-hook judged wave completion from stale data. |
| C2 | **Codex global review drifted** | gpt-5.4 + 236 KB prompt → 8054-line Chinese methodology essay, zero structured findings, no VERDICT line. Analyst fell back to independent evaluation. |
| C3 | batch-planner agent does too much in one call | writes tasks.json, 11 task.md files, runs compute-waves.sh, verifies paths; failure mode is opaque. |
| C4 | stop-hook repeats "please run …" on every Stop | pollutes Claude context window with instructions it has already acted on. |
| C5 | no canonical rescue flow | T02/T05/T08/T10 rescue was the same pattern four times (`git merge branch` → `pytest <narrow>` → `tasks_update done` → cleanup) — begs a one-shot script. |

## 3. Optimisation agenda (priority ranked)

### P0 — Blocking bugs, must fix

1. **Windows CRLF global fix**: inject `sys.stdout.reconfigure(newline='\n')` at every Python entrypoint in `lib-state.sh`/`lib-tasks.sh` instead of per-call `| tr -d '\r'`.
2. **Multi-signal done-check in `run-task-loop.sh`**: on codex exec non-zero, inspect `git log <base>..HEAD --oneline` for new commits; if present, continue to review/test phase rather than marking failed.
3. **`/spec-loop:spec-rebind` command**: write the current `$CLAUDE_SESSION_ID` into state.json to recover from Claude restarts.

### P1 — Flow quality

4. **Auto-advance waves from the stop hook**: on wave completion the hook itself `state_set`s `current_wave N+1`, launches `run-wave.sh N+1` via `setsid … &; disown`, and prints a minimal notification.
5. **`rescue-task.sh <task_id>`**: standardises the merge-branch → run-test-cmd → mark-done pattern; reusable by a human or the hook when a task fails but its code looks viable.
6. **Merge-conflict cherry-pick fallback**: when `git merge` conflicts, abort, enumerate `git diff main..branch --name-only`, cherry-pick the non-overlapping files, file the conflicting files to `.spec-loop/global/deferred-from-waves.md`.
7. **Batch-planner contract-collision pass**: extend the agent prompt with an explicit step "list signatures / schemas / test invariants each task touches; flag cross-task collisions as `conflicts_with` in tasks.json".

### P2 — Quality polish

8. **Narrow default `test_command`**: batch-planner generates per-task tests only (`pytest tests/server/test_foo.py -q`), not `pytest -q`. Full-repo pytest belongs to the global-testing phase.
9. **Global-review prompt hardening**: cap diff at 50 KB, require `VERDICT: {APPROVED|NEEDS_CHANGES}` in the first three output lines, and if missing, re-run once with `--model gpt-5.4-mini` before falling back to analyst-only mode.
10. **Split state schema by mode**: `state_init` writes only the fields the active mode needs; `_state_set_unlocked` rejects writes to fields outside the mode's schema.

### P3 — Longer-term

11. **`/spec-loop:spec-resume`**: skips already-done waves/rounds, re-enters at the first non-terminal phase; treats wall-clock trip as `paused` rather than `failed`.
12. **Enhanced `/spec-loop:spec-status`**: per-wave progress bar, live codex PID list, ETA based on historical iter duration.
13. **Iter-level progress log (`progress.ndjson`)**: run-task-loop writes one line per implement/review/test; resume reads the tail to skip completed iters within a task.

## 4. Key lesson

Review is a *suggestion*; tests are the *authoritative signal*. Every merge/advance/failed decision should trace back to either a commit hash or a test result, not a reviewer LLM's textual verdict. v0.2 partially realised this with the "tests-first" shortcut in run-task-loop; v0.3 finishes the refactor by letting every control decision (done, failed, conflict-resolved, wave-advanced, round-accepted) consume deterministic file/git/process state as input.
