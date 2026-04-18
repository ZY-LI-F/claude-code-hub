#!/usr/bin/env bash
# lib-state.sh - Shared state management for spec-loop
# Source this from other scripts: source "${CLAUDE_PLUGIN_ROOT}/scripts/lib-state.sh"

# ============================================================
# Force Python to use UTF-8 for all text I/O, even on Windows where
# the default is cp1252/cp936/etc. Without this, `open(path)` on a
# review / task / test log containing non-ASCII (em-dash, CJK, etc.)
# raises UnicodeDecodeError. PYTHONUTF8=1 is honored by Python 3.7+
# and is idempotent on Linux/macOS (already UTF-8 by default).
# ============================================================
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# ============================================================
# Directory conventions
# ============================================================
: "${CLAUDE_PROJECT_DIR:=$(pwd)}"
export SPEC_LOOP_DIR="${CLAUDE_PROJECT_DIR}/.spec-loop"
export SPEC_LOOP_STATE="${SPEC_LOOP_DIR}/state.json"
export SPEC_LOOP_SPEC="${SPEC_LOOP_DIR}/spec.md"
export SPEC_LOOP_PLAN="${SPEC_LOOP_DIR}/plan.md"
export SPEC_LOOP_LOG="${SPEC_LOOP_DIR}/spec-loop.log"
export SPEC_LOOP_ITER_DIR="${SPEC_LOOP_DIR}/iterations"

# ============================================================
# Budgets (env-overridable)
# ============================================================
export SPEC_LOOP_MAX_INNER_ITER="${SPEC_LOOP_MAX_INNER_ITER:-10}"
export SPEC_LOOP_MAX_OUTER_ITER="${SPEC_LOOP_MAX_OUTER_ITER:-3}"
export SPEC_LOOP_MAX_WALL_SECONDS="${SPEC_LOOP_MAX_WALL_SECONDS:-18000}"
# Oscillation streak semantics (1-based): streak counts occurrences of the
# same issue set. streak=1 means "we saw these issues once"; streak=5 means
# "5 consecutive reviews with identical issues". Hard brake fires when
# streak >= SPEC_LOOP_MAX_OSCILLATION_STREAK.
export SPEC_LOOP_MAX_OSCILLATION_STREAK="${SPEC_LOOP_MAX_OSCILLATION_STREAK:-5}"
# Testing-phase nudge cap: how many times Stop hook can nag Claude to run
# tests before declaring the loop stuck.
export SPEC_LOOP_MAX_TESTING_NUDGES="${SPEC_LOOP_MAX_TESTING_NUDGES:-3}"
# Default to danger-full-access per user choice; isolated env only!
export SPEC_LOOP_CODEX_FLAGS="${SPEC_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"

# ============================================================
# Logging
# ============================================================
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$SPEC_LOOP_DIR"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$SPEC_LOOP_LOG"
}
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ============================================================
# Atomic file write (temp + rename)
# ============================================================
atomic_write() {
  local target="$1"
  local content="$2"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  local tmp="${target}.tmp.$$"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

# ============================================================
# Portable file lock (best-effort; falls back to no-op with warning)
# ============================================================
_with_state_lock() {
  # Usage: _with_state_lock <cmd> [args...]
  # Runs the command while holding an exclusive lock on SPEC_LOOP_STATE.lock.
  local lock="${SPEC_LOOP_STATE}.lock"
  mkdir -p "$SPEC_LOOP_DIR"
  : > "$lock" 2>/dev/null || true

  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lock"
      flock -w 10 9 || { log_error "_with_state_lock: flock timeout"; exit 1; }
      "$@"
    )
    return $?
  else
    # No flock (e.g. macOS without homebrew). Fall back to mkdir-based lock
    # with short retry. Collision probability is low since hooks run serially
    # within a single Claude Code session.
    local lockdir="${SPEC_LOOP_STATE}.lockdir"
    local tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      tries=$((tries + 1))
      if (( tries > 100 )); then
        log_warn "_with_state_lock: mkdir-lock timeout; proceeding without lock"
        break
      fi
      sleep 0.1
    done
    "$@"
    local rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return $rc
  fi
}

# ============================================================
# State I/O (JSON) — argv-based to prevent shell injection
# ============================================================
# Schema (state.json):
# {
#   "session_id": "<claude session id>",
#   "phase": "idle|planning|implementing|reviewing|addressing|testing|done|failed",
#   "outer_iter": 0,
#   "inner_iter": 0,
#   "scenario": "crud|algorithm|bugfix|generic",
#   "current_task": "<path to current task.md>",
#   "last_review_hash": "<issue fingerprint for oscillation detection>",
#   "review_hash_streak": 0,
#   "testing_phase_nudges": 0,
#   "exit_reason": "",
#   "created_at": "...",
#   "updated_at": "..."
# }

state_exists() {
  [[ -f "$SPEC_LOOP_STATE" ]]
}

state_init() {
  local session_id="$1"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$SPEC_LOOP_DIR" "$SPEC_LOOP_ITER_DIR"
  # Build JSON via Python to guarantee safe quoting of session_id.
  local content
  content=$(python3 - "$session_id" "$ts" <<'PY'
import json, sys
session_id, ts = sys.argv[1], sys.argv[2]
state = {
    "session_id": session_id,
    "phase": "idle",
    "outer_iter": 0,
    "inner_iter": 0,
    "scenario": "generic",
    "current_task": "",
    "last_review_hash": "",
    "review_hash_streak": 0,
    "testing_phase_nudges": 0,
    "exit_reason": "",
    "created_at": ts,
    "updated_at": ts,
}
print(json.dumps(state, indent=2))
PY
)
  atomic_write "$SPEC_LOOP_STATE" "$content"
}

state_get() {
  local key="$1"
  [[ -f "$SPEC_LOOP_STATE" ]] || { echo ""; return; }
  # Path and key pass through argv — no string interpolation into Python source.
  python3 - "$SPEC_LOOP_STATE" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
    v = d.get(key, '')
    print(v if not isinstance(v, (dict, list)) else json.dumps(v))
except Exception:
    pass
PY
}

_state_set_unlocked() {
  # Usage: _state_set_unlocked key1 value1 [key2 value2 ...]
  [[ -f "$SPEC_LOOP_STATE" ]] || return 1
  python3 - "$SPEC_LOOP_STATE" "$@" <<'PY'
import json, sys, os, tempfile, datetime
path = sys.argv[1]
kv = sys.argv[2:]
if len(kv) % 2 != 0:
    sys.stderr.write("state_set: odd number of key/value arguments\n")
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
for i in range(0, len(kv), 2):
    k, v = kv[i], kv[i+1]
    # Auto-cast ints for numeric fields
    try:
        v = int(v)
    except ValueError:
        pass
    d[k] = v
d['updated_at'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
# Atomic write via temp + rename, in the same directory to keep it on same FS.
dir_ = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(prefix='state.', suffix='.tmp', dir=dir_)
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    raise
PY
}

state_set() {
  _with_state_lock _state_set_unlocked "$@"
}

# ============================================================
# Iteration directory helpers
# ============================================================
current_outer_dir() {
  local n
  n=$(state_get outer_iter)
  n=${n:-0}
  printf '%s/outer-%03d' "$SPEC_LOOP_ITER_DIR" "$n"
}

current_inner_dir() {
  local i
  i=$(state_get inner_iter)
  i=${i:-0}
  printf '%s/inner/iter-%03d' "$(current_outer_dir)" "$i"
}

ensure_inner_dir() {
  mkdir -p "$(current_inner_dir)"
}

# ============================================================
# Session-id guard (prevents cross-session hook triggers)
# ============================================================
session_matches() {
  local incoming="$1"
  local stored
  stored=$(state_get session_id)
  [[ -n "$stored" && "$stored" == "$incoming" ]]
}
