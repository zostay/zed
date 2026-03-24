# claude-plugin

Personal Claude Code plugin with custom skills, agents, and tools.

## Structure

```
.claude-plugin/
  plugin.json       # Plugin manifest
skills/             # Custom skills (invoked via /claude-plugin:skill-name)
agents/             # Custom agent definitions
hooks/              # Event hooks for Claude Code lifecycle events
scripts/            # Helper scripts used by skills, agents, or hooks
```

## Installation

Add a marketplace that includes this plugin, or test locally:

```bash
claude --plugin-dir /path/to/claude-plugin
```

To install from GitHub via a marketplace, add the marketplace containing this
plugin and then:

```bash
/plugin install claude-plugin
```

## Adding a Skill

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

The skill will be available as `/claude-plugin:my-skill`.

## Adding an Agent

Create a markdown file under `agents/`:

```markdown
---
name: my-agent
description: What this agent specializes in.
model: sonnet
---

Agent system prompt and behavior instructions...
```

## Adding Hooks

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

## Environment Variables

Two variables are available in skills, agents, hooks, and configs:

- `${CLAUDE_PLUGIN_ROOT}` - Absolute path to the plugin installation directory
- `${CLAUDE_PLUGIN_DATA}` - Persistent data directory that survives plugin updates

## License

MIT
