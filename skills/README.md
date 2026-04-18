# Skills

Each subdirectory here is one Claude Code [skill](https://docs.claude.com/en/docs/claude-code/skills) — a capability card Claude loads on demand based on the `description` in the skill's frontmatter.

> Skills do **not** install via the marketplace system. They live under `~/.claude/skills/` and are discovered by directory scan. To use a skill from this repo you either clone the skill directory into that location or symlink it.

## Current skills

_(none yet — this directory is a placeholder for future additions)_

## Installing a skill from this repo

Pick one and copy (or symlink) it into your user skills directory:

```bash
# Copy (simplest)
cp -r skills/<skill-name> ~/.claude/skills/<skill-name>

# Symlink (edits in this repo stay live)
ln -s "$PWD/skills/<skill-name>" ~/.claude/skills/<skill-name>
```

Restart Claude Code — skills are loaded at session start.

## Authoring a new skill

1. Create `skills/<skill-name>/SKILL.md`. Required frontmatter:
   ```markdown
   ---
   name: <skill-name>
   description: >-
     When to invoke this skill. Must be specific enough that Claude can decide
     relevance. Keep the sentence short; Claude truncates long descriptions.
   ---

   # <Skill title>

   Body: usage rules, examples, outputs. This is what Claude reads when the
   skill is active.
   ```
2. Optionally add helper files next to `SKILL.md` (scripts, templates, reference docs) — Claude can reference them via relative path.
3. Add a row to the "Current skills" section above.
4. Test locally by copying into `~/.claude/skills/` and invoking via `/<skill-name>` inside Claude Code.

## Why skills live alongside plugins

Many real workflows need both — a plugin with hooks/commands that enforce a workflow, plus a skill that provides guidance Claude pulls in only when relevant. Keeping them in one repo means a single `git clone` gets the full toolkit, and cross-references between them (e.g. a skill that documents a plugin) stay local.
