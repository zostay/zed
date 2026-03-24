---
name: dependabot-merge
description: Find an open Dependabot PR that is ready to merge and merge it using the repo's default merge method.
---

# Dependabot Merge

Merge the oldest open Dependabot PR that is ready to merge (no conflicts, all checks passing).

## Steps

### 1. Fetch open Dependabot PRs

Run the helper script to retrieve all open Dependabot PRs and their merge readiness:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-prs.sh"
```

If the script reports no open Dependabot PRs, tell the user and stop.

If the script fails, report the error and stop.

### 2. Filter for merge-ready PRs

Parse the JSONL output. Each line is a JSON object with these fields:

- `number` — PR number
- `title` — PR title
- `branch` — head branch name
- `mergeable` — merge state: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`
- `checks_pass` — boolean, true if all status checks succeeded
- `review_decision` — review decision (may be empty if no reviews required)
- `url` — PR URL

A PR is **ready to merge** when both conditions are met:

1. `mergeable` is `MERGEABLE`
2. `checks_pass` is `true`

Filter the list to only ready-to-merge PRs.

If no PRs are ready to merge, tell the user there are no Dependabot PRs ready to merge right now (mention how many open PRs there are and why they aren't ready — conflicts, pending/failing checks, etc.) and stop.

### 3. Select and present the PR

Select the **first** ready PR from the list (PRs are sorted oldest-first, so this merges the longest-waiting PR).

Tell the user which PR you are going to merge, including:

- PR number and title
- PR URL
- That it has no conflicts and all checks are passing

### 4. Merge the PR

Merge the selected PR using the repository's default merge method:

```bash
gh pr merge <number> --auto
```

Report the result to the user. If the merge fails, report the error.
