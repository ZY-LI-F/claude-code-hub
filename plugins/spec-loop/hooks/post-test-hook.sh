#!/usr/bin/env bash
# post-test-hook.sh - PostToolUse hook for Bash tool.
#
# Purpose: detect when Claude invoked run-tests.sh and if the loop is
# still in a pre-testing phase, advance phase to "testing" so the next
# Stop hook sees correct state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh" 2>/dev/null || exit 0

state_exists || exit 0

# Extract the Bash command from the hook JSON input.
# Use a helper function so the $(...) call site doesn't mix heredoc with ||.
extract_bash_command() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true
}

HOOK_INPUT="$(cat || true)"
CMD=$(printf '%s' "$HOOK_INPUT" | extract_bash_command)

case "$CMD" in
  *run-tests.sh*)
    CURRENT_PHASE=$(state_get phase)
    case "$CURRENT_PHASE" in
      implementing|reviewing|addressing)
        log_info "post-test-hook: detected run-tests.sh in phase=$CURRENT_PHASE; advancing to testing"
        state_set phase testing
        ;;
      testing)
        log_info "post-test-hook: run-tests.sh invoked in testing phase (normal)"
        ;;
      *)
        log_info "post-test-hook: run-tests.sh invoked in phase=$CURRENT_PHASE (no-op)"
        ;;
    esac
    ;;
esac

exit 0
