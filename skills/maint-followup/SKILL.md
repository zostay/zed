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
- Resolving tickets is the *only* thing that moves a run from **Needs Followup**
  to **Completed** — there is no separate "complete the run" step.
