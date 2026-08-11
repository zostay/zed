# Changelog

## 0.12.0 — 2026-08-10

### Added

- `maintenance`, `maint-followup`, `maint-followup-do`: **issues a run files are
  now surfaced, not just narrated.** 0.11.0 taught the skills to file a GitHub
  issue rather than a followup ticket for incidental findings — but the only
  trace of a filed issue was a line of prose in a job summary, so the operator
  had no durable signal that the run had created work for them.
  - `project_issues` gains an **`origin`** column (`triage` | `created`).
    Anything the run files itself is recorded with `--origin created` the moment
    `gh issue create` returns.
  - **This is not weekly-gated.** Triage remains a `weekly`-only nudge about work
    that was already there; a filed issue is work the run just created, on
    whatever tag it ran under. A `dependabot` sweep that files one issue now
    shows it in the debrief, where previously it showed nothing at all.
  - The observability app renders them in a dedicated **FILED BY THIS RUN**
    board at the top of the GitHub section, and badges every one of them
    **NEW** — in that board and wherever else they appear, including inside the
    per-project groups. The section title switches to `GITHUB ISSUES FILED` when
    a run filed issues but triaged nothing.
  - Run-filed rows sort **ahead of** triaged rows in both `list-project-issues`
    and the app, so a `--limit`ed roll-up can never drop them in favour of
    pre-existing backlog.
  - Step 6 gains an **Issues filed by this run** summary section (any tag), and
    the Top 10 table now passes `--origin triage` so the two don't restate each
    other.
  - `maint-followup` and `maint-followup-do` record what they file against the
    ticket's own run, so an issue that came out of working a followup shows up
    on that run's page instead of only in the session transcript.
  - `add-project-issue` / `add-project-issues` take `--origin`; the batch form
    also reads a per-item `origin` key (per-item wins). `list-project-issues`
    takes `--origin` to filter.
  - `init` gained a retrofit step: `CREATE TABLE IF NOT EXISTS` cannot add a
    column to a table that already exists, so an idempotent guarded
    `ALTER TABLE` backfills `origin` on databases created by 0.11.0. Existing
    rows adopt `triage`, which is what they were.

### Fixed

- `maintenance` observability app: the GitHub section's boards were hidden but
  never emptied, so selecting a run with no triage after one that had it left
  the previous run's rows parked in the DOM. Every board is now cleared when it
  is hidden.
- `app/server.py` tolerates a `project_issues` table that predates the `origin`
  column, retrying without the origin ordering term instead of returning an
  empty list.

## 0.11.0 — 2026-08-05

### Added

- `maintenance`: **weekly GitHub triage.** A run tagged exactly `weekly` now ends
  each project with one cursory pass over that repo's open issues and PRs —
  listing them, dropping Dependabot/deploy noise and anything the run itself just
  created, ranking what's left, and keeping the top five. It never resolves,
  merges, comments on, or checks out anything; the whole point is to remind you
  what work is pending for *you*.
  - New `project_issues` table (`scripts/schema.sql`) holding a per-run,
    immutable snapshot, plus `add-project-issue`, `add-project-issues` (batch
    JSONL/JSON-array) and `list-project-issues` in `maintenance-db.sh`.
  - `server.py` serves `project_issues` and `top_issues` (the top 10 across all
    projects) on `/api/runs/:id` and over SSE; both degrade to `[]` against a
    database created before the table existed.
  - The observability app gains a **GITHUB TRIAGE** section on the debrief face:
    a ranked top-10 board across every project plus per-project groups, each row
    a generous link that opens the item on GitHub in a new tab. Rank drives a
    four-tier rail, age is colored by staleness, and issues and PRs carry
    distinct glyphs. Only `https://` URLs are ever turned into links.
  - Step 6 repeats the top 10 as a Markdown table in the run summary.
  - Gated on the tag being **exactly** `weekly`: any other tag writes no rows,
    and the app hides the section outright. A project with no GitHub remote is
    an `info` event and a skip; any triage failure is a `warn` and never changes
    a job's status.

### Changed

- `maintenance`, `maint-followup`, `maint-followup-do`: **followup tickets are
  now deliberately scarce.** Run #11 opened ten tickets where roughly one was
  warranted, so Step 5 now runs a three-way disposition — **punt → GitHub issue
  → ticket** — with the real run #11 tickets quoted as worked examples:
  - **Punt** anything next week's routine picks up on its own, unless it is
    urgent (harm accrues first) or blocks the sweep from functioning.
  - **File a GitHub issue** for anything describing a bug, misconfiguration, or
    failure in the project or its tooling — it outlives the run, a ticket
    doesn't.
  - **Open a ticket** only for work that needs you personally before the next
    run: a decision without which the sweep cannot function, a credential step,
    a deploy you must approve. Tie-breakers: torn between ticket and issue, file
    the issue; torn between ticket and punt, punt.
  - `maint-followup` and `maint-followup-do` are now **forbidden from filing
    followups at all** — the regression that produced tickets #63–#65. New
    findings go to `gh issue create` (searching first to avoid duplicates) or
    directly to you, with a comment on the worked ticket recording where the
    finding went. Only a `/zed:maintenance` sweep may open a ticket.
  - A job is `followup` only when it left a ticket; punted work and filed issues
    are ordinary `success` output described in the job summary prose.

- `maintenance` observability app: the debrief followups table is now **one row
  per ticket, at most two lines tall**. The detail sub-line is gone from the
  front page and the title / latest-update cells clamp with the full text in a
  tooltip; the ticket number deep-links to the followups page, where the full
  detail and complete comment timeline still live untouched.

### Fixed

- `maintenance-db.sh`: a batch `add-project-issues` whose rows all failed to
  *write* (a mis-threaded `--job`, an unwritable database) exited 0 and looked
  like success. Validation rejects are still skipped non-fatally, but a database
  write failure now exits non-zero with a count.
- `maintenance-db.sh`: a malformed pretty-printed JSON **array** fell through to
  the line-oriented JSONL path and silently recorded a fraction of its elements.
  It now fails loudly with jq's parse error and records nothing.
- `maintenance-db.sh`: `--rank` outside 0..100 was rejected instead of clamped.
- `maint-followup`: could file a GitHub issue against whatever repository the
  session happened to be sitting in; it now checks the repo matches the ticket's
  project first, as `maint-followup-do` already did.

## 0.10.0 — 2026-08-03

### Added

- `maintenance` observability app: **status-driven focus/debrief redesign.** The
  run view is now one container with two faces that switch automatically on
  `run.status`, so the agent's current work stays top-of-fold while a run is live
  and followups float to the top once the sweep is done.
  - **Live Focus** (`status=running`): viewport-pinned with no page scroll — slim
    header plus inline stage rail, a one-line progress bar, a NOW hero for the
    running project (spinner, live elapsed, latest activity), a dense QUEUE chip
    grid, a full-height ACTIVITY log, and followups collapsed to a quiet one-line
    strip that opens the followups page.
  - **Debrief** (`needs_followup`/`completed`/`failed`/`cancelled`): the order
    inverts so followups float to the top — stoplight board (lamps light when
    non-zero), promoted followups table, run summary, per-project results triaged
    worst-first with the clean majority folded, activity log demoted.
  - **Followups page**: hash-routed `#/run/:id/followups` (plus a
    `/followup/:fid` deep link with one-shot auto-scroll) showing full comment
    timelines, rendered from data already in `/api/runs/:id` — no new endpoint.
  - The running→done transition animates live over SSE with a
    stoplight/followups reveal, guarded by `prefers-reduced-motion`.

  Frontend-only: `app/static/{index.html,styles.css,app.js}`. `server.py` is
  untouched — every field both faces need was already served. Existing
  constraints kept: Python 3 stdlib server, vanilla JS, no pip/npm/CDN/build.

### Fixed

- `maintenance` observability app: the shared HTML escaper now encodes quotes
  (`"` and `'`), closing an attribute-context XSS breakout at the many
  `esc()`-into-attribute call sites (chip `title`, `data-*` attributes).

## 0.9.0 — 2026-07-14

### Added

- `maint-followup-do`: a new skill that **works** a maintenance followup ticket,
  rather than just recording a decision about it. Given a ticket number, it loads
  the ticket (`get-followup`), confirms the current repository is the ticket's
  project (and stops if not — it never switches projects), investigates what the
  ticket actually needs against the live repo, then **either completes the work in
  this session** — verifying the change — **or produces a concrete path forward**
  when it can't. It records progress on the ticket automatically (`update`) and
  asks before any `done`/`nope` that would close the ticket. It is the worker
  counterpart to `maint-followup` (the recorder) and reuses the same
  `maintenance-db.sh update-followup` mechanism.

## 0.8.1 — 2026-07-06

### Fixed

- `dependabot-merge` / `dependabot-sweep`: **don't blindly reach for `gh pr merge
  --auto`, and don't hallucinate a review policy when a merge is rejected.** On a
  repo with `allow_auto_merge: false`, GitHub rejects `gh pr merge --auto` with
  "Auto-merge is not allowed for this repository." Agents were pattern-matching
  that error — and the skills' old "for example, branch protection requires a human
  review" phrasing — into a fabricated diagnosis ("the author can't self-merge, a
  human must review") when the real cause was just a disabled repo *setting*. Right
  outcome (leave the PR open) but wrong, misleading diagnosis.
  - `dependabot-merge` now detects `allow_auto_merge` in pre-flight (Step 1) and
    gates every `--auto` on it: when auto-merge is disabled it falls back to a plain
    `gh pr merge --merge`. The null-`checks_pass` merge paths (Steps 4–5) and the
    ready-PR filter (Step 3) reference that gate.
  - `dependabot-sweep` never actually ran `--auto` (it folds PRs onto the sweep
    branch and plain-merges the sweep PR), but its "Checks unknown" categorization
    and Step 7 failure note were the source of the misleading `--auto` intent and
    the "human must review" example. Both are corrected.
  - Both skills' merge-failure guidance now says to **quote the actual error** and
    not infer a self-merge / human-review policy unless the error literally says so.

## 0.8.0 — 2026-06-29

### Changed

- `maintenance`: **assume elevated permission for the whole sweep.** Authorization
  is now granted **once, up front, for the entire run** instead of per privileged
  project. This retires the per-project `requiresAuthorization` opt-in gate and the
  per-(tag, project) grant + TTL + one-time-consume machinery, which were fragile:
  on a long serial sweep an up-front grant could expire before the run reached the
  last privileged project, silently skipping it (run #6). A deliberate trade-off —
  less granular containment for a far simpler, more robust model.
  - `maintenance-authorize.sh` now manages a **single whole-sweep grant per tag**
    (`sweep__<tag>.json`). Subcommands reduced to `grant`/`check`/`revoke`/`list`/
    `path`; `consume`, `--repeat`, `--one-time`, and `--project` are gone. The
    default TTL is now 12h (a backstop — the run revokes its grant on completion),
    so it comfortably outlasts a long serial sweep.
  - The `PreToolUse` hook (`maintenance-authz.sh`) now lifts the permission block
    for Bash calls while **any** valid whole-sweep grant exists, rather than keying
    on the cwd project basename + a per-project grant. It still never denies.
  - The orchestrator no longer runs a per-job authorization gate or skips projects
    for lack of a grant: every discovered project is dispatched. It asks **once**
    up front (interactive; default authorize), creates the whole-sweep grant, and
    **revokes it when the run finishes**. Unattended runs pre-create the grant with
    `maintenance-authorize.sh grant --tag <tag>`.
  - Why most runs are unaffected: bare `gh pr merge`/`gh pr close` match their own
    allow rules and run without the grant. The grant exists only for the remaining
    case — an **un-allowlisted privileged command** like a project's `make deploy`.
  - `maintenance-discover.sh` no longer reads or emits `requiresAuthorization` /
    `requires_authorization`; the discovery JSONL drops that field.
  - **On-disk format change (breaking).** Grant files moved from the per-(tag,
    project) `<tag>__<project>.json` to a single per-tag `sweep__<tag>.json`.
    Pre-0.8 grant files are simply ignored — they no longer authorize anything,
    and `list`/`revoke` no longer surface them. If you have leftover ones, delete
    `<data-dir>/grants/*__*.json` (the old format) by hand; nothing reads them now.
  - Constraint preserved: no elevation via `--admin`, branch-protection bypass, or
    dangerous allow-globs.

## 0.7.0 — 2026-06-28

### Changed

- `dependabot-merge` and `dependabot-sweep`: stop merging Dependabot PRs one at a
  time. Merging interdependent PRs individually re-conflicts every remaining open
  PR after each merge, forcing a `@dependabot rebase` + full CI wait per PR — an
  O(N) conflict/rebase/CI cascade that dominated sweep wall-clock in multi-module
  repos (gobert, arrest-go) and blew authorization-grant TTLs mid-run.
  - `dependabot-merge` now **combines all ready PRs onto a single integration
    branch** and merges once: one CI run, one merge. A lone ready PR still merges
    directly; a PR that conflicts when folded in is **punted** (silent skip, left
    open) rather than fought. Lockfile-only conflicts are resolved by regenerating
    the lockfile, not punted.
  - `dependabot-sweep` **folds the ready PRs into its own sweep branch**, so the
    batched dependency bumps, the vulnerability fixes, and the changelog all ride
    the single sweep PR through CI once and merge once. The old per-merge re-fetch
    cascade in Step 3 is gone. Superseded Dependabot PRs auto-close when the sweep
    PR merges.
- `scripts/dependabot-prs.sh`: emit two new fields per PR — `base` (the target
  branch to cut the integration branch from) and `ecosystem` (the Dependabot
  package-ecosystem parsed from the branch name, e.g. `go_modules`,
  `npm_and_yarn`), so a caller can group and batch ready PRs. (zostay/zed#16)

## 0.6.3 — 2026-06-24

### Fixed

- `maintenance`: stop wrapping allowlisted commands in a compound `export PATH …;`
  prefix. Claude Code matches permission rules against each subcommand of a
  compound command independently, so `export …; gh pr merge …` failed to match
  `Bash(gh pr merge:*)`, fell through to the auto-mode classifier, and was
  auto-denied under unattended sweeps — producing spurious "merge ready PR"
  followups. The `PATH` bootstrap is now scoped to helper-script
  (`maintenance-*.sh`) invocations only (which need it to resolve their
  `#!/usr/bin/env bash` shebang); `gh pr merge`/`gh pr close` and other
  allowlisted commands run **bare** so they match their allow rules. Updated the
  "Bootstrap `PATH`" section and the Step 5 subagent-dispatch instructions
  accordingly. (#15)

## 0.6.2 — 2026-06-17

### Changed

- `pr-review-fix`: strengthened the guidance that a review must always be
  established before fixing. When a PR has no existing feedback and no pending
  Copilot review, generating one (codex → copilot CLI → Claude subagent) is now an
  explicit, non-skippable invariant rather than soft "last resort" framing. Added a
  hard invariant at the top of Step 3, made the 3b "no feedback" branch a required
  action (not a stopping point), reworded 3c from "fallback" to "the review," and
  surfaced the promise in the skill `description`. Fixes the skill stopping with
  "no review found" instead of producing one.

## 0.6.1 — 2026-06-12

### Fixed

- Plugin load no longer errors with "Duplicate hooks file detected". The manifest
  (`.claude-plugin/plugin.json`) declared `"hooks": "./hooks/hooks.json"`, but the
  standard `hooks/hooks.json` is loaded automatically — naming it again in the
  manifest loaded it twice. Removed the redundant `hooks` key; the `PreToolUse`
  authorization hook still loads via the standard path. (`manifest.hooks` should
  only reference *additional* hook files, not the standard one.)

## 0.6.0 — 2026-06-12

### Changed

- `maintenance`: authorizing privileged (`requiresAuthorization: true`) projects
  is now **interactive and automatic** instead of a manual pre-step. When the
  sweep reaches the execute stage it collects the privileged projects and, in an
  interactive session, asks **once** up front to confirm them (default: authorize
  all), then creates the grants itself before dispatching. A typed
  `/zed:maintenance weekly` now needs a single answer and then runs everything —
  deploys included — to completion; you no longer run
  `maintenance-authorize.sh grant …` by hand for each project before every sweep.
  Declining a project simply skips it. **Unattended** (scheduled/cron) runs, which
  have no one to ask, still authorize ahead of time with an explicit grant — a
  `--repeat` grant is convenient for a recurring schedule. The per-job gate, the
  one-time-grant consume-on-success, and the `PreToolUse` allow hook (what lets
  privileged commands run under auto-accept without prompting or being denied) are
  all unchanged underneath; only the user-facing step moved from a buried pre-run
  command to a single in-session prompt.

## 0.5.0 — 2026-06-09

### Added

- `pr-review-fix` now establishes a review *before* it starts fixing, instead of
  assuming one already exists. It inventories the PR's reviews, inline comments,
  top-level comments, and timeline, then sources feedback in priority order:
  - **Use existing feedback** when any actionable feedback is already present — a
    Copilot review or inline comments, unresolved human review comments, or a
    top-level comment from anyone other than the current user.
  - **Watch for a pending Copilot review** — detected from the PR **timeline**
    (`copilot_work_started` / a `review_requested` naming Copilot), not from
    `reviewRequests` (which GitHub clears the moment the bot starts working, so an
    in-flight review would otherwise read as "no Copilot"). Poll for a Copilot
    review summary *or* inline comments (~30s between checks, bounded to ~15
    minutes by a wall-clock deadline, each network call wrapped in `gtimeout` when
    available) and use the review when it lands. On timeout the skill asks the
    user whether to wait longer, generate a review, or proceed without one — it
    never loops indefinitely.
  - **Generate a review as a last resort** — only when no Copilot review is
    requested/pending/present and no other feedback exists. The review runs from
    a fresh context based solely on the code changes and the PR description (which
    the reviewer discovers itself), preferring an independent model: the **codex**
    CLI, then the **copilot** CLI, then a **Claude Code subagent**. The result is
    posted as a PR comment and carried forward into the fix phase.

### Changed

- `pr-review-fix`: a generated review is evaluated as discrete findings split out
  of its prose body, and the report now names the review source. The
  skip-self-authored-comments rule gains an exception so the freshly generated
  review (authored by the current `gh` user) is still acted upon.

## 0.4.1 — 2026-06-08

### Fixed

- `maintenance`: corrected the `PATH`/shebang guidance that broke a sweep
  outright. The helper scripts carry a `#!/usr/bin/env bash` shebang, so in a
  sandboxed subshell whose `PATH` omits Homebrew, `env` cannot resolve `bash`
  and the script dies with `env: bash: No such file or directory` **before** its
  own in-body `PATH` self-heal can run — silently yielding empty captured output
  (e.g. an empty `JOB_ID`). The previous "invoke by path" mitigation did not
  address this (the failure is `env` resolving the *interpreter*, not the kernel
  resolving the *script*). The SKILL.md now prescribes prepending a `PATH`
  bootstrap (`export PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"`) to every
  helper-script call and passing the same instruction into each dispatched
  subagent. `dependabot-prs.sh` and `dependabot-alerts.sh` gained the same
  in-body `PATH` append the `maintenance-*` scripts already had
- `maintenance`: the SKILL.md summary-file examples now use `>|` (force-clobber)
  instead of `>`. `mktemp` pre-creates the file, so under zsh `noclobber` a plain
  `>` refused to overwrite it and silently wrote an **empty** summary
- `maintenance-db.sh`: `finish-job` and `finish-run` now warn to stderr when a
  `--summary-file` is empty or whitespace-only (recording it anyway), surfacing
  the noclobber-empty-summary bug above immediately instead of after the fact
- `dependabot-sweep`: `checks_pass` no longer reports false negatives on skipped
  jobs. The check evaluation in `dependabot-prs.sh` previously required every
  check to be `status == "COMPLETED"` with conclusion `SUCCESS`/`NEUTRAL`, so an
  intentionally **skipped** job (e.g. an `if:`-gated "Build Summary") made a
  genuinely-ready PR look blocked — and a passing `StatusContext` (which has no
  `status` field) was misread the same way. It now passes only when every check
  concluded acceptably (`SUCCESS`/`NEUTRAL`/`SKIPPED`), normalizing across
  CheckRun (`.conclusion`) and StatusContext (`.state`) nodes; a real failure or
  a not-yet-finished check still keeps the PR out of "ready"
- `maintenance-discover.sh`: discovery now dedupes by git `origin` remote. When
  two local checkouts map to the same remote, only the first (in priority/path
  order) is emitted and a warning is printed for the other, so the sweep no
  longer runs two redundant, racing passes against the same GitHub repo.
  Projects with no remote are unaffected

## 0.4.0 — 2026-06-08

### Added

- `maintenance` now honors a per-project execution order. A project's
  `maintenance-<tag>` skill can declare an integer `priority` in its front
  matter — lower runs earlier, higher runs later, default `0`, ties broken by
  path. `maintenance-discover.sh` reads it, sorts discovery output by
  `(priority, project_path)`, and includes `priority` in each JSONL record. The
  serial path (default / `--now`) runs projects strictly in that order; the
  parallel path (`--fast`) runs them in **priority groups** — all projects at a
  given priority run concurrently as one batch, and each group completes before
  the next-higher group begins. Use a negative priority for a project that needs
  up-front user interaction, and a positive one for a project that redeploys
  centrally-shared apps after earlier projects update them
- `maintenance` can now gate privileged tasks (e.g. production deployments)
  behind an explicit, out-of-band authorization grant so they run during an
  unattended/auto-accept sweep without silently running every time. A project
  opts in with `requiresAuthorization: true` in its `maintenance-<tag>` front
  matter (surfaced by `maintenance-discover.sh` as `requires_authorization`).
  New `scripts/maintenance-authorize.sh` manages time-boxed, one-time grants
  (`grant`/`check`/`consume`/`revoke`/`list`), stored under `<data-dir>/grants/`.
  The orchestrator checks for a valid grant before dispatching such a project —
  skipping and reporting it (with the command to authorize) when absent, and
  consuming the grant on success — so the gate holds even where plugin hooks do
  not reach subagent tool calls. A new `PreToolUse` hook
  (`hooks/maintenance-authz.sh`, registered in `hooks/hooks.json`) is
  defense-in-depth: it returns an `allow` decision for a granted project so the
  privileged command runs without a prompt in an auto-accept/`dontAsk` session,
  and never denies (it only lifts the block when authorization is present)

## 0.3.1 — 2026-06-08

### Fixed

- Observability app: a run whose followups were all resolved (status
  `completed`) still showed **followup** health in the Runs sidebar, because the
  sidebar ranked the lingering followup job count above the run's terminal
  status. The sidebar now reads **OK** once a run completes, matching the
  in-page status. Failures on a still-open `needs_followup` run continue to
  outrank followup.

## 0.3.0 — 2026-06-08

### Added

- `maintenance` now tracks work that needs a human as numbered **followup
  tickets**, with a new job status `followup` (between `success` and `failure`)
  and a run status `needs_followup` ("Needs Followup"). A project that partially
  succeeds is finished `followup` and the orchestrator opens one ticket per
  outstanding item; the run finishes `needs_followup` while any ticket is open.
  The observability app shows the new statuses and a followups ticket table, and
  streams ticket changes live. A new **`maint-followup`** skill
  (`/zed:maint-followup <ticket-number> <update|done|nope> [comment]`) records
  progress on a ticket — `update` comments, `done` closes it completed, `nope`
  closes it won't-do, and an omitted comment is summarized from session context.
  Closing the last open ticket of a run flips it from `needs_followup` to
  `completed` automatically. New `maintenance-db.sh` subcommands back this:
  `add-followup`, `update-followup`, `list-followups`, `get-followup`, plus
  `followups`/`followup_comments` tables in the schema

### Fixed

- Observability app: the status-counts strip was pinned to six columns, so the
  new `followup` dial pushed `skipped` onto a lonely second row. It now lays out
  all seven status dials on one row, with cells that shrink gracefully and labels
  that never wrap.

### Changed

- Observability app: bumped the type size across the whole UI (~17%, base
  16.5px) for legibility. All `font-size`s now route through a `--fs-*` type
  scale in `:root`, so the whole interface can be resized from one place.

## 0.2.1 — 2026-06-08

### Changed

- `dependabot-sweep` now waits for its sweep PR's checks to pass and merges the
  PR automatically (new Step 7). It watches checks with `gh pr checks --watch`
  under a `gtimeout` hard timeout (falling back to plain `gh` when `gtimeout`
  is absent), merges with `--merge` when checks pass or none are reported, and
  leaves the PR open and reported when checks fail or time out — never
  bypassing branch protection

### Fixed

- Maintenance scripts (`maintenance-{db,config,discover,monitor}.sh`) now
  self-heal `PATH` by appending the standard tool dirs (including Homebrew) so
  `dirname`/`sqlite3`/`jq`/`find`/`python3` resolve under a minimal
  environment. The `maintenance` orchestrator now invokes the scripts directly
  via their shebang instead of prefixing a bare `bash`, so job registration no
  longer fails when Homebrew's bash is off `PATH`

## 0.2.0 — 2026-06-01

### Added

- `maintenance` skill — run a maintenance task across all configured projects in
  one pass. Discovers every project that defines a `maintenance-<tag>` skill,
  dispatches a subagent per project to run it (serial by default and with
  `--now`; parallel with `--fast`), and records the whole sweep to a local
  SQLite database. Supports `--headless` to skip the web app
- `maintenance-config.sh` — manages `config.json` (search roots + blocklist) used
  to locate participating projects
- `maintenance-discover.sh` — discovers projects defining a `maintenance-<tag>`
  skill under the configured search roots, applying the blocklist, and emits JSONL
- `maintenance-db.sh` — observability writer CLI that records runs, per-project
  jobs, and events to a WAL-mode SQLite database (`schema.sql`) for safe
  concurrent writes from parallel subagents
- `maintenance-monitor.sh` — lifecycle controller (start/stop/status/url/restart)
  for the observability web app
- `maintenance-common.sh` — shared library resolving the persistent data dir and
  common helpers, sourced by the other maintenance scripts
- Observability web app (`app/server.py` + `app/static/`) — a single-file
  Python 3 standard-library HTTP/SSE server and vanilla-JS UI that renders runs,
  a per-run stage stepper, live per-project job status (pending / running /
  success / failure / skipped) with red/green health indicators, and rendered
  Markdown summaries. Reads the database read-only; no `pip`, npm, or build step.
  Requires `python3` and `sqlite3`

## 0.1.9 — 2026-05-13

### Added

- `send-context` skill — summarize the current Claude Code session's context
  (goal, current state, decisions, open questions, pointers) and write it to a
  Markdown handoff file in the current folder or a named destination
- `recv-context` skill — read a context handoff file written by `send-context`
  from the current folder or a named source, absorb it into the current
  session, and delete the file (unless `--keep` is passed) so the handoff is
  consumed once

## 0.1.8 — 2026-05-11

### Changed

- `dependabot-sweep` no longer blindly skips PRs with failing checks. It now
  consults project-recorded failure-remediation and rebase-remediation guidance
  and applies the prescribed automatic fix when the failure matches a covered
  scenario (e.g., multi-module go.mod test failures resolved by the project's
  rebase script). Failures with no matching guidance are still skipped — the
  sweep does not perform open-ended debugging

## 0.1.7 — 2026-05-11

### Changed

- `dependabot-sweep` now checks the project's Claude configuration
  (`CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`) for dependency management
  guidance during pre-flight and applies it when requesting rebases, so
  projects requiring a custom rebase script are no longer skipped

## 0.1.6 — 2026-04-20

### Changed

- `dependabot-unblock` now checks the project's Claude configuration
  (`CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`) for dependency management
  guidance before acting, so projects can override defaults (e.g., provide a
  custom rebase script when Dependabot's built-in rebase is too naive)

## 0.1.5 — 2026-04-06

### Changed

- `pr-review-fix` now commits the applied fixes to the PR branch and pushes
  them, instead of leaving the changes uncommitted

## 0.1.4 — 2026-04-06

### Added

- `pr-review-fix` skill — check out a PR, read its GitHub review comments,
  evaluate each for validity, apply the warranted fixes, and report

## 0.1.3 — 2026-03-24

### Added

- npm version pinning: dependabot-fix and dependabot-sweep now strip `^`/`~`
  prefixes from `package.json` versions to ensure exact pinned versions
- Language/runtime version consistency checks: dependabot-fix, dependabot-sweep,
  and dependabot-unblock now audit `go.mod`, CI workflows, Dockerfiles, and
  other config files to keep language versions in sync after a bump

## 0.1.2 — 2026-03-24

### Changed

- Merge commands now use `--merge` instead of `--auto` for non-interactive use
- Merge skills will never bypass branch protection rules or rulesets (no
  `--admin` or similar overrides)

## 0.1.1 — 2026-03-24

### Fixed

- Fixed `dependabot-prs.sh` failing silently when token lacks `checks:read`
  permission — the script now falls back to fetching without `statusCheckRollup`
  and sets `checks_pass` to `null`
- Replaced N+1 API calls (`gh pr list` + `gh pr view` per PR) with a single
  `gh pr list` call for better performance
- Added `--limit 100` to handle repos with many Dependabot PRs
- `dependabot-sweep` now re-fetches PR data after each merge to detect PRs that
  became conflicting and requests rebases for them

## 0.1.0 — 2026-03-24

Initial release.

### Added

- `dependabot-fix` skill — fix the highest-priority Dependabot vulnerability alert
- `dependabot-merge` skill — merge the oldest ready Dependabot PR
- `dependabot-unblock` skill — request rebases for conflicting PRs and investigate failing checks
- `dependabot-sweep` skill — full maintenance sweep orchestrating all three skills
- `dependabot-prs.sh` helper script — fetch open Dependabot PRs with merge readiness info
- `dependabot-alerts.sh` helper script — fetch open Dependabot vulnerability alerts
