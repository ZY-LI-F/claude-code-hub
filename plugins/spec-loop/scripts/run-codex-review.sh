#!/usr/bin/env bash
# run-codex-review.sh - Invoke Codex CLI for structured code review
# Usage: run-codex-review.sh <inner_dir>
#
# Writes:
#   <inner_dir>/diff.patch
#   <inner_dir>/review-prompt.md
#   <inner_dir>/codex-review.md
#
# Falls back to a self-review placeholder if Codex is not installed.

set -euo pipefail

INNER_DIR="${1:?inner_dir required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"

mkdir -p "$INNER_DIR"

# ---- Capture diff since session start ----
DIFF_FILE="${INNER_DIR}/diff.patch"
cd "$CLAUDE_PROJECT_DIR"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  { git diff HEAD 2>/dev/null || true; } > "$DIFF_FILE"
else
  echo "# Not a git repo - no diff captured" > "$DIFF_FILE"
fi

DIFF_BYTES=$(wc -c < "$DIFF_FILE" | tr -d ' ')
log_info "Captured diff: $DIFF_BYTES bytes"

# Size cap on diff to prevent swamping the review prompt (and stay well under
# ARG_MAX on systems where codex might still pass via argv).
: "${SPEC_LOOP_MAX_DIFF_BYTES:=204800}"   # 200 KB
DIFF_FOR_PROMPT="$DIFF_FILE"
if (( DIFF_BYTES > SPEC_LOOP_MAX_DIFF_BYTES )); then
  log_warn "Diff is ${DIFF_BYTES}B; truncating to ${SPEC_LOOP_MAX_DIFF_BYTES}B for review"
  DIFF_FOR_PROMPT="${INNER_DIR}/diff.patch.truncated"
  head -c "$SPEC_LOOP_MAX_DIFF_BYTES" "$DIFF_FILE" > "$DIFF_FOR_PROMPT"
  printf '\n\n... [truncated, original was %s bytes]\n' "$DIFF_BYTES" >> "$DIFF_FOR_PROMPT"
fi

REVIEW_FILE="${INNER_DIR}/codex-review.md"
CURRENT_TASK=$(state_get current_task)
SCENARIO=$(state_get scenario); SCENARIO=${SCENARIO:-generic}
SCHEMA_FILE="${PLUGIN_ROOT}/templates/review-schema.md"
PROMPT_FILE="${INNER_DIR}/review-prompt.md"

# ---- Build the review prompt in Python — no shell expansion of user content ----
# Task spec and diff may contain $(...) or backticks that must NOT be executed.
python3 - "$PROMPT_FILE" "$SCENARIO" "${CURRENT_TASK:-}" "$DIFF_FOR_PROMPT" "$SCHEMA_FILE" <<'PY'
import sys, pathlib

out_path, scenario, task_path, diff_path, schema_path = sys.argv[1:6]

def read_or(path, default=""):
    if not path:
        return default
    try:
        return pathlib.Path(path).read_text(errors="replace")
    except Exception:
        return default

task_spec = read_or(task_path, "(no task file; reviewing general diff)")
diff_body = read_or(diff_path, "(empty diff)")
schema    = read_or(schema_path,
                    "Produce a markdown review with sections: BLOCKING, IMPORTANT, NIT. "
                    "End with 'VERDICT: APPROVED' or 'VERDICT: NEEDS_CHANGES'.")

prompt = f"""# Code Review Task

You are an independent code reviewer. Review the diff below against the task spec.
Focus on: correctness, edge cases, tests, security, code quality.

## Scenario: {scenario}

## Task spec

{task_spec}

## Diff

```diff
{diff_body}
```

## Output format (STRICT)

{schema}
"""
pathlib.Path(out_path).write_text(prompt)
PY

# ---- Dispatch to Codex CLI (prompt via stdin, not argv) ----
if command -v codex >/dev/null 2>&1; then
  log_info "Running codex exec for review (flags: $SPEC_LOOP_CODEX_FLAGS)"
  # Pass prompt on stdin to avoid ARG_MAX and keep it out of `ps` output.
  # `codex exec -` reads prompt from stdin; if the installed codex doesn't
  # support that flag, fall back to a smaller argv-based call (prompt already
  # size-capped above to a safe width).
  if codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check - \
       < "$PROMPT_FILE" > "$REVIEW_FILE" 2>> "$SPEC_LOOP_LOG"; then
    log_info "Codex review written to $REVIEW_FILE"
  elif codex exec $SPEC_LOOP_CODEX_FLAGS --skip-git-repo-check \
         "$(cat "$PROMPT_FILE")" > "$REVIEW_FILE" 2>> "$SPEC_LOOP_LOG"; then
    log_warn "Codex review succeeded via argv fallback (stdin mode unsupported)"
  else
    log_error "codex exec failed via both stdin and argv"
    cat > "$REVIEW_FILE" <<'EOF'
# Review (codex failed)

Codex CLI invocation failed. Please self-review or check logs.

VERDICT: NEEDS_CHANGES
EOF
    # Still compute fingerprint below so oscillation counter progresses.
  fi
else
  log_warn "codex CLI not found; writing fallback prompt for Claude self-review"
  # Build self-review fallback with python too (paths may contain $).
  python3 - "$REVIEW_FILE" "$DIFF_FILE" "$SCHEMA_FILE" <<'PY'
import sys, pathlib
out, diff, schema = sys.argv[1:4]
body = f"""# Review (self-review mode)

Codex CLI is not installed. Please review the diff in `{diff}` yourself
against the task spec. Apply the criteria defined in `{schema}`.

Update this file with your review findings, ending with
  VERDICT: APPROVED
or
  VERDICT: NEEDS_CHANGES
"""
pathlib.Path(out).write_text(body)
PY
fi

# ---- Fingerprint for oscillation detection (portable SHA-256) ----
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest(), " -")'
  fi
}

FINGERPRINT=$(grep -iE '^[[:space:]]*(BLOCKING|IMPORTANT):' "$REVIEW_FILE" 2>/dev/null \
              | sort \
              | _sha256 \
              | cut -c1-16 \
              | tr -d '[:space:]' || echo "")

PREV_HASH=$(state_get last_review_hash)
STREAK=$(state_get review_hash_streak); STREAK=${STREAK:-0}

# 1-based semantics: streak counts consecutive identical reviews.
# streak=1 after first review with these issues; streak=5 after 5 in a row.
if [[ -n "$FINGERPRINT" && "$FINGERPRINT" == "$PREV_HASH" ]]; then
  STREAK=$((STREAK + 1))
else
  STREAK=1
fi
state_set last_review_hash "$FINGERPRINT" review_hash_streak "$STREAK"

# Soft warning: annotate review.md when approaching the hard brake (2 away).
WARN_AT=$((SPEC_LOOP_MAX_OSCILLATION_STREAK - 2))
(( WARN_AT < 2 )) && WARN_AT=2
if (( STREAK >= WARN_AT && STREAK < SPEC_LOOP_MAX_OSCILLATION_STREAK )); then
  {
    printf '\n---\n'
    printf '**[spec-loop] OSCILLATION WARNING**: Review has reported the same issues for %d consecutive iterations.\n' "$STREAK"
    printf 'The Stop hook will force-escalate to L1 at streak=%d (%d more iteration(s)).\n' \
      "$SPEC_LOOP_MAX_OSCILLATION_STREAK" \
      $((SPEC_LOOP_MAX_OSCILLATION_STREAK - STREAK))
    printf 'Consider:\n'
    printf '  - Asking convergence-judge to converge early (return to L1 testing), OR\n'
    printf '  - A more fundamental redesign of the affected code before the next iteration.\n'
  } >> "$REVIEW_FILE"
fi

exit 0
