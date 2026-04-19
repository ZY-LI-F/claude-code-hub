#!/usr/bin/env bash
# run-global-review.sh (v0.4) - Slice-based whole-project review.
#
# Instead of a single 200 KB+ prompt that asks codex for a VERDICT, we
# fire multiple small codex invocations (one per "slice"), each with a
# narrow focus and a structured-JSON output contract. Claude's
# global-review-analyst agent then reads all findings-*.json and produces
# the final decision.json.
#
# Slices (v0.4 default):
#   - api-contracts   : router files + service signatures, look for drift
#   - ui-integration  : web/ imports + route wiring, unused exports
#   - test-coverage   : tests/ vs server/ / web/ directory parity
#   - security        : hard-coded secrets, unsafe defaults, missing auth
#
# For each slice we pass codex:
#   - a tight 20 KB snippet (the slice-relevant diff + a file list)
#   - a "STRICT OUTPUT: one JSON object" system rule
#   - reasoning effort medium, model gpt-5-codex-mini when available (falls
#     back to the session default on error)
#
# Writes: .spec-loop/global/round-NNN/findings-<slice>.json

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

ROUND=$(state_get global_round); ROUND=${ROUND:-1}
ROUND_DIR=$(printf '%s/round-%03d' "$SPEC_LOOP_GLOBAL_DIR" "$ROUND")
mkdir -p "$ROUND_DIR"

BASE=$(state_get multi_base_commit)
if [[ -z "$BASE" ]]; then
  BASE=$(cd "$CLAUDE_PROJECT_DIR" && git rev-list --max-parents=0 HEAD | head -1)
fi

# Unfiltered full diff (audit trail)
DIFF_FILE="$ROUND_DIR/diff.patch"
( cd "$CLAUDE_PROJECT_DIR" && git diff "$BASE" HEAD ) > "$DIFF_FILE" 2>/dev/null || true

# Per-slice diff cap — keep prompts small to stop codex drifting into essay mode.
: "${SPEC_LOOP_SLICE_DIFF_CAP:=20480}"   # 20 KB per slice
: "${SPEC_LOOP_REVIEW_MODEL:=}"          # optional override, e.g. gpt-5-codex-mini
: "${SPEC_LOOP_REVIEW_REASONING:=medium}"

_slice_diff() {
  # Usage: _slice_diff <slice_name> > file
  # Produces a size-capped diff limited to path globs that matter for the slice.
  local slice="$1"
  local pathspecs=()
  case "$slice" in
    api-contracts)  pathspecs=( 'server/routers/*' 'server/services/*' 'server/repos/*' ) ;;
    ui-integration) pathspecs=( 'web/src/routes/*' 'web/src/features/*' 'web/src/components/*' 'web/src/stores/*' 'web/src/lib/*' ) ;;
    test-coverage)  pathspecs=( 'tests/*' 'web/src/**/__tests__/*' 'web/vitest.config.ts' ) ;;
    security)       pathspecs=( 'server/*' 'configs/*' '*.env*' '*.gitignore' ) ;;
    *)              pathspecs=( '.' ) ;;
  esac
  ( cd "$CLAUDE_PROJECT_DIR" && git diff "$BASE" HEAD -- "${pathspecs[@]}" ) 2>/dev/null | head -c "$SPEC_LOOP_SLICE_DIFF_CAP"
}

_slice_prompt() {
  local slice="$1" diff_snippet="$2" prompt_file="$3"
  cat > "$prompt_file" <<EOF
You are performing a FOCUSED review on slice: "$slice".

STRICT OUTPUT CONTRACT. Reply with exactly ONE JSON object and NOTHING ELSE:

{
  "slice": "$slice",
  "summary": "one short sentence",
  "findings": [
    {
      "severity": "BLOCKING" | "IMPORTANT" | "NIT",
      "title": "short noun phrase",
      "location": "path/to/file.ext:line or module",
      "rationale": "one sentence, concrete, cites the diff",
      "fix": "one sentence, concrete action"
    }
  ]
}

Rules:
- Max 5 findings. If nothing found, return an empty "findings" array.
- Do NOT emit any prose outside the JSON object. No markdown fences.
- Do NOT write a VERDICT — that's Claude's job, not yours.
- Be strict about REAL bugs (contract drift, dead wiring, leaked secrets).
  Skip stylistic nits; they just waste the triage budget.

## Spec (trimmed)

$(head -c 2048 "$SPEC_LOOP_SPEC" 2>/dev/null)

## Diff scoped to slice "$slice" (up to $SPEC_LOOP_SLICE_DIFF_CAP bytes)

\`\`\`diff
$diff_snippet
\`\`\`
EOF
}

_invoke_codex_slice() {
  # Usage: _invoke_codex_slice <slice>
  local slice="$1"
  local prompt="$ROUND_DIR/review-prompt-${slice}.md"
  local out="$ROUND_DIR/findings-${slice}.json"
  local raw="$ROUND_DIR/codex-raw-${slice}.log"
  local diff_body
  diff_body=$(_slice_diff "$slice")

  _slice_prompt "$slice" "$diff_body" "$prompt"

  if ! command -v codex >/dev/null 2>&1; then
    log_error "codex CLI missing for global review slice=$slice"
    printf '{"slice":"%s","summary":"codex CLI not installed","findings":[]}' "$slice" > "$out"
    return 0
  fi

  local flags="$SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check"
  [[ -n "$SPEC_LOOP_REVIEW_MODEL" ]] && flags="$flags --model $SPEC_LOOP_REVIEW_MODEL"
  # shellcheck disable=SC2086
  if ! codex exec $flags - < "$prompt" > "$raw" 2>&1; then
    log_warn "run-global-review[$ROUND/$slice]: codex exec failed (rc=$?); emitting empty findings"
    printf '{"slice":"%s","summary":"codex exec failed","findings":[]}' "$slice" > "$out"
    return 0
  fi

  # Extract the first JSON object found in the raw output.
  _py3 - "$raw" "$out" "$slice" <<'PY'
import json, re, sys
raw_path, out_path, slice_name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(raw_path, encoding='utf-8', errors='replace').read()
except Exception:
    text = ""
match = None
# Cheap extract: first { ... } block with "slice" key
for m in re.finditer(r'\{', text):
    start = m.start()
    depth = 0
    for i, ch in enumerate(text[start:], start=start):
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                candidate = text[start:i+1]
                try:
                    obj = json.loads(candidate)
                    if isinstance(obj, dict) and 'slice' in obj and 'findings' in obj:
                        match = obj
                        break
                except Exception:
                    pass
                break
    if match:
        break
if not match:
    match = {"slice": slice_name, "summary": "could not parse codex output as JSON",
             "findings": []}
json.dump(match, open(out_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
}

# Default slice set (overridable via env)
: "${SPEC_LOOP_REVIEW_SLICES:=api-contracts ui-integration test-coverage security}"

log_info "run-global-review[$ROUND]: slices=$SPEC_LOOP_REVIEW_SLICES"
for slice in $SPEC_LOOP_REVIEW_SLICES; do
  log_info "run-global-review[$ROUND]: slice=$slice starting"
  _invoke_codex_slice "$slice"
done

# Aggregate index so analyst only needs one read
AGG="$ROUND_DIR/findings.json"
_py3 - "$ROUND_DIR" "$AGG" <<'PY'
import json, os, sys, glob
round_dir, agg_path = sys.argv[1], sys.argv[2]
slices = []
for path in sorted(glob.glob(os.path.join(round_dir, 'findings-*.json'))):
    try:
        slices.append(json.load(open(path, encoding='utf-8')))
    except Exception as e:
        slices.append({"slice": os.path.basename(path), "summary": f"parse error: {e}", "findings": []})
json.dump({"round_dir": round_dir, "slices": slices}, open(agg_path, 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
PY

echo "Global review round $ROUND: $(ls "$ROUND_DIR"/findings-*.json 2>/dev/null | wc -l | tr -d ' ') slice findings files"
echo "Aggregate: $AGG"
