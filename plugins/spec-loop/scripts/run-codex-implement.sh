#!/usr/bin/env bash
# run-codex-implement.sh - Invoke Codex CLI for implementation
# Separate session from review to avoid self-endorsement.
#
# Usage: run-codex-implement.sh <inner_dir>
# Reads: $inner_dir/task.md
# Writes: modifies working tree; logs to $inner_dir/codex-impl.log

set -euo pipefail

INNER_DIR="${1:?inner_dir required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

TASK_FILE="${INNER_DIR}/task.md"
IMPL_LOG="${INNER_DIR}/codex-impl.log"
PROMPT_FILE="${INNER_DIR}/impl-prompt.md"

if [[ ! -f "$TASK_FILE" ]]; then
  echo "[run-codex-implement] task.md not found: $TASK_FILE" >&2
  exit 1
fi

SCENARIO=$(state_get scenario); SCENARIO=${SCENARIO:-generic}
PREV_REVIEW=""
INNER=$(state_get inner_iter); INNER=${INNER:-0}
# Cap previous review to avoid unbounded prompt growth across iterations.
: "${SPEC_LOOP_MAX_PREV_REVIEW_BYTES:=102400}"   # 100 KB
if (( INNER > 0 )); then
  PREV_INNER_DIR=$(printf '%s/inner/iter-%03d' "$(current_outer_dir)" $((INNER - 1)))
  PREV_REVIEW_FILE="${PREV_INNER_DIR}/codex-review.md"
  if [[ -f "$PREV_REVIEW_FILE" ]]; then
    PREV_BYTES=$(wc -c < "$PREV_REVIEW_FILE" | tr -d ' ')
    if (( PREV_BYTES > SPEC_LOOP_MAX_PREV_REVIEW_BYTES )); then
      PREV_REVIEW=$(head -c "$SPEC_LOOP_MAX_PREV_REVIEW_BYTES" "$PREV_REVIEW_FILE")
      PREV_REVIEW="${PREV_REVIEW}"$'\n\n... [truncated, original was '"$PREV_BYTES"' bytes]'
    else
      PREV_REVIEW=$(cat "$PREV_REVIEW_FILE")
    fi
  fi
fi

cat > "$PROMPT_FILE" <<EOF
# Implementation Task

You are a senior engineer implementing the following task. Write code, add/update tests, and commit iteratively.

## Scenario: $SCENARIO

## Task

$(cat "$TASK_FILE")

## Previous review (if this is an iteration)

$(if [[ -n "$PREV_REVIEW" ]]; then echo "$PREV_REVIEW"; else echo "(first iteration - no prior review)"; fi)

## Rules

- **Do** make the minimum set of changes needed to satisfy the task.
- **Do** add or update tests so the acceptance criteria are exercised.
- **Do NOT** commit or push — leave changes in the working tree.
- **Do NOT** modify files under \`.spec-loop/\` — that's the harness state.
- If you cannot complete the task, write a short explanation to
  \`${INNER_DIR}/impl-blockers.md\` and exit.
EOF

if ! command -v codex >/dev/null 2>&1; then
  log_error "codex CLI not installed; cannot delegate implementation"
  cat >&2 <<EOF
[spec-loop] codex CLI is required for implementation but is not installed.
Install: npm install -g @openai/codex
Or set CODEX_IMPL_FALLBACK=self to have Claude implement directly (defeats the purpose).
EOF
  exit 1
fi

log_info "Running codex exec for implementation (inner=$INNER)"
cd "$CLAUDE_PROJECT_DIR"
# Prefer stdin to stay off argv (ARG_MAX) and out of `ps` output. Fall back to
# argv only if the installed codex rejects `-`. Mirrors run-codex-review.sh.
# shellcheck disable=SC2086
if codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - \
     < "$PROMPT_FILE" > "$IMPL_LOG" 2>&1; then
  log_info "Codex implementation complete via stdin; log: $IMPL_LOG"
  echo "Implementation complete. Log: $IMPL_LOG"
  exit 0
elif codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check \
       "$(cat "$PROMPT_FILE")" > "$IMPL_LOG" 2>&1; then
  log_warn "Codex implementation succeeded via argv fallback (stdin mode unsupported)"
  echo "Implementation complete (argv fallback). Log: $IMPL_LOG"
  exit 0
else
  log_error "codex exec for implementation failed via both stdin and argv"
  tail -n 30 "$IMPL_LOG" >&2
  exit 1
fi
