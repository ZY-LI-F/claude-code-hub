#!/usr/bin/env bash
# analyze-review.sh - Parse a Codex review and surface structured signals
# Usage: analyze-review.sh <inner_dir>
#
# Reads:  $inner_dir/codex-review.md
# Writes: $inner_dir/review-summary.json   (parsed signals for claude/convergence-judge)

set -euo pipefail

INNER_DIR="${1:?inner_dir required}"
REVIEW_FILE="${INNER_DIR}/codex-review.md"
SUMMARY_FILE="${INNER_DIR}/review-summary.json"

if [[ ! -f "$REVIEW_FILE" ]]; then
  echo "[analyze-review] no review file at $REVIEW_FILE" >&2
  exit 1
fi

# Atomic write: build summary.json into a tempfile, then rename. Path comes via
# argv so we do not shell-interpolate into Python source (<<'PY' is quoted).
TMP_SUMMARY="${SUMMARY_FILE}.tmp.$$"
python3 - "$REVIEW_FILE" <<'PY' > "$TMP_SUMMARY"
import json, re, sys
review_path = sys.argv[1]

with open(review_path) as f:
    text = f.read()

# Verdict
verdict = "UNKNOWN"
m = re.search(r'^\s*VERDICT:\s*(APPROVED|NEEDS_CHANGES)', text, re.MULTILINE | re.IGNORECASE)
if m:
    verdict = m.group(1).upper()

# Count issues by severity
def count(severity):
    return len(re.findall(rf'^\s*{severity}:', text, re.MULTILINE | re.IGNORECASE))

blocking = count("BLOCKING")
important = count("IMPORTANT")
nit = count("NIT")

# Oscillation note: run-codex-review.sh writes "OSCILLATION WARNING"; accept the
# legacy "OSCILLATION DETECTED" string too so older reviews keep parsing.
oscillation = bool(re.search(r'\bOSCILLATION\s+(WARNING|DETECTED)\b', text, re.IGNORECASE))

# Heuristic hard-convergence signal
hard_converged = (verdict == "APPROVED") and (blocking == 0)

summary = {
    "verdict": verdict,
    "counts": {"blocking": blocking, "important": important, "nit": nit},
    "hard_converged": hard_converged,
    "oscillation": oscillation,
    "review_path": review_path,
}
print(json.dumps(summary, indent=2))
PY
mv -f "$TMP_SUMMARY" "$SUMMARY_FILE"

cat "$SUMMARY_FILE"
