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

#### Bootstrap `PATH` before every helper-script call (do not skip this)

The scripts carry a `#!/usr/bin/env bash` shebang. When you run one, the kernel
launches `/usr/bin/env`, which then resolves `bash` **from `PATH`**. In a
sandboxed subshell whose `PATH` omits Homebrew (`/opt/homebrew/bin`), `env`
cannot find `bash` and the script dies before its first line with
`env: bash: No such file or directory` (exit 127) — so the script's own
internal `PATH` self-heal never gets to run, and a captured command
substitution (e.g. `JOB_ID=$(... add-job ...)`) silently yields an **empty
string** with the error buried on stderr. Invoking the script "by its path"
does **not** avoid this: the failure is `env` resolving the *interpreter*, not
the kernel resolving the *script*.

The fix is to ensure a usable `PATH` **in the caller** before the shebang is
evaluated. Prepend this bootstrap to every Bash command **that runs a helper
script** (it is harmless when `PATH` is already fine — it only prepends):

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"
```

So each **helper-script** invocation looks like:

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"; "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-config.sh" ...
export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"; "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" ...
export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"; "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-discover.sh" <tag>
export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"; "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-monitor.sh" ...
export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"; "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" ...
```

Each Bash tool call is a fresh shell, so the export does not persist between
calls — include it in every **helper-script** call. Still invoke scripts **by
their path** (do not prefix with a bare `bash`, which has the same
unresolved-`bash` problem). When you dispatch a subagent (Step 5), **include
this same `PATH` bootstrap instruction in its prompt** so its own script calls
do not hit the identical failure.

#### Never prefix an allowlisted command (run `gh pr merge`/`gh pr close` bare)

The `PATH` bootstrap is **only** for helper-script (`maintenance-*.sh`)
invocations — they need `bash` resolved for their `#!/usr/bin/env bash` shebang.
**Do not** prepend it to any command that has its own allow rule (e.g.
`gh pr merge`, `gh pr close`, other `gh pr …` calls). Run those **bare**.

Why this matters: the `export …; <cmd>` prefix makes the command **compound**,
and Claude Code's permission engine matches a rule against **each subcommand
independently** (it splits on `;`, `&&`, `|`, …). So `export …; gh pr merge …`
no longer matches the allow rule `Bash(gh pr merge:*)` — the un-allowlisted
`export` segment defeats it, the command falls through to the auto-mode
classifier, and under an unattended sweep (`defaultMode: auto`) it is
**auto-denied**. Bare `gh pr merge …` matches the allow rule directly and runs.
This is the confirmed cause of spurious "merge ready PR" followups in past runs.

A `gh` binary launched directly by the Bash tool does **not** hit the
`env: bash` problem (it is not a script with a shebang to resolve), and runs in
a profile-sourced shell that already has a usable `PATH` — so it needs no
bootstrap. Reserve the prefix for helper scripts; everything that has its own
allow rule runs bare. The examples below omit the prefix for brevity — apply it
to helper-script (`maintenance-*.sh`) calls regardless; leave allowlisted
commands bare.

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

Keep an ordered list of `(JOB_ID, project_path, project_name, skill_name,
priority)`. Log how many projects were found:

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

**Before the per-job loop — authorize the whole sweep once, up front.** The model
is "assume elevated permission for the whole run": you authorize **once**, for the
entire sweep, rather than per project. This single grant lets privileged commands
(a project's `make deploy`, a rollout) run unblocked anywhere in the run. Bare
`gh pr merge`/`gh pr close` already match their own allow rules and don't need it,
but ordinary Dependabot sweeps don't run anything privileged at all — so most runs
never exercise the grant. Create it anyway: it's harmless when unused and it's the
one deliberate "yes" that carries any deploy through.

- **Interactive session (you can ask the user a question):** ask **once**, with a
  single AskUserQuestion, whether to authorize this `<tag>` sweep to run privileged
  commands (deploys, rollouts) for the whole run. Default/recommended is
  **authorize**. If the user authorizes, create the whole-sweep grant:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" grant --tag "<tag>"
  ```
  If the user declines, create no grant and continue — `gh`-only work (the common
  Dependabot case) still runs via its own allow rules; only a project that needs an
  un-allowlisted privileged command will be blocked (and you handle that as a
  followup, like any blocked step).

- **Unattended session (a scheduled/cron run with no human to ask):** do **not**
  prompt. Rely on a grant created ahead of time:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" grant --tag "<tag>" --ttl 12h
  ```
  Without it, `gh`-only work still runs; an un-allowlisted privileged command is
  reported as a followup.

Record the grant outcome as a run event so the sweep history reflects what
actually happened — log the elevated case **only when you created a grant**, and
log the un-elevated case otherwise (user declined, or unattended with no
pre-created grant), so the history never claims it ran elevated when it didn't:
```bash
# only if you created/confirmed a whole-sweep grant above:
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level info --message "Sweep authorized for privileged commands (whole-run grant)."
# otherwise (no grant in effect):
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  log --run "$RUN_ID" --level info --message "Sweep not elevated; gh-only work runs, un-allowlisted privileged commands will be reported as followups."
```

The grant is run-scoped: **revoke it when the run finishes** (Step 6) so it cannot
carry over to a later sweep — the generous default TTL is only a backstop if the
run dies before it can revoke (see **Authorization** for that orphan window).

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

   Instruct the subagent to log progress with (note the `PATH` bootstrap — the
   subagent runs in the same kind of stripped subshell and must apply it to
   helper-script calls, see **Bootstrap `PATH`** above):
   ```bash
   export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"; "<DB_SCRIPT>" log --run <RUN_ID> --job <JOB_ID> --level info --message "<what it's doing>"
   ```
   (using `--level warn`/`error`/`success` as appropriate) so the live view
   updates while it works. Tell the subagent to prepend that same `PATH` export
   to its **helper-script** (`maintenance-*.sh`) calls (its project's
   `maintenance-<tag>` work runs helper scripts too) — but to run allowlisted
   commands such as `gh pr merge`/`gh pr close` **bare**, never with the prefix,
   so they match their allow rules instead of being auto-denied (see **Never
   prefix an allowlisted command** above). The subagent should NOT touch the run
   row or call `finish-run`; the orchestrator owns those.
3. After the subagent returns, write its summary to a temp file and finish the
   job with the right status (`success`, `followup`, `failure`, or `skipped`):
   ```bash
   SUMMARY_TMP=$(mktemp)
   # Use `>|` (force-clobber), not `>`: `mktemp` pre-creates the file, and under
   # zsh `noclobber` a plain `>` refuses to overwrite an existing file and writes
   # nothing — silently recording an empty summary. `>|` overwrites regardless.
   printf '%s\n' "<subagent's Markdown summary>" >| "$SUMMARY_TMP"
   "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
     finish-job --job "$JOB_ID" --status success --summary-file "$SUMMARY_TMP"
   rm -f "$SUMMARY_TMP"
   ```
   Choose the status:
   - `success` — the project's maintenance completed cleanly with nothing left
     for a human to do.
   - **`followup`** — the project at least **partially** succeeded but left work
     that needs a human (a manual step, a decision, something to verify). Use this
     for anything you would otherwise put in the run's "needs attention" section.
   - `failure` — the project's maintenance could not be completed; also pass
     `--error "<short reason>"`. A hard failure that a human must chase up should
     **also** get a followup ticket (next sub-step) so it is tracked.
   - `skipped` — there was nothing to do.

   Log a closing event for the job and append the result to your action log.
4. **Open followup tickets for anything needing a human.** For each distinct
   outstanding item this project left behind (i.e. each thing you'd list under
   "needs attention"), open a ticket and capture its number:
   ```bash
   TICKET=$("${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
     add-followup --run "$RUN_ID" --job "$JOB_ID" --project "<project_name>" \
       --title "<one-line what's needed>" [--detail "<more context>"])
   ```
   `add-followup` prints the sequential **ticket number** (and logs a live `warn`
   event so it appears in the activity feed). Keep the ticket numbers in your
   action log — you will list them in the run summary. Open tickets for `followup`
   jobs and for any `failure` job a human must resolve; a clean `success`/`skipped`
   job gets none. (The user later resolves each ticket with
   `/zed:maint-followup <number> done|nope|update`.)

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
followup / failure / skipped with one-line notes), totals, and a **"Needs
attention"** section. That section must list each open followup ticket **by its
number**, e.g.:

```markdown
## Needs attention
- **#7** qubling.cloud — rotate the API token in prod (manual)
- **#8** openscripture.today — confirm the import looks right

Resolve each with `/zed:maint-followup <number> done|nope|update [comment]`.
When the last ticket is closed, this run flips from **Needs Followup** to
**Completed**.
```

Write it to a temp file and finish the run; `finish-run` sets the stage to `done`
implicitly. **Choose the run status from whether any followup tickets are open:**

```bash
RUN_SUMMARY_TMP=$(mktemp)
# Write the Markdown roll-up to "$RUN_SUMMARY_TMP" using `>|` (force-clobber),
# e.g.  printf '%s\n' "$ROLLUP" >| "$RUN_SUMMARY_TMP"  — never a plain `>`, which
# `mktemp` + zsh `noclobber` turns into a silent no-op (empty summary).
# If you opened any followup tickets this run, use needs_followup; else completed.
RUN_STATUS=completed
if [ -n "$("${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" list-followups --run "$RUN_ID" --status open)" ]; then
  RUN_STATUS=needs_followup
fi
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-db.sh" \
  finish-run --run "$RUN_ID" --status "$RUN_STATUS" --summary-file "$RUN_SUMMARY_TMP"
rm -f "$RUN_SUMMARY_TMP"
```

**Revoke the whole-sweep grant** if you created one at the start (Step 5), so the
elevated authorization does not carry into a later sweep. It's harmless if no
grant was created:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" revoke --tag "<tag>" >/dev/null 2>&1 || true
```

Revoke on **every** exit path, not just the clean one: do it even when the run
ends `failed` or the orchestration itself breaks part-way (wrap the rest of the
sweep so this still runs). A grant left behind by an aborted run keeps elevating
Bash in every session until its TTL expires — the orphan window described under
**Authorization**. The TTL is only the backstop for the case the orchestrator
never reaches this line at all (a hard crash / killed session); revoking here is
what keeps that window from ever opening in normal operation.

- Use **`needs_followup`** whenever the run leaves any open followup ticket. The
  run is finished sweeping but awaits human action; it graduates to `completed`
  on its own when the last ticket is resolved (the orchestrator does **not** need
  to revisit it).
- Use **`completed`** when there are no open tickets.
- Use **`failed`** only if the orchestration itself broke (individual project
  failures do not by themselves fail the run — they are reported in the summary,
  and any that need chasing have their own followup tickets).

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

## Authorization

The model is **"assume elevated permission for the whole sweep."** You authorize
**once, up front, for the entire run** — not per privileged project. This is a
deliberate trade-off: less granular containment in exchange for a far simpler,
more robust model. (It replaces the old per-project `requiresAuthorization` gate
and the per-(tag, project) grant + TTL + one-time-consume machinery, which were
fragile — an up-front grant could expire before a long serial sweep reached the
last project, silently skipping it.)

Why authorization is needed at all: most maintenance commands are fine without
it. Bare `gh pr merge`/`gh pr close` match their own allow rules and run in any
session (including an unattended/`dontAsk` sweep). The gap is **arbitrary
privileged commands with no allow rule** — a project's `make deploy` or rollout —
which the auto-accept classifier would otherwise prompt for or auto-deny. A
whole-sweep grant lifts that block for the duration of the run.

The control flow:

1. **The sweep authorizes once, up front (Step 5, before the per-job loop).** In
   an interactive session the orchestrator asks a single yes/no — authorize this
   `<tag>` sweep to run privileged commands for the whole run? (default: yes) —
   and, on yes, creates one whole-sweep grant:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" grant --tag weekly
   ```
2. **Unattended runs use a pre-created grant.** A scheduled/cron sweep has no one
   to ask, so authorize ahead of time:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/maintenance-authorize.sh" grant --tag weekly --ttl 12h
   ```
   Grants live under `<data-dir>/grants/`, one per tag (`sweep__<tag>.json`).
   `list`/`revoke` inspect and rescind.
3. **A `PreToolUse` hook (`hooks/maintenance-authz.sh`, registered in
   `hooks/hooks.json`) makes the privileged commands actually run.** While **any**
   valid whole-sweep grant exists it returns `permissionDecision: allow` for Bash
   calls, so an un-allowlisted privileged command runs without the auto-accept
   classifier prompting or denying it. With no grant it stays silent and defers to
   normal permission handling. The hook **never denies** — it only lifts the block
   when a grant exists — so it cannot break ordinary commands.
4. **The run revokes its grant when it finishes (Step 6).** Authorization is
   run-scoped, so it cannot carry into a later sweep; the generous default TTL is
   only a backstop if the run dies before revoking.

No per-project gate runs any more: every discovered project is dispatched to a
subagent regardless (there is nothing to skip for lack of a grant). If the user
declines authorization, the sweep still runs — only an un-allowlisted privileged
command will block, and you record that as a followup like any other blocked step.

**Subagent hook-firing caveat.** The hook reliably fires for top-level tool calls;
whether it fires inside a dispatched subagent depends on the Claude Code version.
Bare `gh pr merge`/`gh pr close` are unaffected (they match allow rules directly,
no hook needed), so ordinary Dependabot work runs fine in subagents. Only a
project that runs an **un-allowlisted privileged command** (e.g. `make deploy`)
depends on the hook firing where that command runs. If you find such a command
still blocked inside its subagent, run that one project **inline in the
orchestrator session** (the orchestrator `cd`s into `project_path` and invokes the
`maintenance-<tag>` skill itself, logging to the same `job_id`) so the hook
applies; ordinary jobs still go to subagents.

**Blast radius and the orphan window (know the trade-off).** A valid grant is
deliberately broad: while it exists the hook allows **any** Bash command in **any**
session on the machine — not just the sweep's own — and it matches a grant under
**any** tag, not only the running sweep's. That is the "less granular containment"
the model accepts in exchange for simplicity. Two consequences to keep bounded:

- **Orphan after an aborted run.** The run revokes its grant when it finishes
  (Step 6), including on the `failed` path — that is the primary control, and it
  keeps the window closed in normal operation. The TTL only matters if the
  orchestrator never reaches that revoke at all (a hard crash / killed session);
  then the grant lingers — and silently elevates later sessions — until it
  expires (default 12h). The default is intentionally long so a grant can't expire
  *mid-sweep* (the original run-#6 failure); if you want a tighter orphan bound on
  an unattended schedule, pass a smaller `--ttl` that still comfortably outlasts
  your slowest run. If a sweep ever ends abnormally, `maintenance-authorize.sh
  list` shows any lingering grant and `revoke --tag <tag>` clears it.
- **Cross-tag / concurrent grants.** Because the hook matches any tag, a still-valid
  grant from a *different* tag keeps elevating during an unrelated run, and a run's
  `revoke --tag <tag>` only clears its own tag — use `list`/`revoke` to clean a
  stray one. Do **not** run two sweeps of the *same* tag concurrently: they share
  one grant file, so whichever finishes first revokes it and de-authorizes the
  other mid-run.

## Followups

A sweep rarely leaves everything in a finished state — some projects partially
succeed but need a human to finish the job (a manual deploy step, a decision, a
verification). Rather than burying these in prose, the run records them as
numbered **followup tickets** and surfaces a distinct status for them.

Statuses involved (all already understood by the DB and the observability app):

- **Job status `followup`** — sits between `success` and `failure`: the project
  at least partially succeeded but needs human attention. Set it in Step 5.
- **Run status `needs_followup`** ("Needs Followup" in the app) — the run is done
  sweeping but has at least one open ticket. Set it in Step 6.
- A ticket's own lifecycle is `open → done | wontdo`.

How it flows:

1. As the orchestrator finishes each job (Step 5), it sets `followup` status for
   partial successes and opens one `add-followup` ticket per outstanding item
   (also for failures a human must chase). `add-followup` assigns the sequential
   ticket number and logs a live event.
2. At summary time (Step 6) the run is finished `needs_followup` if any ticket is
   open, and the **Needs attention** section lists the tickets by number.
3. The user resolves each ticket from any session with
   `/zed:maint-followup <number> done|nope|update [comment]` (the **maint-followup**
   skill). `update` comments without closing; `done` closes it completed; `nope`
   closes it as won't-do. Each call appends to the ticket's comment timeline.
4. When the **last** open ticket of a `needs_followup` run is closed, the DB flips
   that run to `completed` automatically — the app shows the status change live.
   The orchestrator never has to revisit a finished run to do this.

Inspect tickets directly with `maintenance-db.sh list-followups [--run R]
[--status open]` and `maintenance-db.sh get-followup --id N`.

## Robustness

- The run is fully recorded to the DB regardless of whether the web app is up,
  so running `--headless` (or with `python3` unavailable) loses no data.
- A monitor that fails to start is a **warning**, never a fatal error — log it
  and proceed (Step 3).
- A single project's failure is recorded on its job and reported in the summary;
  it never aborts the rest of the sweep (Step 5).
