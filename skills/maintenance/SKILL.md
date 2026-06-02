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
web app and the orchestrator always agree on state. Invoke them as:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" ...
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" ...
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-discover.sh" <tag>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" ...
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
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" init
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" roots
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" blocklist
```

`config.json` defaults to `{ "searchRoots": ["~/projects"], "blocklist": [] }`.
If `roots` prints only the default `~/projects` and that may not match this
user's layout, mention that they can add a search root with:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" add-root <path>
```

(and remove with `remove-root <path>`; blocklist entries via `add-block`/`remove-block`).

### 2. Initialize observability

Create the database (idempotent) and open a run. Choose the mode string from the
flags: `fast` for `--fast`, `now` for `--now`, otherwise `serial`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" init

RUN_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  start-run --tag "<tag>" --mode "<serial|fast|now>" \
  --options '{"now":false,"fast":false,"headless":false}')

bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage reading-config
```

`start-run` prints the new `run_id` on stdout — capture it into `RUN_ID`. Put
the actual flag values into `--options` JSON.

### 3. Start the monitor

Unless `--headless`, start the observability web app and surface its URL:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" start
```

This prints `http://127.0.0.1:<port>` and opens a browser. Log the URL as a run
event so it appears in the run history:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level info --message "Observability app: http://127.0.0.1:<port>"
```

**Monitor failures must not abort the run.** If `maintenance-monitor.sh start`
fails (e.g. `python3` missing, port unavailable), log a `warn` event and
continue — the sweep still runs and is fully recorded to the DB:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level warn --message "Could not start observability app; continuing without it."
```

With `--headless`, skip starting the app entirely and note to the user that they
can start it later (and revisit history) with the same command:
`maintenance-monitor.sh start`.

### 4. Discover participating projects

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage discovering
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-discover.sh" <tag>
```

`maintenance-discover.sh` searches the configured roots for projects that define
a `maintenance-<tag>` skill (at `<project>/.claude/skills/maintenance-<tag>/SKILL.md`
or `<project>/skills/maintenance-<tag>/SKILL.md`), applies the blocklist, and
prints **JSONL**, one object per line, sorted by `project_path`:

```json
{"project_path":"...","project_name":"...","skill_name":"maintenance-<tag>","skill_path":"..."}
```

For each line, register a job and capture its `job_id`:

```bash
JOB_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  add-job --run "$RUN_ID" \
  --path "<project_path>" --name "<project_name>" --skill "<skill_name>")
```

Keep an ordered list of `(JOB_ID, project_path, project_name, skill_name)`. Log
how many projects were found:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level info --message "Discovered N project(s) defining maintenance-<tag>."
```

If discovery printed nothing (no participating projects), finish the run and
stop here:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  finish-run --run "$RUN_ID" --status completed \
  --summary "No projects define a \`maintenance-<tag>\` skill under the configured search roots."
```

Then report that to the user (with the monitor URL if it was started) and stop.

### 5. Execute (dispatch a subagent per project)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage executing
```

For each job, you (the orchestrator) own the job lifecycle in the DB, and the
subagent does the project work and logs its own progress events.

**Per job, the orchestrator:**

1. Marks the job running before dispatch:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" start-job --job "$JOB_ID"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
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
   bash "<DB_SCRIPT>" log --run <RUN_ID> --job <JOB_ID> --level info --message "<what it's doing>"
   ```
   (using `--level warn`/`error`/`success` as appropriate) so the live view
   updates while it works. The subagent should NOT touch the run row or call
   `finish-run`; the orchestrator owns those.
3. After the subagent returns, write its summary to a temp file and finish the
   job with the right status (`success`, `failure`, or `skipped`):
   ```bash
   SUMMARY_TMP=$(mktemp)
   printf '%s\n' "<subagent's Markdown summary>" > "$SUMMARY_TMP"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
     finish-job --job "$JOB_ID" --status success --summary-file "$SUMMARY_TMP"
   rm -f "$SUMMARY_TMP"
   ```
   On failure pass `--status failure` and `--error "<short reason>"`; if the
   project decided there was nothing to do, `--status skipped`. Log a closing
   event for the job and append the result to your action log.

**Serial (default / `--now`):** dispatch one subagent, wait for it to return,
finish its job, then move to the next — in the deterministic discovery order.

**Parallel (`--fast`):** call `start-job` for the batch, then dispatch multiple
Task subagents **in a single turn** so they run concurrently; finish each job as
its subagent returns. Concurrent DB writes from the subagents are safe by design
(the DB uses WAL mode + `busy_timeout`), so **no extra coordination is needed** —
just give each subagent its own `job_id`.

If a subagent crashes or returns nothing usable, mark that job
`--status failure --error "<reason>"`, log an `error` event, and keep going with
the remaining projects. One project's failure must not abort the others.

### 6. Summarize

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" set-stage --run "$RUN_ID" --stage summarizing
```

Build a Markdown roll-up from your action log: per-project results (success /
failure / skipped with one-line notes), totals, and a "needs attention" section
listing any failures. Write it to a temp file and finish the run; `finish-run`
sets the stage to `done` implicitly:

```bash
RUN_SUMMARY_TMP=$(mktemp)
# ... write the Markdown roll-up to "$RUN_SUMMARY_TMP" ...
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  finish-run --run "$RUN_ID" --status completed --summary-file "$RUN_SUMMARY_TMP"
rm -f "$RUN_SUMMARY_TMP"
```

Use `--status failed` only if the orchestration itself broke (individual project
failures still make a `completed` run — they are reported in the summary).

### 7. Report & observe

Print the roll-up summary to the user, along with the monitor URL (if the app is
running) so they can review live progress and history:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" url   # prints URL if running
```

Tell the user they can:

- stop the app anytime with `maintenance-monitor.sh stop`, and
- start it again later with `maintenance-monitor.sh start` to revisit this run
  and all past runs (the database persists across runs and plugin updates).

## Robustness

- The run is fully recorded to the DB regardless of whether the web app is up,
  so running `--headless` (or with `python3` unavailable) loses no data.
- A monitor that fails to start is a **warning**, never a fatal error — log it
  and proceed (Step 3).
- A single project's failure is recorded on its job and reported in the summary;
  it never aborts the rest of the sweep (Step 5).
