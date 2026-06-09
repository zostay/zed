# Changelog

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
