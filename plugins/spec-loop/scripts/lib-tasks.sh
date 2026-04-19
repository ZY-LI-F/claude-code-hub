#!/usr/bin/env bash
# lib-tasks.sh - tasks.json I/O for v0.2 multi-task mode
# Source after lib-state.sh: requires SPEC_LOOP_TASKS, atomic_write, _with_state_lock.
#
# tasks.json schema:
# {
#   "version": 1,
#   "created_at": "...",
#   "updated_at": "...",
#   "max_parallel": 3,
#   "tasks": [
#     {
#       "id": "T01",
#       "title": "...",
#       "summary": "one-paragraph scope",
#       "depends_on": ["T00"],
#       "wave": 1,                    // assigned by compute-waves
#       "status": "pending",          // pending|ready|running|review|fix|test|done|failed
#       "inner_iter": 0,
#       "attempts": 0,
#       "max_attempts": 3,
#       "task_md": ".spec-loop/batches/wave-001/task-T01/task.md",
#       "test_command": "pytest tests/... -q",
#       "worktree": null,             // optional git worktree path
#       "claimed_by": null,
#       "started_at": null,
#       "completed_at": null,
#       "error_log": []
#     },
#     ...
#   ]
# }

_require_tasks_file() {
  if [[ ! -f "$SPEC_LOOP_TASKS" ]]; then
    log_error "tasks.json missing at $SPEC_LOOP_TASKS"
    return 1
  fi
}

tasks_exists() {
  [[ -f "$SPEC_LOOP_TASKS" ]]
}

tasks_init_empty() {
  # Creates a minimal tasks.json. Does NOT overwrite an existing file.
  if tasks_exists; then
    return 0
  fi
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local max_par="${SPEC_LOOP_MAX_PARALLEL:-3}"
  mkdir -p "$SPEC_LOOP_DIR"
  local content
  content=$(python3 - "$ts" "$max_par" <<'PY'
import json, sys
ts, max_par = sys.argv[1], int(sys.argv[2])
doc = {
    "version": 1,
    "created_at": ts,
    "updated_at": ts,
    "max_parallel": max_par,
    "tasks": [],
}
print(json.dumps(doc, indent=2))
PY
)
  atomic_write "$SPEC_LOOP_TASKS" "$content"
}

_tasks_write_unlocked() {
  # Replaces tasks.json with the JSON on stdin, touches updated_at.
  local tmp
  tmp="${SPEC_LOOP_TASKS}.tmp.$$"
  python3 - "$tmp" <<'PY'
import json, sys, datetime
tmp = sys.argv[1]
doc = json.load(sys.stdin)
doc['updated_at'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(tmp, 'w') as f:
    json.dump(doc, f, indent=2)
PY
  mv -f "$tmp" "$SPEC_LOOP_TASKS"
}

tasks_read_raw() {
  _require_tasks_file || return 1
  cat "$SPEC_LOOP_TASKS"
}

# ---- Queries (read-only) ----

tasks_list_ids() {
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for t in d.get('tasks', []):
    print(t['id'])
PY
}

tasks_get_field() {
  # Usage: tasks_get_field <task_id> <field>
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
tid, key = sys.argv[2], sys.argv[3]
for t in d.get('tasks', []):
    if t.get('id') == tid:
        v = t.get(key, '')
        if isinstance(v, (dict, list)):
            print(json.dumps(v))
        else:
            print('' if v is None else v)
        break
PY
}

tasks_count_by_status() {
  # Prints key=count lines for each status.
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" <<'PY'
import json, sys, collections
with open(sys.argv[1]) as f:
    d = json.load(f)
c = collections.Counter(t.get('status','pending') for t in d.get('tasks', []))
for k, v in sorted(c.items()):
    print(f"{k}={v}")
PY
}

tasks_pending_in_wave() {
  # Usage: tasks_pending_in_wave <wave_num>
  # Prints ids of tasks in that wave whose status is not in {done,failed}.
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
w = int(sys.argv[2])
for t in d.get('tasks', []):
    if t.get('wave') == w and t.get('status') not in ('done','failed'):
        print(t['id'])
PY
}

tasks_all_terminal() {
  # Returns 0 iff every task is in {done, failed}.
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for t in d.get('tasks', []):
    if t.get('status') not in ('done','failed'):
        sys.exit(1)
sys.exit(0)
PY
}

tasks_any_failed() {
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for t in d.get('tasks', []):
    if t.get('status') == 'failed':
        sys.exit(0)
sys.exit(1)
PY
}

tasks_max_wave() {
  _require_tasks_file || return 1
  python3 - "$SPEC_LOOP_TASKS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
m = 0
for t in d.get('tasks', []):
    w = t.get('wave') or 0
    if w > m: m = w
print(m)
PY
}

# ---- Mutations (locked) ----

_tasks_update_unlocked() {
  # Usage: _tasks_update_unlocked <task_id> <key1> <val1> [k2 v2 ...]
  local tid="$1"; shift
  python3 - "$SPEC_LOOP_TASKS" "$tid" "$@" <<'PY'
import json, sys, os, datetime, tempfile
path = sys.argv[1]
tid = sys.argv[2]
kv = sys.argv[3:]
if len(kv) % 2 != 0:
    sys.stderr.write("tasks_update: odd kv\n"); sys.exit(1)
with open(path) as f:
    d = json.load(f)
found = False
for t in d.get('tasks', []):
    if t.get('id') == tid:
        found = True
        for i in range(0, len(kv), 2):
            k, v = kv[i], kv[i+1]
            # Auto-cast ints for numeric fields
            try: v = int(v)
            except ValueError: pass
            t[k] = v
        break
if not found:
    sys.stderr.write(f"tasks_update: task {tid} not found\n"); sys.exit(2)
d['updated_at'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
dir_ = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(prefix='tasks.', suffix='.tmp', dir=dir_)
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

tasks_update() {
  _with_state_lock _tasks_update_unlocked "$@"
}

_tasks_append_error_unlocked() {
  # Usage: _tasks_append_error_unlocked <task_id> <error_string>
  python3 - "$SPEC_LOOP_TASKS" "$1" "$2" <<'PY'
import json, sys, os, datetime, tempfile
path, tid, err = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    d = json.load(f)
ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
for t in d.get('tasks', []):
    if t.get('id') == tid:
        t.setdefault('error_log', []).append(f"[{ts}] {err}")
        break
d['updated_at'] = ts
dir_ = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(prefix='tasks.', suffix='.tmp', dir=dir_)
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

tasks_append_error() {
  _with_state_lock _tasks_append_error_unlocked "$@"
}
