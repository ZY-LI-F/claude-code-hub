#!/usr/bin/env bash
# spec-rebind.sh - Rebind .spec-loop/state.json's session_id to the current
# Claude Code session. Needed after a Claude Code restart because the Stop
# hook's session_matches guard silently allows exit on mismatch, which
# stalls the loop.
#
# Usage:
#   spec-rebind.sh <session_id>
#   spec-rebind.sh           # auto-detect from most-recent jsonl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

INCOMING="${1:-}"

if [[ -z "$INCOMING" ]]; then
  # Try to auto-detect from the most-recent jsonl under the Claude Code
  # project history. Encoding of project dir → folder name follows
  # Claude Code's scheme: replace `/` and `:` with `-` and drop drive letters.
  HIST_ROOT="${HOME}/.claude/projects"
  if [[ -d "$HIST_ROOT" ]]; then
    CWD_ENCODED=$(pwd | sed -e 's#/#-#g' -e 's#^-##' -e 's#^\([A-Za-z]\)-#\1--#' -e 's#^#/c/Users/qq108/.claude/projects/#')
    # Fallback to any project dir that matches the last path segment
    LATEST=$(ls -t "$HIST_ROOT" 2>/dev/null | head -30 | \
             grep -i "$(basename "$PWD")" | head -1 || true)
    if [[ -n "$LATEST" && -d "$HIST_ROOT/$LATEST" ]]; then
      LATEST_JSONL=$(ls -t "$HIST_ROOT/$LATEST"/*.jsonl 2>/dev/null | head -1)
      if [[ -n "$LATEST_JSONL" ]]; then
        INCOMING=$(basename "$LATEST_JSONL" .jsonl)
      fi
    fi
  fi
fi

if [[ -z "$INCOMING" ]]; then
  cat >&2 <<EOF
spec-rebind: could not determine a session id.
Pass it explicitly: spec-rebind.sh <session-id>
(it is the basename of the most-recent .jsonl file under
 ~/.claude/projects/<encoded-project>/).
EOF
  exit 1
fi

if ! state_exists; then
  echo "spec-rebind: no .spec-loop/ here (not an active loop)" >&2
  exit 1
fi

OLD=$(state_get session_id)
state_set session_id "$INCOMING"
NEW=$(state_get session_id)

log_info "spec-rebind: session $OLD -> $NEW"
cat <<EOF
[spec-loop] session rebound.
  old: $OLD
  new: $NEW
Hook will now recognize this session. Continue the loop normally.
EOF
