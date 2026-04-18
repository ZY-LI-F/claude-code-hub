#!/usr/bin/env bash
# install.sh - Quick install helper for spec-loop marketplace
#
# Usage:
#   bash install.sh                  # runs smoke test then prints the /plugin commands you need
#   bash install.sh --skip-smoke     # skip smoke test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_SMOKE=0
[[ "${1:-}" == "--skip-smoke" ]] && SKIP_SMOKE=1

echo "==> spec-loop install helper"
echo "    Marketplace root: $SCRIPT_DIR"
echo

# ---- Check prerequisites ----
echo "==> Checking prerequisites..."

missing=0
check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    local version
    version=$("$1" --version 2>&1 | head -1)
    printf '  %-15s ✓  %s\n' "$1" "$version"
  else
    printf '  %-15s ✗  MISSING\n' "$1"
    missing=1
  fi
}

check_cmd node
check_cmd claude
check_cmd python3
check_cmd git
echo -n '  codex           '
if command -v codex >/dev/null 2>&1; then
  echo "✓  $(codex --version 2>&1 | head -1)"
else
  echo "⚠  not installed (required for real loops; smoke test OK without)"
fi

if [[ $missing -eq 1 ]]; then
  echo
  echo "ERROR: Required tools are missing. Please install them and re-run." >&2
  echo "  - Node 18+:   https://nodejs.org"
  echo "  - Claude Code: npm install -g @anthropic-ai/claude-code && claude login"
  echo "  - Codex CLI (for real loops): npm install -g @openai/codex"
  exit 1
fi

# ---- Smoke test ----
if [[ $SKIP_SMOKE -eq 0 ]]; then
  echo
  echo "==> Running smoke test..."
  if bash "$SCRIPT_DIR/plugins/spec-loop/tests/smoke-test.sh"; then
    echo
    echo "✓ Smoke test passed."
  else
    echo
    echo "✗ Smoke test failed. Do NOT install until resolved." >&2
    exit 1
  fi
fi

# ---- Print install instructions ----
cat <<EOF

==================================================================
✓ Ready to install. Run these commands inside Claude Code:
==================================================================

  claude

  # Inside the Claude Code session:
  /plugin marketplace add $SCRIPT_DIR
  /plugin install spec-loop@claude-code-hub
  /reload-plugins
  /plugin list

==================================================================
After install, your commands will be:
  /spec-loop:spec-start  <requirement>
  /spec-loop:spec-status
  /spec-loop:spec-cancel
  /spec-loop:spec-replan

See INSTALL.md for details and troubleshooting.
==================================================================
EOF
