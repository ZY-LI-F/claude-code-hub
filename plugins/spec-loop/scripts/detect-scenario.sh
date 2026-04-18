#!/usr/bin/env bash
# detect-scenario.sh - Classify a spec into crud | algorithm | bugfix | generic
# Usage: detect-scenario.sh "<spec text>"
#
# Uses Python regex with word boundaries to avoid false positives like
# "fix" matching "prefix" or "api" matching "apache".

set -euo pipefail

SPEC="${1:-}"
if [[ -z "$SPEC" ]]; then
  echo "generic"
  exit 0
fi

# Pass spec via argv — no shell interpolation into Python source.
python3 - "$SPEC" <<'PY'
import re, sys
spec = sys.argv[1].lower()

# Bug-fix signals (weighted higher as they're more specific)
BUGFIX = ["bug", "fix", "fixes", "fixed", "regression", "broken", "crash",
          "error", "errors", "refactor", "refactoring",
          "修复", "重构", "失败", "异常", "不工作", "坏了"]

CRUD   = ["endpoint", "endpoints", "api", "rest", "graphql", "route", "routes",
          "controller", "controllers", "form", "forms", "database", "migration",
          "crud", "ui", "frontend", "backend", "http", "https",
          "接口", "页面", "组件", "前端", "后端"]

ALGO   = ["algorithm", "algorithms", "compute", "computes", "calculate", "calculates",
          "parse", "parses", "sort", "sorts", "search", "searches",
          "traverse", "traverses", "recursion", "recursive", "complexity",
          "function", "functions", "algo",
          "算法", "递归", "排序", "查找", "遍历", "计算"]

def score(keywords, weight=1):
    n = 0
    for kw in keywords:
        if re.search(r'[\u4e00-\u9fff]', kw):
            # CJK: no word boundaries — use plain substring.
            if kw in spec:
                n += weight
        else:
            # ASCII: word boundary.
            if re.search(r'\b' + re.escape(kw) + r'\b', spec):
                n += weight
    return n

bugfix_score = score(BUGFIX, weight=2)
crud_score   = score(CRUD,   weight=1)
algo_score   = score(ALGO,   weight=1)

best = max(bugfix_score, crud_score, algo_score)
# Require a minimum signal strength to avoid noisy auto-classification.
if best < 2:
    print("generic")
elif bugfix_score == best:
    print("bugfix")
elif crud_score == best:
    print("crud")
else:
    print("algorithm")
PY
