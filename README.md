# zed

Personal Claude Code plugin with custom skills for Dependabot maintenance,
system-wide cross-project maintenance, cross-session context handoff, and other
repository automation.

## Prerequisites

- [Claude Code](https://claude.com/claude-code) CLI
- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated with access to
  the target repository
- Dependabot enabled on the target repository (for alerts and/or security
  updates)
- For the `maintenance` skill's observability app: `python3` and `sqlite3` (both
  ubiquitous on macOS/Linux; the web app uses only the Python 3 standard
  library, no `pip` installs)

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
2. Batch-merges every ready-to-merge Dependabot PR by folding their branches onto
   a single sweep branch (instead of merging one PR at a time, which re-conflicts
   the rest); PRs that cannot be combined cleanly are punted to the next sweep
3. Fixes up to 10 vulnerability alerts (highest severity first) on that same
   branch, one commit per package
4. Updates the project changelog (if one exists)
5. Pushes the branch and opens **one** PR carrying the batched dependency bumps,
   the vulnerability fixes, and the changelog, with a summary of all actions

Because everything rides one PR, CI runs once and the whole sweep merges once —
avoiding the conflict/rebase/CI cascade that merging Dependabot PRs individually
triggers in multi-module repos.

```
/zed:dependabot-sweep
```

### `maintenance`

Run a maintenance task across **all** your configured projects in one pass.
This skill is an orchestrator: it discovers every project that opts in by
defining a `maintenance-<tag>` skill, dispatches a subagent per project to run
that skill, and records the whole sweep to a local SQLite database that a small
web app renders live so you can watch progress and results across all your
repositories at a glance.

```
/zed:maintenance <tag> [--now] [--fast] [--headless] [--resume [run_id]]
```

- `<tag>` (required) — discover and run the `maintenance-<tag>` skill in each
  participating project (e.g. `/zed:maintenance dependabot` runs each project's
  `maintenance-dependabot` skill).
- `--now` — explicitly select the methodical, serial execution path. Claude Code
  has no user-facing batch primitive for subagents, so the **default** is the
  serial path; `--now` states that intent explicitly.
- `--fast` — dispatch the per-project subagents in parallel (faster, more tokens).
- `--headless` — do not start or open the observability web app.
- `--resume [run_id]` — re-attach to a run parked at **Awaiting You** and drain
  what is left (see **Interactive work**). Defaults to the newest parked run for
  the tag.

**Configuration.** Search roots and a blocklist live in a `config.json` managed
by `scripts/maintenance-config.sh` (defaults to `{ "searchRoots": ["~/projects"],
"blocklist": [] }`). Add a search root with
`maintenance-config.sh add-root <path>` and exclude a project with
`maintenance-config.sh add-block <path-or-name>`.

**Per-project frontmatter flags.** Each project controls how it participates in a
sweep through optional keys in its own `maintenance-<tag>` skill's YAML front
matter (alongside the standard `name`/`description` every skill carries):

| Flag | Type | Default | Effect |
| ---- | ---- | ------- | ------ |
| `priority` | integer | `0` | Where the project runs in the sweep — lower runs earlier, higher later, ties broken by path. See **Ordering**. |
| `interactive` | boolean | `false` | Only on a `maintenance-<tag>-*` sub-skill: marks it work that needs *you*, put in the interactive queue with a Start button instead of run unattended. See **Interactive work**. |

It is read from the leading `---`…`---` block only; signed and quoted forms
(`priority: '-100'`) parse fine, and anything missing or unparseable falls back to
the default. Example:

```yaml
---
name: maintenance-weekly
description: Weekly dependency sweep and redeploy.
priority: 100               # run last, after other projects have pushed updates
---
```

**Ordering.** A project's `maintenance-<tag>` skill can set an integer
`priority` in its front matter to control where it runs: lower runs earlier,
higher later, default `0`, ties broken by path. On the serial path projects run
in strict order; with `--fast` they run in priority **groups** (each group
concurrent, groups in order). Use a negative priority for a project that needs
up-front interaction (runs first) and a positive one for a project that
redeploys centrally-shared apps (runs last).

**Interactive work.** Some maintenance genuinely needs *you* — approving photos,
okaying a rollout, reading something before it ships — and that is not going to
change: as the sweep grows, more tasks will need you, not fewer. So a run has
**two queues at different paces**. The automated queue proceeds unattended as it
always has. The interactive queue is yours: you press **Start** in the app and
work each task at your own pace, in parallel, never blocking the automated half.

The governing rule, and the reason the rest of it is shaped this way: *pausing to
think, walking away, or stopping to file a bug is normal.* Nothing infers your
absence from elapsed time, nothing kills a task that is waiting on you, and the
app shows no timers or countdowns against you.

A project declares interactive work by shipping a sibling skill beside its
`maintenance-<tag>` skill — splitting at the seam where a human is actually
needed, rather than flagging the whole skill and stranding its dependency sweep
behind a photo picker:

```
<project>/.claude/skills/
  maintenance-weekly/SKILL.md                 # automated job
  maintenance-weekly-select-images/SKILL.md   # interactive: true
```

The sub-skill's `description` becomes the label beside its Start button. An
undeclared `maintenance-<tag>-*` skill stays invisible to discovery, exactly as
before.

How a run flows through it:

1. Automated jobs run unattended. A project with an interactive task still
   outstanding ends its job at **`awaiting_interactive`**, never `success`.
2. The app lists each task in a **NEEDS YOU** bar with a Start button. The app is
   a viewer with no channel to the Claude Code session, so Start records your
   intent as a row and the sweep picks it up — a click while the session is busy,
   or after it has parked entirely, is queued rather than lost.
3. The sweep dispatches a subagent for it, running **in parallel** with whatever
   automated work is in flight.
4. An interactive task can **inject a job back into the automated queue** when
   you finish — typically the automated stage that follows it. Injected work is
   picked up even after the automated queue has otherwise drained.
5. The run reaches **Completed** only when both queues drain. Until then it sits
   at **Awaiting You**, which is *not* a finish: `finished_at` stays empty.

If you are still working when the automated queue runs dry, the run **parks** and
the session lets go. Take as long as you like; `/zed:maintenance <tag> --resume`
re-attaches later and drains the rest — including re-dispatching anything the
previous session had already started, so a session ending mid-task strands
nothing. Distinct from **Needs Followup**, which
means the run is over and owes you something afterwards — Awaiting You means the
run is not over.

**Authorization.** The model is **"assume elevated permission for the whole
sweep"**: you authorize **once, up front, for the entire run** rather than per
project (a deliberate trade-off — less granular containment for a far simpler,
more robust model). Most commands need nothing: bare `gh pr merge`/`gh pr close`
match their own allow rules and run in any session. The whole-sweep grant exists
for the remaining case — an un-allowlisted privileged command like a project's
`make deploy` — which would otherwise be prompted for or auto-denied. When the
sweep reaches the execute stage it asks you **once** whether to authorize this
run for privileged commands (default: yes) and creates a single whole-sweep grant;
a typed `/zed:maintenance weekly` needs just one answer. For **unattended** runs
(a scheduled sweep with no one to ask), authorize ahead of time instead:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" grant --tag weekly --ttl 12h
```

While a valid whole-sweep grant exists, a `PreToolUse` hook
(`hooks/maintenance-authz.sh`) returns an `allow` decision for Bash calls so an
un-allowlisted privileged command runs without the auto-accept classifier
prompting or denying it; with no grant it stays silent (never denies). The run
**revokes its grant when it finishes**, so authorization never carries into a
later sweep (the generous default TTL is only a backstop). Manage grants with
`maintenance-authorize.sh list` / `revoke`. Grants live under `<data-dir>/grants/`,
one per tag.

**Followups.** A sweep often leaves work that needs a human (a manual deploy
step, a decision, something to verify). Those are not buried in prose — a project
that partially succeeds gets the job status **`followup`** (between `success` and
`failure`), and the run records one numbered **followup ticket** per outstanding
item. The run then finishes at status **Needs Followup** instead of Completed.
Resolve a ticket from any session with the `maint-followup` skill:

```bash
/zed:maint-followup <ticket-number> <update|done|nope> [comment]
```

`update` adds a progress comment, `done` closes it completed, `nope` closes it as
won't-do; omit the comment and the skill summarizes from the session in one
sentence. When the last open ticket of a run is resolved, that run flips from
**Needs Followup** to **Completed** automatically. Inspect tickets with
`maintenance-db.sh list-followups` / `get-followup`.

**Observability app.** Unless `--headless`, the skill starts a single-file
Python 3 HTTP server (`app/server.py`, default port 7373, probing upward if
busy) that serves a vanilla-JS UI from `app/static/`. The UI shows a sidebar of
runs, a per-run stage stepper, live per-project job cards (pending / running /
success / followup / failure / skipped / awaiting you) with health indicators, a
**NEEDS YOU bar** with Start buttons for interactive tasks, a **followups
ticket table** (number, project, what's needed, status, latest update), and
rendered Markdown summaries — updated live via Server-Sent Events with a polling
fallback. It opens the database **read-only** (WAL mode lets readers never block
the subagent writers) apart from a single narrow write path — the Start button,
which records your intent for the sweep to pick up, refuses cross-origin
requests, and touches nothing else. It uses only the Python 3 standard library —
no `pip`, no npm, no build step, no external CDN. Control it directly with:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" start    # start + open browser
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" status
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" stop
```

All runtime state (the SQLite database, config, and monitor pid/port/log) lives
in `${CLAUDE_PLUGIN_DATA}/maintenance` (or
`${XDG_DATA_HOME:-$HOME/.local/share}/zed-maintenance`), so history persists
across runs and plugin updates.

### `maint-followup`

Record progress on a followup ticket raised by a `maintenance` run. Comments on,
completes, or declines a single ticket; closing the last open ticket of a run
flips that run from **Needs Followup** to **Completed**.

```
/zed:maint-followup <ticket-number> <update|done|nope> [comment]
```

With no `comment`, the skill writes a one-sentence summary of what happened toward
the ticket from the current session's context.

### `maint-followup-do`

Examine a followup ticket and **actually move it forward**. Where `maint-followup`
only records a decision you've already made, this skill investigates the ticket,
then either completes the outstanding work in the current session — verifying the
change — or explains a concrete path forward when it can't. It records progress on
the ticket automatically and asks before closing it.

```
/zed:maint-followup-do <ticket-number>
```

Operates only on the current repository; if the ticket belongs to another project,
it reports the mismatch and stops.

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

Check out a pull request (the current branch's PR or a named one) and make sure
it has a review to act on first: use existing feedback if any exists, wait for a
pending Copilot review to land, or — only as a last resort — generate one (via
the codex CLI, the copilot CLI, or a Claude Code subagent, in that order) and
post it as a PR comment. Then read the review comments, evaluate each for
validity against the current code, apply the fixes that are warranted, commit and
push them to the PR branch, and report on what was done.

```
/zed:pr-review-fix
/zed:pr-review-fix 123
```

### `dependabot-merge`

Batch-merge the open Dependabot PRs that are ready (no conflicts, all checks
passing). When two or more are ready, it combines their branches onto a single
integration branch and merges once — running CI a single time and avoiding the
conflict cascade that merging interdependent PRs one at a time causes. A single
ready PR is merged directly; any PR that cannot be combined cleanly is left open
for next time.

```
/zed:dependabot-merge
```

### `send-context`

Summarize the current Claude Code session — goal, current state, decisions and
constraints, open questions, pointers — and write it to a Markdown handoff file
(`claude-context-handoff.md` by default) so another Claude Code session can
pick up the work. Pass a destination folder or full path as an argument to
write somewhere other than the current directory.

```
/zed:send-context
/zed:send-context ~/projects/other-repo
```

### `recv-context`

Read a context handoff file written by `send-context`, absorb its contents into
the current session, and delete the file so the handoff is consumed once. Pass
a folder or file path to read from somewhere other than the current directory.
Add `--keep` to preserve the file after reading.

```
/zed:recv-context
/zed:recv-context ~/projects/other-repo
/zed:recv-context --keep
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
app/                # Python-stdlib observability web app for the maintenance skill
  server.py         # Single-file HTTP/SSE server (Python 3 stdlib only)
  static/           # Vanilla-JS UI (index.html, app.js, styles.css)
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
