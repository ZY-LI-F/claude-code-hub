#!/usr/bin/env bash
# run-global-review.sh - Whole-repo review round, using codex as reviewer.
# Produces: .spec-loop/global/round-<N>/codex-review.md  + diff.patch
# Updates state: reads global_round; caller is responsible for bumping.
#
# Usage: run-global-review.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

ROUND=$(state_get global_round); ROUND=${ROUND:-1}
ROUND_DIR=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$ROUND")
mkdir -p "$ROUND_DIR"

# Base for the diff: the commit recorded when multi-mode was set up, or HEAD~
BASE=$(state_get multi_base_commit)
if [[ -z "$BASE" ]]; then
  BASE=$(cd "$CLAUDE_PROJECT_DIR" && git rev-list --max-parents=0 HEAD | head -1)
fi

DIFF_FILE="$ROUND_DIR/diff.patch"
( cd "$CLAUDE_PROJECT_DIR" && git diff "$BASE" HEAD ) > "$DIFF_FILE" 2>/dev/null || true

# v0.3: cap at 50 KB (was 200 KB). Codex drifts into essay mode on huge
# prompts; forcing a compact diff keeps the review focused on top-level
# integration risks rather than line-by-line nitpicking.
DIFF_CAP="${SPEC_LOOP_GLOBAL_DIFF_CAP:-51200}"
DIFF_SNIPPET=$(head -c "$DIFF_CAP" "$DIFF_FILE")
DIFF_BYTES=$(wc -c < "$DIFF_FILE" | tr -d ' ')

PROMPT_FILE="$ROUND_DIR/review-prompt.md"
REVIEW_FILE="$ROUND_DIR/codex-review.md"

cat > "$PROMPT_FILE" <<EOF
# Whole-Project Review (round $ROUND)

**Output format is hard-enforced. Ignore it and this round is wasted.**

The FIRST THREE LINES of your response MUST be:

\`\`\`
VERDICT: APPROVED
SUMMARY: <one-sentence summary>
FINDINGS: <n>
\`\`\`

or, if there are any blocking issues:

\`\`\`
VERDICT: NEEDS_CHANGES
SUMMARY: <one-sentence summary>
FINDINGS: <n>
\`\`\`

Then list findings (one per block, at most 10). Do NOT write prose essays
about software methodology, complexity transfer, or team roles — this is a
code review, keep it mechanical.

You are the *senior* reviewer for an entire multi-task delivery. Many atomic
tasks have been merged into the main branch; now judge the result as a whole.

## Spec (original requirement)

$(cat "$SPEC_LOOP_SPEC" 2>/dev/null || echo "(spec.md missing)")

## Plan

$(cat "$SPEC_LOOP_PLAN" 2>/dev/null || echo "(plan.md missing)")

## Completed tasks

$(python3 - "$SPEC_LOOP_TASKS" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for t in d.get('tasks', []):
        print(f"- {t['id']} [{t.get('status','?')}] {t.get('title','')}")
except Exception:
    print("(tasks.json missing)")
PY
)

## Diff (size: $DIFF_BYTES bytes, truncated to first $DIFF_CAP if larger)

\`\`\`diff
$DIFF_SNIPPET
\`\`\`

## Review scope

Focus on integration issues that single-task reviews cannot see:
1. **Cross-task consistency**: API contracts, shared types, naming, dependency versions.
2. **Data-flow correctness**: state, concurrency, error propagation across boundaries.
3. **Missing wiring**: unused exports, orphaned modules, dead endpoints, disabled tests.
4. **Security regressions**: leaked secrets, unsafe defaults, auth gaps.
5. **Tests**: total coverage gaps, flaky patterns, tests that only pass in isolation.

## Findings block format

Recap: start with the 3-line header above. For each finding use:

\`\`\`
<SEVERITY>: <title> — <file:line>
  Rationale: one sentence.
  Fix: one sentence.
\`\`\`

Severities: BLOCKING, IMPORTANT, NIT. Max 10 findings total. Prefer
elevating the most important 3-5; skip cosmetic nits entirely.

The header you already wrote (VERDICT / SUMMARY / FINDINGS) is the source
of truth for the harness — do not change it, do not echo it at the bottom.
EOF

if ! command -v codex >/dev/null 2>&1; then
  log_error "codex CLI missing for global review"
  echo "VERDICT: NEEDS_CHANGES" > "$REVIEW_FILE"
  echo "BLOCKING: codex CLI not installed" >> "$REVIEW_FILE"
  exit 1
fi

log_info "run-global-review[$ROUND]: invoking codex"
_invoke_codex() {
  local out="$1"
  # shellcheck disable=SC2086
  codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - \
    < "$PROMPT_FILE" > "$out" 2>&1
}

if ! _invoke_codex "$REVIEW_FILE"; then
  log_warn "run-global-review[$ROUND]: codex exec failed (rc=$?); assuming NEEDS_CHANGES"
  echo "VERDICT: NEEDS_CHANGES" >> "$REVIEW_FILE"
fi

# Drift detection: if codex produced no VERDICT header in the first 20 lines,
# it probably wandered off into essay mode. Try once more with a much
# shorter prompt that re-emphasises the output contract.
if ! head -20 "$REVIEW_FILE" | grep -qE '^VERDICT:\s*(APPROVED|NEEDS_CHANGES)'; then
  log_warn "run-global-review[$ROUND]: no VERDICT in first 20 lines; retrying with strict prompt"
  cat > "$PROMPT_FILE.retry" <<EOF
STRICT MODE. Your reply MUST start with exactly these three lines:

VERDICT: APPROVED
SUMMARY: <one sentence>
FINDINGS: 0

or if there are issues:

VERDICT: NEEDS_CHANGES
SUMMARY: <one sentence>
FINDINGS: <count>

followed by up to 10 structured findings in the format:

<SEVERITY>: <title> — <file:line>
  Rationale: ...
  Fix: ...

Do NOT write any other prose. Here is the change summary you are judging:

## Spec
$(cat "$SPEC_LOOP_SPEC" 2>/dev/null | head -c 4096)

## Diff (first 30 KB)
\`\`\`diff
$(head -c 30720 "$DIFF_FILE")
\`\`\`
EOF
  mv "$REVIEW_FILE" "$REVIEW_FILE.drift"
  if codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - \
         < "$PROMPT_FILE.retry" > "$REVIEW_FILE" 2>&1; then
    log_info "run-global-review[$ROUND]: strict retry complete"
  else
    log_error "run-global-review[$ROUND]: strict retry also failed"
    echo "VERDICT: NEEDS_CHANGES" >> "$REVIEW_FILE"
  fi
fi

echo "Global review round $ROUND -> $REVIEW_FILE"
