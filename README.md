# zed

Personal Claude Code plugin with custom skills for Dependabot maintenance and
other repository automation.

## Prerequisites

- [Claude Code](https://claude.com/claude-code) CLI
- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated with access to
  the target repository
- Dependabot enabled on the target repository (for alerts and/or security
  updates)

## Installation

### Per-session (local checkout)

Clone the repo and load the plugin for your current session:

```bash
git clone https://github.com/zostay/zed.git
claude --plugin-dir ./zed
```

### Persistent install via marketplace

Add this repo as a marketplace, then install the plugin:

```bash
claude plugin marketplace add https://github.com/zostay/zed
claude plugin install zed
```

## Skills

All skills are invoked as `/zed:<skill-name>` from within Claude Code.

### `dependabot-sweep`

Run a full Dependabot maintenance sweep in a single pass. This orchestrates the
work of the other three skills:

1. Requests rebases for all conflicting Dependabot PRs
2. Merges all ready-to-merge Dependabot PRs
3. Fixes up to 10 vulnerability alerts (highest severity first), creating a
   branch with one commit per package
4. Updates the project changelog (if one exists)
5. Pushes the branch and opens a PR with a summary of all actions

```
/zed:dependabot-sweep
```

### `dependabot-fix`

Fix the highest-priority open Dependabot vulnerability alert. Analyzes all open
alerts, ranks by severity/CVSS/impact, updates the dependency to the patched
version, and runs tests to verify.

```
/zed:dependabot-fix
```

### `dependabot-unblock`

Unblock stuck Dependabot PRs. Requests rebases for conflicting PRs, then
investigates the first PR with failing checks and attempts a trivial fix.

```
/zed:dependabot-unblock
```

### `pr-review-fix`

Check out a pull request (the current branch's PR or a named one), read its
GitHub review comments, evaluate each for validity against the current code,
apply the fixes that are warranted, and report on what was done.

```
/zed:pr-review-fix
/zed:pr-review-fix 123
```

### `dependabot-merge`

Merge the oldest open Dependabot PR that is ready (no conflicts, all checks
passing) using the repository's default merge method.

```
/zed:dependabot-merge
```

## Project Structure

```
.claude-plugin/
  plugin.json       # Plugin manifest
  marketplace.json  # Marketplace manifest (for install via marketplace)
skills/             # Custom skills (invoked via /zed:skill-name)
agents/             # Custom agent definitions
hooks/              # Event hooks for Claude Code lifecycle events
scripts/            # Helper scripts used by skills, agents, or hooks
```

## Development

### Adding a Skill

Create a directory under `skills/` with a `SKILL.md` file:

```
skills/my-skill/
  SKILL.md
```

The `SKILL.md` file uses YAML frontmatter for metadata:

```markdown
---
name: my-skill
description: What this skill does and when to use it.
---

Instructions for Claude when this skill is invoked...
```

The skill will be available as `/zed:my-skill`.

### Adding an Agent

Create a markdown file under `agents/`:

```markdown
---
name: my-agent
description: What this agent specializes in.
model: sonnet
---

Agent system prompt and behavior instructions...
```

### Adding Hooks

Define event hooks in `hooks/hooks.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/my-script.sh"
          }
        ]
      }
    ]
  }
}
```

### Environment Variables

Two variables are available in skills, agents, hooks, and configs:

- `${CLAUDE_PLUGIN_ROOT}` - Absolute path to the plugin installation directory
- `${CLAUDE_PLUGIN_DATA}` - Persistent data directory that survives plugin updates

## License

MIT
