---
name: maint-followup-do
description: Examine a maintenance followup ticket, then either address the outstanding work in this session or explain the concrete path forward. Invoke as `/zed:maint-followup-do <ticket-number>`. Records progress on the ticket; asks before closing it.
---

# Maintenance Followup — Do

Pick up one followup **ticket** raised by a `/zed:maintenance` run and actually
move it forward. Where the sibling `maint-followup` skill only *records* a decision
you have already made, this skill does the investigating and the work: it reads the
ticket, figures out what needs to happen, and then **either does it** (if it can be
done from this session) **or explains the concrete path forward** (if it can't).

It is the "worker" counterpart to `maint-followup` (the "recorder"). When it makes
progress it records that progress on the ticket for you — see
[Recording the outcome](#5-record-the-outcome) — so you don't need a separate
`/zed:maint-followup` call for the common cases.

## Argument

```
/zed:maint-followup-do <ticket-number>
```

- `<ticket-number>` (required) — the sequential ticket number the maintenance app
  assigned when the followup was recorded (e.g. `7`). Must be a positive integer.
  If it is missing or not a positive integer, show the correct form and stop.

## Helper script

The observability database is read and written through `maintenance-db.sh`. Invoke
it **directly by its path** (do not prefix with `bash`):

```bash
DB="${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh"
```

## Process

### 1. Load the ticket

```bash
"$DB" get-followup --id <ticket-number>
```

This prints a JSON object with `ticket`, `run_id`, `project_name`, `title`,
`detail`, `status`, timestamps, and a `comments` timeline. If the command fails or
prints nothing, the ticket does not exist — report that and stop (suggest
`"$DB" list-followups` to see open tickets).

If the ticket is already closed (`done`/`wontdo`), say so and stop unless the user
explicitly asked to re-open the investigation. There is normally nothing to do on a
closed ticket.

For extra context on what the sweep was doing, you may also read the sibling
tickets from the same run:

```bash
"$DB" list-followups --run <run-id>
```

### 2. Confirm you are in the right repository

The ticket's `project_name` identifies the repository the work belongs to. It is
recorded as the **basename of the project directory** the sweep discovered (see
`scripts/maintenance-discover.sh`), so compare against the current repo's directory
basename — **not** its `origin` remote, which can differ from the directory name and
cause a false mismatch:

```bash
[ "$(basename "$(git rev-parse --show-toplevel)")" = "<project_name>" ]
```

If the current repo's directory basename does **not** match the ticket's
`project_name`:

- Tell the user the ticket belongs to `<project_name>` but this session is in
  `<current repo>`, and **stop**.
- Suggest they re-run `/zed:maint-followup-do <ticket-number>` from a Claude session
  opened in the `<project_name>` repository.

Do not `cd` into another project or clone anything. Only proceed when the current
repo is the ticket's project.

### 3. Understand what the ticket needs

Read the `title`, `detail`, and every entry in the `comments` timeline. From those,
state — in one or two sentences, to yourself — what concrete outcome would resolve
this ticket. Followup tickets are often terse (they were filed mid-sweep), so treat
the text as a pointer, not a spec: go look at the actual code, PRs, alerts, CI logs,
or config the ticket refers to before deciding what "done" means.

Be skeptical of stale framing. A ticket may have been filed for a reason that no
longer holds (a PR since merged, an alert since resolved, a blocker since cleared).
Verify the situation against the live repository before acting.

### 4. Address it, or map the path forward

Decide whether the outstanding work can be completed from this session:

**If you can do it** — make the change. Follow the repo's conventions, keep the
change scoped to what the ticket asks for, and **verify it** the way this project
expects (build/tests/lint, or by exercising the affected behavior). Don't claim
completion you haven't checked. If the work is genuinely obsolete (already resolved,
or should not be pursued), that is a valid outcome too — a `nope` in step 5.

**If you can't do it** — do not force it. Produce a clear, concrete **path
forward**: what specifically needs to happen, what is blocking it (missing access,
a decision only the user can make, an upstream dependency, a required human review),
and the next actionable step. Vague ("needs more investigation") is not good enough;
name the file, command, PR, person, or decision involved.

Never resolve a blocker with dangerous shortcuts — no `--admin`, no branch-protection
bypass, no `git reset --hard`/`git checkout .` over unrelated uncommitted changes, no
force-merging past failing required checks. If those are the only ways forward, that
is a finding for the path-forward write-up, not an action to take.

**If the work surfaces something new** — a decision that has to be made before the
ticket can move, or a defect you tripped over while investigating, or a fix whose
implications reach past this ticket — **never file a followup for it.** Do not call
`"$DB" add-followup` from this skill, for any reason at all. Followup tickets exist
only to flag work that needs the user *personally* before the next weekly maintenance
run, and only a `/zed:maintenance` sweep may open them. Those two cases — "this needs
a decision first" and "I found another bug while I was in here" — are precisely the
rationalizations that produced tickets nobody asked for.

New findings go elsewhere, in this order:

1. **A GitHub issue on this project.** Search first so you don't duplicate one:

   ```bash
   gh issue list --state open --search "<a few distinctive words>"
   gh issue create --title "<what is wrong>" --body "<what you observed, where, why it matters>"
   ```

   If a matching open issue already exists, comment on that one
   (`gh issue comment <n> --body ...`) instead of opening a second.

   Step 2 already confirmed this session is in the ticket's project, so these run
   bare and resolve to the right repository. The issue verbs carry standing allow
   rules, but don't assume it — if one comes back permission-denied, that is
   case 2 below, never a reason to file a followup.

   **Then record the issue against the ticket's run**, so it shows up badged
   **NEW** on that run's debrief in the observability app instead of living only
   in this session's transcript. The ticket JSON you loaded in step 1 carries both
   ids you need — `run_id` and `job_id`:

   ```bash
   "$DB" add-project-issue --run <run_id> --job <job_id> \
     --project "<project_name>" --repo "<owner/repo>" --origin created \
     --kind issue --number <n> --title "<issue title>" --url "<url gh printed>" \
     --state open --age-days 0 --rank 20 \
     --triage "Filed while working followup #<ticket-number>: <one sentence>"
   ```

   `<n>` is the trailing path segment of the URL `gh issue create` printed, and
   `<owner/repo>` comes from `gh repo view --json nameWithOwner -q .nameWithOwner`.
   If `job_id` is null on the ticket, omit `--job`. If the call fails, note it and
   move on — the issue itself is filed and named in your report, which is still
   the durable record.

2. **Straight to the user, in your step 6 report** — when the project has no GitHub
   remote (`gh repo view` fails), when `gh issue create` is denied, or when the
   finding is really a question only they can answer.

Either way, say where it went in the comment you record in step 5 (issue URL, or
"raised with you directly"), so the trail from ticket to finding isn't lost.

### 5. Record the outcome

Record progress on the ticket via the same database command the `maint-followup`
skill uses. Choose the action from what actually happened:

- **`update`** — you made progress or produced a path forward, but the ticket is not
  resolved. The ticket stays **open**. Record this **automatically** (no
  confirmation needed) — it only appends a comment.
- **`done`** — the outstanding work is complete and verified. **Closes** the ticket.
- **`nope`** — the work should not be pursued (obsolete, superseded, or a deliberate
  decline). **Closes** the ticket.

Because `done` and `nope` **close** the ticket — and closing the last open ticket of
a run flips the whole run from **Needs Followup** to **Completed** — **ask the user
to confirm before recording a `done` or a `nope`.** State plainly what you finished
(or why you're declining) and that closing it will resolve the ticket. Only run the
close after they confirm; if they decline, fall back to an `update`.

Write a one-sentence comment describing what you did, found, or decided — and if step
4 sent a finding somewhere else, name that destination in it (the issue URL, or that
you raised it with the user directly):

```bash
"$DB" update-followup --id <ticket-number> --action <update|done|nope> --comment "<one sentence>"
```

`update-followup` is the **only** followup command this skill runs. It comments and it
closes; it never opens a ticket.

It prints a JSON receipt, e.g.:

```json
{"ticket":7,"status":"done","run_id":3,"open_remaining":0,"run_completed":true}
```

(See the `maint-followup` skill for the full semantics of this command.)

### 6. Report

Tell the user, concisely:

- the ticket number, its project/title, and what you determined it needed;
- **what you did** — the change made and how you verified it — **or** the path
  forward, if you couldn't complete it;
- **anything new you filed or escalated** (step 4) — the issue URL, or the
  finding you are raising with them directly. Say plainly that it is new work
  this session surfaced, not part of the ticket's original scope. A filed issue
  also appears badged **NEW** on the run's page in the observability app;
- **anything you filed or escalated on the way** — the URL of the GitHub issue you
  opened or commented on, or the finding you are handing them directly because there
  was no repo to file it against or because only they can decide it;
- the action recorded on the ticket and its new status; and
- from the receipt: how many followups remain open on the run (`open_remaining`),
  and — if `run_completed` is `true` — that this resolved the last one, so **the run
  is now marked Completed**.

Note that the observability app reflects the change live (the ticket row and run
status update without a refresh).

## Notes

- This skill handles **one** ticket per invocation and only in the **current**
  repository.
- It composes with `maint-followup`: this skill does the work and records the common
  outcomes; use `/zed:maint-followup <n> <update|done|nope> [comment]` directly if you
  only want to record a decision without any investigation.
- Resolving tickets (via `done`/`nope`) is the only thing that moves a run from
  **Needs Followup** to **Completed** — there is no separate "complete the run" step.
