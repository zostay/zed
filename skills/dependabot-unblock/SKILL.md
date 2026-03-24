---
name: dependabot-unblock
description: Unblock stuck Dependabot PRs by requesting rebases for conflicts and investigating failing checks.
---

# Dependabot Unblock

Unblock stuck Dependabot PRs. For merge conflicts, request a rebase from Dependabot. For failing checks, investigate and attempt a trivial fix.

## Steps

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
- `checks_pass` — boolean, true if all status checks succeeded
- `review_decision` — review decision (may be empty if no reviews required)
- `url` — PR URL

Categorize PRs into two groups:

1. **Conflicting** — `mergeable` is `CONFLICTING`
2. **Failing checks** — `checks_pass` is `false` AND `mergeable` is NOT `CONFLICTING` (to avoid double-handling)

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
5. If a trivial fix is apparent (e.g., a minor code adjustment, linting fix, type error), implement it, commit, and push to the PR branch
6. If no trivial fix is possible, report findings to the user and stop — do not attempt complex fixes

### 5. Report summary

Summarize all actions taken:

- Which conflicting PRs had rebases requested
- What was found for the failing-checks PR (fixed or not, and what was observed)
- Any PRs that remain blocked
