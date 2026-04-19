#!/usr/bin/env bash
# compute-waves.sh - Topo-sort tasks.json into waves of <= max_parallel.
# Reads and rewrites .spec-loop/tasks.json in place, assigning `wave` (1..N)
# to every task. Tasks with status in {done, failed} keep whatever wave they
# already have (so reruns don't shuffle history).
#
# Usage: compute-waves.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/scripts/lib-tasks.sh"

_require_tasks_file

MAX_PAR="${SPEC_LOOP_MAX_PARALLEL:-3}"

_with_state_lock python3 - "$SPEC_LOOP_TASKS" "$MAX_PAR" <<'PY'
import json, sys, os, tempfile

path, max_par = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    doc = json.load(f)

tasks = doc.get("tasks", [])
by_id = {t["id"]: t for t in tasks}

# Validate: depends_on references and cycles
# Kahn's algorithm with stable ordering by id for determinism.
indeg = {}
for t in tasks:
    deps = [d for d in t.get("depends_on", []) if d in by_id]
    t["depends_on"] = deps  # drop unknown refs
    indeg[t["id"]] = len(deps)

# Queue of tasks with indeg==0, wave-aware FIFO
ready = sorted([tid for tid, d in indeg.items() if d == 0])
waves = []  # list of list-of-ids
assigned = {}  # task_id -> wave (1-based)
current = 1
while ready:
    # Take up to max_par per wave, keep remainder for next wave
    take = ready[:max_par]
    rest = ready[max_par:]
    for tid in take:
        assigned[tid] = current
    waves.append(take)
    # decrement indeg of tasks whose deps are now complete
    freed = []
    # A task is "done" for wave-purposes once it is assigned to a wave — its
    # dependents can enter the *next* wave or later.
    completed_ids = set()
    for w in waves:
        completed_ids.update(w)
    for t in tasks:
        tid = t["id"]
        if tid in assigned:
            continue
        deps = t.get("depends_on", [])
        if all(d in completed_ids for d in deps):
            if tid not in rest:
                rest.append(tid)
    ready = sorted(rest)
    current += 1

# Any task not assigned is part of a cycle
unassigned = [t["id"] for t in tasks if t["id"] not in assigned]
if unassigned:
    sys.stderr.write(f"compute-waves: cycle or unresolved deps among: {unassigned}\n")
    sys.exit(2)

# Write back: assign wave to every task
for t in tasks:
    t["wave"] = assigned[t["id"]]

# Atomic write
dir_ = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(prefix='tasks.', suffix='.tmp', dir=dir_)
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(doc, f, indent=2)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    raise

print(f"Assigned waves: max_wave={max(assigned.values())} total_tasks={len(tasks)} max_parallel={max_par}")
PY
