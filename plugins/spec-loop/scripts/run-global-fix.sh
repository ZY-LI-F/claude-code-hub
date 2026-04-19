#!/usr/bin/env bash
# run-global-fix.sh - Ask codex to address findings from the current global review
# round. Operates on main branch / main worktree (no parallel here).
#
# Usage: run-global-fix.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

ROUND=$(state_get global_round); ROUND=${ROUND:-1}
ROUND_DIR=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$ROUND")
REVIEW_FILE="$ROUND_DIR/codex-review.md"
PROMPT_FILE="$ROUND_DIR/fix-prompt.md"
LOG_FILE="$ROUND_DIR/codex-fix.log"

if [[ ! -f "$REVIEW_FILE" ]]; then
  log_error "run-global-fix: review file missing ($REVIEW_FILE)"
  exit 1
fi

cat > "$PROMPT_FILE" <<EOF
# Whole-Project Fix (round $ROUND)

Address ALL findings in the review below. Operate on the main branch at the
repo root — this is NOT a parallel task.

## Review to address

$(cat "$REVIEW_FILE")

## Original spec (context)

$(cat "$SPEC_LOOP_SPEC" 2>/dev/null || echo "(spec.md missing)")

## Rules
- Make minimum viable fixes; no broad refactoring.
- Update or add tests when behaviour changes.
- \`git add\` + \`git commit -m "[spec-loop] global round $ROUND: <summary>"\` at the end.
- **Do NOT** modify files under \`.spec-loop/\`.
- If a finding is truly out of scope, write a note to \`$ROUND_DIR/deferred.md\` explaining why.
EOF

if ! command -v codex >/dev/null 2>&1; then
  log_error "codex CLI missing for global fix"
  exit 127
fi

log_info "run-global-fix[$ROUND]: invoking codex"
cd "$CLAUDE_PROJECT_DIR"
# shellcheck disable=SC2086
if codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - \
     < "$PROMPT_FILE" > "$LOG_FILE" 2>&1; then
  log_info "run-global-fix[$ROUND]: codex complete; log: $LOG_FILE"
  echo "Global fix round $ROUND applied. Log: $LOG_FILE"
  exit 0
else
  log_error "run-global-fix[$ROUND]: codex failed"
  tail -n 30 "$LOG_FILE" >&2
  exit 1
fi
