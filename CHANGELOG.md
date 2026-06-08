# Changelog

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
