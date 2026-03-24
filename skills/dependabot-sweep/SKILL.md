---
name: dependabot-sweep
description: Run a full Dependabot maintenance sweep — unblock stuck PRs, merge ready PRs, fix vulnerability alerts, update changelog, and open a PR.
---

# Dependabot Sweep

Run a full Dependabot maintenance sweep for the current repository. This orchestrates the work of the individual dependabot-unblock, dependabot-merge, and dependabot-fix skills into a single pass.

## Steps

### 1. Pre-flight checks

Before doing anything:

1. Run `git status --porcelain`. If the working tree is dirty (any output), tell the user to commit or stash their changes and **stop**.
2. Record the current branch name: `git rev-parse --abbrev-ref HEAD`. You will return to this branch at the end.
3. Run `gh auth status` to verify the GitHub CLI is authenticated. If it fails, report the error and **stop**.
4. Initialize an internal **action log** (an in-memory list). Every action taken in the steps below gets appended here. The log is used for the changelog update and the final summary.

### 2. Unblock stuck PRs (remote-only)

Fetch open Dependabot PRs:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-prs.sh"
```

If the script reports no open PRs or fails, log the outcome and skip to Step 4.

Parse the JSONL output. Each line is a JSON object with these fields:

- `number` — PR number
- `title` — PR title
- `branch` — head branch name
- `mergeable` — merge state: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`
- `checks_pass` — boolean or null; true if all status checks succeeded, false if any failed, null if check info is unavailable (token lacks `checks:read` permission)
- `review_decision` — review decision (may be empty if no reviews required)
- `url` — PR URL

Categorize every PR into one of four groups:

1. **Conflicting** — `mergeable` is `CONFLICTING`
2. **Failing checks** — `checks_pass` is `false` AND `mergeable` is NOT `CONFLICTING`
3. **Ready to merge** — `mergeable` is `MERGEABLE` AND `checks_pass` is `true`
4. **Checks unknown** — `checks_pass` is `null` AND `mergeable` is `MERGEABLE` (treat as ready to merge with `--auto`, which lets GitHub enforce branch protection rules)

For **every** conflicting PR, request a rebase:

```bash
gh pr comment <number> --body "@dependabot rebase"
```

Log each rebase request (PR number, title, URL).

Do **not** investigate failing-checks PRs — that requires checking out branches and open-ended investigation that conflicts with the fix phase. Note them in the log as "skipped (failing checks)" for the summary.

### 3. Merge ready PRs (remote-only)

Using the PR data already fetched in Step 2, find all ready-to-merge PRs.

For **every** ready PR, oldest first:

```bash
gh pr merge <number> --merge
```

Log each merge attempt and its result. If an individual merge fails, log the error and continue with the next PR. Do **not** retry with `--admin` or any other flag that bypasses branch protection rules or rulesets.

**Important:** After each successful merge, re-fetch PR data before attempting the next merge:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-prs.sh"
```

A merge can cause other PRs to become conflicting. After re-fetching:

- If a PR you were about to merge is now `CONFLICTING`, request a rebase instead (`gh pr comment <number> --body "@dependabot rebase"`) and log it as rebased, not merged.
- If new conflicts appeared on PRs that were already handled in Step 2, skip them (they were already rebased).
- Continue merging remaining ready PRs from the updated data.

### 4. Fix vulnerability alerts (local changes)

Fetch open Dependabot alerts:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-alerts.sh"
```

If the script reports no open alerts or fails, log the outcome and skip to Step 5.

Parse the JSONL output. Each line is a JSON object with these fields:

- `number` — alert number
- `package` — vulnerable package name
- `ecosystem` — package ecosystem (npm, pip, maven, etc.)
- `manifest` — path to the manifest file
- `severity` — severity tier: `critical`, `high`, `medium`, or `low`
- `cvss` — CVSS score (0–10, higher is worse)
- `summary` — advisory summary
- `ghsa_id` — GitHub Security Advisory ID
- `patched_version` — first patched version, if known

Group alerts by **package name**. For each package, record:

- The number of open alerts affecting it
- Its highest severity tier
- Its highest CVSS score

Rank packages using these criteria in order:

1. **Highest severity tier** (critical > high > medium > low)
2. **Highest CVSS score** within that tier
3. **Most alerts resolved** by fixing that package

Create a new branch for the fixes:

```bash
git checkout -b chore/dependabot-sweep-YYYY-MM-DD
```

Use today's date. If the branch name is already taken, append a counter (`-2`, `-3`, etc.) until you find an available name.

For each package, in priority order, up to a maximum of **10** packages:

1. Find the manifest file(s) that declare the dependency (use the `manifest` field as a starting point)
2. Update the dependency to the patched version. If multiple alerts affect the same package, use the highest patched version to resolve all of them
3. Run the project's install/lock command to update the lockfile (e.g., `npm install`, `pip install`, `bundle install`, `go mod tidy`, etc.)
4. Run the project's test suite if one exists
5. If tests pass: commit with message `fix(deps): update <package> to <version> (resolves N alert(s))` and continue to the next package
6. If tests fail: attempt a trivial fix. If not possible, revert the changes for this package and **stop fixing further packages** — do not proceed to remaining packages
7. Log each fix or skip

### 5. Update changelog

If the action log is empty (nothing was done in Steps 2–4), skip to Step 6.

Search the repo root for a changelog file. Check these names case-insensitively: `CHANGELOG.md`, `CHANGELOG`, `CHANGELOG.rst`, `CHANGELOG.txt`, `CHANGES.md`, `CHANGES`, `CHANGES.rst`, `CHANGES.txt`, `HISTORY.md`, `HISTORY`, `HISTORY.rst`, `HISTORY.txt`, `NEWS.md`, `NEWS`, `NEWS.rst`, `NEWS.txt`.

If no changelog file is found, skip to Step 6.

If you are not already on a sweep branch (i.e., Step 4 was skipped), create one now:

```bash
git checkout -b chore/dependabot-sweep-YYYY-MM-DD
```

(Same naming convention and collision handling as Step 4.)

Read the existing changelog to understand its format and style. Add a new entry at the top of the changelog (below any title/header) with a date heading for today. Group entries by category:

- **Merged**: `- Merged Dependabot PR #N: <title>`
- **Rebased**: `- Requested rebase for Dependabot PR #N: <title>`
- **Fixed**: `- Updated <package> to <version> to resolve N <severity> alert(s)`
- **Skipped**: `- Skipped <package> update (test failures)`

Only include categories that have entries. Match the existing changelog's formatting conventions (heading levels, date format, bullet style, etc.).

Commit:

```
docs: update changelog for dependabot sweep YYYY-MM-DD
```

### 6. Push and create PR

If you are still on the original branch (no local changes were made, no sweep branch was created), skip to Step 7.

Push the sweep branch:

```bash
git push -u origin HEAD
```

Create a PR:

```bash
gh pr create --title "chore(deps): dependabot sweep YYYY-MM-DD" --body "<structured body>"
```

The PR body should list all actions taken, organized by category (rebases requested, PRs merged, vulnerabilities fixed, vulnerabilities skipped). Use the action log to populate this.

Report the PR URL to the user.

### 7. Return and report

Return to the original branch:

```bash
git checkout <original-branch>
```

Print a final summary covering:

- PRs unblocked (rebases requested)
- PRs with failing checks (noted but not investigated)
- PRs merged
- Vulnerabilities fixed
- Vulnerabilities skipped (test failures)
- Changelog updated (yes/no)
- PR URL (if one was created)
- Remaining work (anything that still needs attention)

If **nothing was done at all** across all steps, report: "No Dependabot maintenance needed."
