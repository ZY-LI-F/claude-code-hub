# claude-code-hub

A personal collection of [Claude Code](https://claude.com/claude-code) **plugins** and **skills**. This repo doubles as a **Claude Code marketplace**, so every plugin listed below is installable with two commands.

## Contents

### Plugins

| Plugin | Status | What it does |
|---|---|---|
| [`spec-loop`](plugins/spec-loop/) | v0.1.0 | Nested-loop coding harness — Claude plans & analyzes, Codex implements & reviews, tests gate the outer loop. |

### Skills

| Skill | Status | What it does |
|---|---|---|
| _(none yet)_ | — | See [`skills/README.md`](skills/README.md) for how skills will be added. |

## Install the marketplace

Inside any Claude Code session:

```text
/plugin marketplace add ZY-LI-F/claude-code-hub
/plugin install spec-loop@claude-code-hub
```

Equivalent CLI invocation (useful for scripting):

```bash
claude plugin marketplace add ZY-LI-F/claude-code-hub
claude plugin install spec-loop@claude-code-hub
```

`/plugin list` will then show the installed plugin; slash commands are namespaced as `/spec-loop:spec-start`, `/spec-loop:spec-status`, etc.

If you have the repository cloned locally and want to iterate on it, point Claude Code at the local path instead so edits show up immediately after `claude plugin marketplace update`:

```bash
claude plugin marketplace add /path/to/claude-code-hub
```

## Repository layout

```text
claude-code-hub/
├── README.md                      ← you are here
├── LICENSE                        ← MIT (per-component licenses may override)
├── .claude-plugin/
│   └── marketplace.json           ← Claude Code marketplace manifest
├── plugins/
│   ├── README.md                  ← index of plugins + plugin contribution rules
│   └── <plugin>/
│       ├── .claude-plugin/plugin.json
│       ├── README.md
│       └── (commands/, hooks/, agents/, scripts/, tests/, ...)
├── skills/
│   ├── README.md                  ← how to install / author skills
│   └── <skill>/SKILL.md
└── docs/
    └── CONTRIBUTING.md            ← recipe for adding a new plugin or skill
```

## Why separate plugins and skills?

Claude Code treats them as two different extension mechanisms:

- **Plugins** are packaged sets of commands, agents, and hooks that install through the marketplace system. They can own persistent hooks (e.g. Stop, PostToolUse) and ship their own MCP servers.
- **Skills** are prompt-bundled capability cards that Claude loads on demand. They are simpler (one `SKILL.md` plus optional helper files) and currently install by copying into `~/.claude/skills/`. They do not install via the marketplace flow.

Keeping them in one repo means one `git clone` brings everything; keeping them in separate top-level directories means tooling can target each category without ambiguity.

## Contributing / adding new entries

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) — it covers the directory templates, the `plugin.json` / `marketplace.json` gotchas I hit (non-obvious validation rules), and the smoke-test conventions used here.

## License

MIT — see [`LICENSE`](LICENSE). Individual plugins may ship their own `LICENSE` with extra attribution; those override the root license for their subtree.
