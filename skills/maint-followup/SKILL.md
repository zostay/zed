---
name: maint-followup
description: Record progress on a maintenance followup ticket — comment on it, mark it done, or decline it. Invoke as `/zed:maint-followup <ticket-number> <update|done|nope> [comment]`. When the last open ticket of a run is closed, the run flips to Completed.
---

# Maintenance Followup

Update a followup **ticket** raised by a `/zed:maintenance` run. When a sweep
finishes with work that still needs a human, it leaves the run at status
**Needs Followup** and opens one numbered ticket per outstanding item (visible in
the observability app and via `maintenance-db.sh list-followups`). This skill
records progress on one of those tickets and, when the last open ticket of a run
is resolved, the run automatically graduates to **Completed**.

## Argument

```
/zed:maint-followup <ticket-number> <status> [comment]
```

- `<ticket-number>` (required) — the sequential ticket number the app assigned
  when the followup was recorded (e.g. `7`). Must be a positive integer.
- `<status>` (required) — one of:
  - `update` — record a progress comment; the ticket stays **open**.
  - `done` — record a comment and **close** the ticket as completed.
  - `nope` — record a comment and **close** the ticket as won't-do (you have
    decided not to pursue this one).
- `[comment]` (optional) — the rest of the line is the progress comment. **If no
  comment is given, write a single concise sentence summarizing what has happened
  toward this ticket from the current session's context** (what you did, found,
  or decided). If the session has no relevant context, fall back to a short
  status-appropriate note (e.g. for `done`: "Completed."; for `nope`: "Declining
  this one."; for `update`: "Checked in; no change yet.").

## Helper script

The observability database is written through `maintenance-db.sh`. Invoke it
**directly by its path** (do not prefix with `bash`):

```bash
DB="${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh"
```

## Process

### 1. Parse the argument

Split the argument into `<ticket-number>`, `<status>`, and the optional
remaining `<comment>`. Validate:

- `<ticket-number>` is a positive integer. If not, tell the user the correct form
  and stop.
- `<status>` is exactly `update`, `done`, or `nope`. If it is missing or
  something else, explain the three valid values and stop.

### 2. Look up the ticket

```bash
"$DB" get-followup --id <ticket-number>
```

This prints a JSON object (`ticket`, `project_name`, `title`, `detail`, `status`,
`run_id`, and a `comments` timeline). If the command fails / prints nothing, the
ticket does not exist — report that and stop (suggest `"$DB" list-followups` to
see open tickets).

Note the ticket's `title`, `project_name`, and current `status`. If it is already
closed (`done`/`wontdo`), still proceed (a late comment or re-close is allowed),
but mention its current state in your report.

### 3. Determine the comment

If the user supplied a comment, use it verbatim. **Otherwise, compose one concise
sentence** describing what has happened toward this ticket using the current
session context — reference the concrete action/finding/decision if the session
has one; otherwise use the short status-appropriate fallback above. Keep it to a
single sentence.

### 4. Record it

```bash
"$DB" update-followup --id <ticket-number> --action <status> --comment "<comment>"
```

This appends the comment, sets the ticket's status (`update` leaves it open;
`done`→done; `nope`→wontdo), and, when a close resolves the **last** open ticket
of a `needs_followup` run, flips that run to `completed`. It prints a JSON receipt:

```json
{"ticket":7,"status":"done","run_id":3,"open_remaining":0,"run_completed":true}
```

### 5. Report

Tell the user, concisely:

- the ticket number, its project/title, and its new status,
- the comment that was recorded,
- and, from the receipt: how many followups remain open on that run
  (`open_remaining`), and — if `run_completed` is `true` — that this resolved the
  last one so **the run is now marked Completed**. Otherwise note how many remain.

Mention that the observability app reflects the change live (the ticket row and
the run status update without a refresh).

## Notes

- This skill only touches a single ticket per invocation. To see all tickets for
  a run, use `"$DB" list-followups --run <run-id>` (or `list-followups` for all).
- **Never open a new followup from here.** `update-followup` is the only followup
  command this skill runs; do not call `"$DB" add-followup`, not for a decision that
  is blocking this ticket and not for a defect you noticed while recording it. Only a
  `/zed:maintenance` sweep opens tickets, and only for work needing the user
  personally before the next weekly run. Send new findings to a GitHub issue on the
  project instead — but **establish which repository that is first.** This skill can
  be invoked from any directory, and a bare `gh issue …` resolves the repo from the
  session's cwd, so filing without checking lands the issue on whatever repo the user
  happens to be sitting in. The ticket's `project_name` (from `get-followup` in
  step 2) is recorded as the **basename of the project directory** the sweep
  discovered, so compare against the current repo's directory basename — not its
  `origin` remote, which can differ and cause a false mismatch:

  ```bash
  [ "$(basename "$(git rev-parse --show-toplevel)")" = "<project_name>" ]
  ```

  - **They match** — file it bare: `gh issue list --state open --search ...` first
    so you don't duplicate, then comment on the match if there is one, otherwise
    `gh issue create`.
  - **They do not match** (or you are not in a git repo at all) — **do not file
    anything.** You cannot name the right repository from here, and guessing one is
    worse than not filing. Report the finding to the user in step 5 instead, saying
    it belongs on `<project_name>`.

  Also report it to the user rather than filing when the project has no GitHub
  remote, when `gh issue create` comes back permission-denied (the issue verbs
  carry standing allow rules, but don't assume it — a session whose settings
  differ can have them blocked), or when the finding is really a question only
  they can answer. A blocked or unfilable finding is **never** downgraded to a followup
  ticket. Then say where it went in the comment you record, so the trail isn't lost.
- Resolving tickets is the *only* thing that moves a run from **Needs Followup**
  to **Completed** — there is no separate "complete the run" step.
