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

DIFF_CAP="${SPEC_LOOP_MAX_DIFF_BYTES:-204800}"
DIFF_SNIPPET=$(head -c "$DIFF_CAP" "$DIFF_FILE")
DIFF_BYTES=$(wc -c < "$DIFF_FILE" | tr -d ' ')

PROMPT_FILE="$ROUND_DIR/review-prompt.md"
REVIEW_FILE="$ROUND_DIR/codex-review.md"

cat > "$PROMPT_FILE" <<EOF
# Whole-Project Review (round $ROUND)

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

## Output format

For each finding:

\`\`\`
<SEVERITY>: <title> — <file:line>
  Rationale: ...
  Fix: ...
\`\`\`

Severities: BLOCKING, IMPORTANT, NIT. Be concise — this is a final gate, not a
tutorial.

End with exactly one line: \`VERDICT: APPROVED\` or \`VERDICT: NEEDS_CHANGES\`.
EOF

if ! command -v codex >/dev/null 2>&1; then
  log_error "codex CLI missing for global review"
  echo "VERDICT: NEEDS_CHANGES" > "$REVIEW_FILE"
  echo "BLOCKING: codex CLI not installed" >> "$REVIEW_FILE"
  exit 1
fi

log_info "run-global-review[$ROUND]: invoking codex"
# shellcheck disable=SC2086
if ! codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - \
       < "$PROMPT_FILE" > "$REVIEW_FILE" 2>&1; then
  log_warn "run-global-review[$ROUND]: codex exec failed; assuming NEEDS_CHANGES"
  echo "VERDICT: NEEDS_CHANGES" >> "$REVIEW_FILE"
fi

echo "Global review round $ROUND -> $REVIEW_FILE"
