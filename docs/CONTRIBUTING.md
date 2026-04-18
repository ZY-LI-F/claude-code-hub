# Contributing

This repo hosts multiple independent plugins and skills. Each addition is scoped to its own directory so contributors can work on different entries in parallel without stepping on each other.

## Principles

1. **Every entry has a smoke test.** A plugin without `tests/smoke-test.sh` (or a skill without a worked example) gets rejected — you cannot fix what you cannot detect breaking.
2. **Every entry is self-contained.** Cross-entry dependencies make future refactors radioactive. If two plugins share helpers, factor them into a third plugin the others depend on explicitly.
3. **Fail loudly, not silently.** Scripts use `set -euo pipefail`. Hooks that can abort return non-zero and print the reason to stderr. Background updates (`async: true` hooks) log to `~/.claude/` so failures are recoverable.
4. **Stay cross-platform where reasonable.** The author develops on Windows (git-bash); the three most common traps — Windows Python's cp936 default, MSYS path translation of argv strings, and `~/tmp` not existing — are covered in the plugin conventions.

## Adding a plugin

Full recipe is in [`../plugins/README.md`](../plugins/README.md). Skeleton:

```text
plugins/<name>/
├── .claude-plugin/plugin.json      # { name, version, description, author }
├── README.md                        # what, install, commands, deps
├── commands/<cmd>.md                # optional
├── agents/<agent>.md                # optional
├── hooks/hooks.json                 # optional
├── scripts/                         # optional
└── tests/smoke-test.sh              # required
```

Then append to `.claude-plugin/marketplace.json` under `plugins[]`.

### Gotchas that cost me an afternoon

- `plugin.json` root keys are **whitelisted**. Declaring `commands`, `hooks`, or `agents` in it will fail schema validation even though the field names are intuitive — Claude Code auto-discovers those directories by convention. Only `name`, `version`, `description`, `author` (+ a few others) are allowed.
- `marketplace.json` rejects `version` and `description` at the root. Per-plugin `description` inside `plugins[]` is fine.
- Python scripts run by hooks open files without specifying encoding by default. On Windows, that is cp1252/cp936 and trips on any non-ASCII (em-dash, CJK, smart quotes). Export `PYTHONUTF8=1` in your plugin's shared shell library.
- MSYS (git-bash on Windows) translates `/tmp/x` in argv into the Windows temp path when spawning native binaries like Windows Python, but it does **not** translate paths embedded in `python3 -c "... '/tmp/x' ..."` strings. Use argv (`python3 -c 'open(sys.argv[1])' /tmp/x`) or a quoted heredoc (`python3 - "/tmp/x" <<'PY' ... PY`), never inline string interpolation.
- Heredoc `cat >prompt.md <<EOF` with unquoted `EOF` expands shell metacharacters from the heredoc body — but does **not** recursively re-parse the output of `$(cat file)`. So `$(cat task.md)` is not a shell-injection vector; command substitution output is never treated as source.
- `%Y-%m-%dT%H:%M:%SZ` with Python's `strptime` produces a **naive** datetime. Calling `.timestamp()` on it assumes local time and silently skews by the TZ offset. Always `.replace(tzinfo=datetime.timezone.utc)` immediately after parsing.

## Adding a skill

Full recipe is in [`../skills/README.md`](../skills/README.md). Key points:

- `SKILL.md` frontmatter `description` is what Claude sees when deciding whether to load the skill — make it specific ("When the user asks for X" beats "For X tasks").
- Skills install by copying into `~/.claude/skills/`; they are not part of the marketplace flow. Document the install command in the skill's README if it has moving parts.

## Style for scripts

- Shell: `set -euo pipefail` unless you have a documented reason not to.
- Python: argv over inline `-c "..."`, `<<'PY'` (quoted) over `<<PY`, `encoding='utf-8'` on `open()` unless `PYTHONUTF8=1` is guaranteed.
- Atomic writes: tempfile + `mv -f` (shell) or `os.replace` (Python). Never write JSON state directly with `json.dump(open(path, 'w'))` as your only line — a mid-write crash leaves truncated state.
- Hooks that fire on every Write/Edit should exit in <250 ms on the no-op path, since they run synchronously (unless `async: true`). Filter in shell before doing anything expensive.

## License

By contributing you agree your contribution is licensed under the root MIT license unless your entry ships a stricter per-component `LICENSE`.
