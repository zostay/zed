# Changelog

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
