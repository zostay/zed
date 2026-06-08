---
name: maintenance
description: Run system-wide maintenance (e.g. a weekly Dependabot sweep) across all your configured projects by discovering and executing each project's `maintenance-<tag>` skill, with a live observability web app that shows per-project progress and results. Invoke as `/zed:maintenance <tag>`.
---

# Maintenance

Run a maintenance task named `<tag>` across every configured project that opts
in by defining a `maintenance-<tag>` skill. This skill is an **orchestrator**: it
discovers the participating projects, dispatches a subagent per project to run
that project's own `maintenance-<tag>` skill, and records everything to a local
SQLite database that a small web app renders live so you can watch the sweep
across all your repositories at a glance.

## Argument & flags

```
/zed:maintenance <tag> [--now] [--fast] [--headless]
```

- `<tag>` (required) — discover and run the `maintenance-<tag>` skill in each
  participating project. Must match `[A-Za-z0-9._-]+`. Example: `/zed:maintenance dependabot`
  runs each project's `maintenance-dependabot` skill.
- `--now` — explicitly select the methodical, serial execution path (see batch note).
- `--fast` — dispatch the per-project subagents in parallel (faster, more tokens).
- `--headless` — do not start or open the observability web app.

### Batch note (be honest about this)

Claude Code does **not** currently expose a user-facing batch primitive for
orchestrating subagents from within a skill session. There is no "submit a batch
of subagents and await them" API to call. Consequently:

- The **default** behavior is the methodical **serial** path: one project
  subagent at a time, in a deterministic order.
- `--now` **explicitly** selects that same serial path. It is accepted for
  forward-compatibility and to let you state intent; it does not unlock a hidden
  batch mode.
- `--fast` opts into running the per-project subagents **in parallel** by
  dispatching multiple Task subagents in one turn.

Do not pretend a batch API exists. Pick serial (default / `--now`) or parallel
(`--fast`) and follow the corresponding execution path in Step 5.

## Helper scripts

All scripts resolve their data directory the same way (via
`scripts/maintenance-common.sh`) and write to a single SQLite database, so the
web app and the orchestrator always agree on state.

Invoke each script **directly by its path** (it is executable and carries a
`#!/usr/bin/env bash` shebang) — do **not** prefix the call with `bash`. A bare
`bash` token has to be resolved against the caller's `PATH`, which in a stripped
subshell may omit Homebrew's `bash` and fail with `command not found: bash`,
stalling the sweep. Direct execution lets the kernel pick the interpreter and
the scripts self-heal `PATH` for their own helpers. Invoke them as:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" ...
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" ...
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-discover.sh" <tag>
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" ...
```

Resolve the absolute path to the DB script once and keep it; you will hand it to
each subagent so it can log its own progress:

```bash
DB_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh"
```

## Process

Work through these steps in order. Keep an internal action log; it feeds the
final roll-up summary. Capture `run_id` and each `job_id` exactly as shown — the
scripts print bare integers on stdout for this purpose.

### 1. Read configuration

Ensure the config exists, then read the search roots and blocklist:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" init
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" roots
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" blocklist
```

`config.json` defaults to `{ "searchRoots": ["~/projects"], "blocklist": [] }`.
If `roots` prints only the default `~/projects` and that may not match this
user's layout, mention that they can add a search root with:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" add-root <path>
```

(and remove with `remove-root <path>`; blocklist entries via `add-block`/`remove-block`).

### 2. Initialize observability

Create the database (idempotent) and open a run. Choose the mode string from the
flags: `fast` for `--fast`, `now` for `--now`, otherwise `serial`.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" init

RUN_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  start-run --tag "<tag>" --mode "<serial|fast|now>" \
  --options '{"now":false,"fast":false,"headless":false}')

"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage reading-config
```

`start-run` prints the new `run_id` on stdout — capture it into `RUN_ID`. Put
the actual flag values into `--options` JSON.

### 3. Start the monitor

Unless `--headless`, start the observability web app and surface its URL:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" start
```

This prints `http://127.0.0.1:<port>` and opens a browser. Log the URL as a run
event so it appears in the run history:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level info --message "Observability app: http://127.0.0.1:<port>"
```

**Monitor failures must not abort the run.** If `maintenance-monitor.sh start`
fails (e.g. `python3` missing, port unavailable), log a `warn` event and
continue — the sweep still runs and is fully recorded to the DB:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level warn --message "Could not start observability app; continuing without it."
```

With `--headless`, skip starting the app entirely and note to the user that they
can start it later (and revisit history) with the same command:
`maintenance-monitor.sh start`.

### 4. Discover participating projects

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage discovering
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-discover.sh" <tag>
```

`maintenance-discover.sh` searches the configured roots for projects that define
a `maintenance-<tag>` skill (at `<project>/.claude/skills/maintenance-<tag>/SKILL.md`
or `<project>/skills/maintenance-<tag>/SKILL.md`), applies the blocklist, reads
each skill's execution `priority` (see **Ordering** below), and prints **JSONL**,
one object per line, sorted by `(priority ascending, project_path)`:

```json
{"project_path":"...","project_name":"...","skill_name":"maintenance-<tag>","skill_path":"...","priority":0}
```

The orchestrator must preserve this emitted order: register jobs and (for serial
runs) dispatch subagents in the exact sequence the lines arrive, so the priority
ordering is honored end to end.

For each line, register a job and capture its `job_id`:

```bash
JOB_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  add-job --run "$RUN_ID" \
  --path "<project_path>" --name "<project_name>" --skill "<skill_name>")
```

Keep an ordered list of `(JOB_ID, project_path, project_name, skill_name)`. Log
how many projects were found:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level info --message "Discovered N project(s) defining maintenance-<tag>."
```

If discovery printed nothing (no participating projects), finish the run and
stop here:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  finish-run --run "$RUN_ID" --status completed \
  --summary "No projects define a \`maintenance-<tag>\` skill under the configured search roots."
```

Then report that to the user (with the monitor URL if it was started) and stop.

### 5. Execute (dispatch a subagent per project)

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage executing
```

For each job, you (the orchestrator) own the job lifecycle in the DB, and the
subagent does the project work and logs its own progress events.

**Per job, the orchestrator:**

1. Marks the job running before dispatch:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" start-job --job "$JOB_ID"
   "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
     log --run "$RUN_ID" --job "$JOB_ID" --level info --message "Starting maintenance-<tag> in <project_name>."
   ```
2. Dispatches a subagent (via the Task/Agent tool). The subagent's task is to:
   - `cd` into `project_path`,
   - invoke that project's `maintenance-<tag>` skill and do the work,
   - log its own progress events to the **same** database, and
   - return a concise Markdown summary of what it changed.

   Give the subagent exactly these three coordinates so it can log live activity
   that the web app shows in place:
   - its `job_id` (e.g. `$JOB_ID`),
   - the absolute path to the DB script (`$DB_SCRIPT`, i.e.
     `${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh`),
   - the `run_id` (`$RUN_ID`).

   Instruct the subagent to log progress with:
   ```bash
   "<DB_SCRIPT>" log --run <RUN_ID> --job <JOB_ID> --level info --message "<what it's doing>"
   ```
   (using `--level warn`/`error`/`success` as appropriate) so the live view
   updates while it works. The subagent should NOT touch the run row or call
   `finish-run`; the orchestrator owns those.
3. After the subagent returns, write its summary to a temp file and finish the
   job with the right status (`success`, `failure`, or `skipped`):
   ```bash
   SUMMARY_TMP=$(mktemp)
   printf '%s\n' "<subagent's Markdown summary>" > "$SUMMARY_TMP"
   "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
     finish-job --job "$JOB_ID" --status success --summary-file "$SUMMARY_TMP"
   rm -f "$SUMMARY_TMP"
   ```
   On failure pass `--status failure` and `--error "<short reason>"`; if the
   project decided there was nothing to do, `--status skipped`. Log a closing
   event for the job and append the result to your action log.

**Serial (default / `--now`):** dispatch one subagent, wait for it to return,
finish its job, then move to the next — in the discovery order (priority
ascending, then path). This is the path that honors per-project `priority`: a
project that needs up-front user interaction runs before the rest, and one that
redeploys centrally-shared apps runs after them.

**Parallel (`--fast`):** run **priority groups** in order, parallel *within* each
group. Partition the jobs by their `priority` value (the field discovery emitted)
into ascending groups — e.g. all `-100`s, then all `0`s, then all `100`s, and
any other values as their own groups in between. Then, **one group at a time**:

1. `start-job` for every job in the group.
2. Dispatch a Task subagent for each job in that group **in a single turn** so
   the whole group runs concurrently.
3. Wait for the entire group to finish and `finish-job` each one **before**
   starting the next group.

This keeps `--fast`'s concurrency while still honoring `priority`: a `-100`
project (e.g. one needing up-front user interaction) completes before any `0`
project starts, and a `100` project (e.g. one redeploying centrally-shared apps)
only starts after every lower group is done. Projects sharing a priority have no
ordering guarantee relative to each other — that is the point of putting them in
the same group. A single-group sweep (everything at the default `0`) is just one
parallel batch, exactly as before.

Concurrent DB writes from the subagents are safe by design (the DB uses WAL mode
+ `busy_timeout`), so **no extra coordination is needed** — just give each
subagent its own `job_id`.

If a subagent crashes or returns nothing usable, mark that job
`--status failure --error "<reason>"`, log an `error` event, and keep going with
the remaining projects. One project's failure must not abort the others.

### 6. Summarize

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage summarizing
```

Build a Markdown roll-up from your action log: per-project results (success /
failure / skipped with one-line notes), totals, and a "needs attention" section
listing any failures. Write it to a temp file and finish the run; `finish-run`
sets the stage to `done` implicitly:

```bash
RUN_SUMMARY_TMP=$(mktemp)
# ... write the Markdown roll-up to "$RUN_SUMMARY_TMP" ...
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  finish-run --run "$RUN_ID" --status completed --summary-file "$RUN_SUMMARY_TMP"
rm -f "$RUN_SUMMARY_TMP"
```

Use `--status failed` only if the orchestration itself broke (individual project
failures still make a `completed` run — they are reported in the summary).

### 7. Report & observe

Print the roll-up summary to the user, along with the monitor URL (if the app is
running) so they can review live progress and history:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" url   # prints URL if running
```

Tell the user they can:

- stop the app anytime with `maintenance-monitor.sh stop`, and
- start it again later with `maintenance-monitor.sh start` to revisit this run
  and all past runs (the database persists across runs and plugin updates).

## Ordering

By default every participating project runs in the middle of the pack, ordered
alphabetically by path. A project can override where it falls by declaring an
integer `priority` in the front matter of its own `maintenance-<tag>` skill:

```yaml
---
name: maintenance-dependabot
description: ...
priority: -100
---
```

Semantics:

- **Lower runs earlier, higher runs later.** The default is `0`.
- Use a **negative** priority for a project that must run **first** — e.g. one
  whose maintenance needs up-front user interaction, so you deal with it before
  walking away from the sweep.
- Use a **positive** priority for a project that must run **last** — e.g. one
  that redeploys centrally-shared applications which earlier projects may have
  just updated, so it picks up their changes.
- Ties (same priority, including the common case of everything at `0`) break by
  `project_path`, keeping the order deterministic across runs.

The numbers are only relative ranks, not slots — pick values with room to insert
later (`-100`, `100`) rather than `-1`/`1`. `maintenance-discover.sh` reads the
`priority`, sorts on it, and emits projects in execution order. Both execution
paths honor it:

- **Serial (default / `--now`)** runs projects strictly in the emitted order, so
  every priority is fully ordered relative to every other.
- **Parallel (`--fast`)** runs projects in **priority groups**: all projects at a
  given priority run concurrently as one batch, and each group completes before
  the next-higher group begins (see Step 5). So priorities are ordered relative
  to each other, but projects sharing a priority are not ordered among
  themselves. If a project must run strictly before or after *every* other —
  including others at the same rank — give it its own distinct priority, or use
  the serial path.

## Robustness

- The run is fully recorded to the DB regardless of whether the web app is up,
  so running `--headless` (or with `python3` unavailable) loses no data.
- A monitor that fails to start is a **warning**, never a fatal error — log it
  and proceed (Step 3).
- A single project's failure is recorded on its job and reported in the summary;
  it never aborts the rest of the sweep (Step 5).
