---
name: dependabot-unblock
description: Unblock stuck Dependabot PRs by requesting rebases for conflicts and investigating failing checks.
---

# Dependabot Unblock

Unblock stuck Dependabot PRs. For merge conflicts, request a rebase from Dependabot. For failing checks, investigate and attempt a trivial fix.

## Steps

### 0. Check for project-specific dependency management guidance

Before taking any action, check the project's Claude configuration for special dependency management requirements or scripts. Look in:

- `CLAUDE.md` (and any imported files)
- `.claude/CLAUDE.md`
- `AGENTS.md`

Look for guidance on dependency updates, rebasing, merging, or Dependabot handling — for example, a project may provide a custom rebase script because Dependabot's built-in rebase is too naive. If such guidance exists, follow it in place of the default behavior in the steps below (e.g., use the project's rebase script instead of `@dependabot rebase`).

### 1. Fetch open Dependabot PRs

Run the helper script to retrieve all open Dependabot PRs and their merge readiness:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-prs.sh"
```

If the script reports no open Dependabot PRs, tell the user and stop.

If the script fails, report the error and stop.

### 2. Identify blocked PRs

Parse the JSONL output. Each line is a JSON object with these fields:

- `number` — PR number
- `title` — PR title
- `branch` — head branch name
- `mergeable` — merge state: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`
- `checks_pass` — boolean or null; true if all status checks succeeded, false if any failed, null if check info is unavailable (token lacks `checks:read` permission)
- `review_decision` — review decision (may be empty if no reviews required)
- `url` — PR URL

Categorize PRs into three groups:

1. **Conflicting** — `mergeable` is `CONFLICTING`
2. **Failing checks** — `checks_pass` is `false` AND `mergeable` is NOT `CONFLICTING` (to avoid double-handling)
3. **Checks unknown** — `checks_pass` is `null`; note these in the summary but do not investigate (check status cannot be determined)

If no PRs are in either group, tell the user there are no blocked Dependabot PRs and stop.

### 3. Handle conflicting PRs

For **every** PR in the "conflicting" group, comment on the PR to request a rebase:

```bash
gh pr comment <number> --body "@dependabot rebase"
```

Report each one to the user (number, title, URL, that a rebase was requested).

### 4. Handle first PR with failing checks

Select the **first** (oldest) PR from the "failing checks" group. Only handle one per invocation.

1. Report the PR to the user (number, title, URL)
2. Run `gh pr checks <number>` to see which checks are failing
3. Check out the PR branch: `git checkout <branch>`
4. Investigate the failures — look at CI output, run tests locally if possible
5. **Check for version inconsistencies**: If the PR bumps a language or runtime version (e.g., `actions/setup-go`, Go module directive, Node.js version), check whether the version is declared in multiple places and only updated in one. Look across project config (`go.mod`, `package.json` `engines`, `.nvmrc`, `.node-version`, `.tool-versions`, `.python-version`), CI workflows (`.github/workflows/*.yml`), and Dockerfiles (`FROM` directives). Mismatches are a common cause of check failures on version-bump PRs — fix all locations to use the same version.
6. If a trivial fix is apparent (e.g., a minor code adjustment, linting fix, type error, version mismatch), implement it, commit, and push to the PR branch
7. If no trivial fix is possible, report findings to the user and stop — do not attempt complex fixes

### 5. Report summary

Summarize all actions taken:

- Which conflicting PRs had rebases requested
- What was found for the failing-checks PR (fixed or not, and what was observed)
- Any PRs that remain blocked
