---
name: dependabot-sweep
description: Run a full Dependabot maintenance sweep — unblock stuck PRs, batch-merge ready PRs onto the sweep branch, fix vulnerability alerts, update changelog, open one PR, and merge it once checks are green.
---

# Dependabot Sweep

Run a full Dependabot maintenance sweep for the current repository. This orchestrates the work of the individual dependabot-unblock, dependabot-merge, and dependabot-fix skills into a single pass.

Rather than merging each ready Dependabot PR separately, the sweep **folds the
ready PRs into its own branch**: their dependency bumps, the vulnerability fixes,
and the changelog all ride one PR through CI once and merge once. This eliminates
the per-merge conflict cascade — where merging one PR re-conflicts the rest and
forces repeated rebases and CI waits — that dominated past sweep run times.

## Steps

### 1. Pre-flight checks

Before doing anything:

1. Run `git status --porcelain`. If the working tree is dirty (any output), tell the user to commit or stash their changes and **stop**.
2. Record the current branch name: `git rev-parse --abbrev-ref HEAD`. You will return to this branch at the end.
3. Run `gh auth status` to verify the GitHub CLI is authenticated. If it fails, report the error and **stop**.
4. Check the project's Claude configuration for special dependency management guidance. Look in:
   - `CLAUDE.md` (and any imported files)
   - `.claude/CLAUDE.md`
   - `AGENTS.md`

   Look for guidance on dependency updates, rebasing, merging, Dependabot handling, or remediation of common Dependabot PR failures. Record specifically:

   - **Rebase remediation**: a custom rebase command/script the project uses in place of `@dependabot rebase` (e.g., because Dependabot's built-in rebase is too naive for the project's module layout).
   - **Failure remediation**: guidance describing failure modes that Dependabot PRs commonly hit in this project and a prescribed automatic fix for each — for example, "if tests fail in subproject go.mod files, run script X" or "if a `setup-go` version mismatch shows up in CI, run script Y." A remediation only qualifies as **automatic** if it is a single command/script/comment the project prescribes; open-ended debugging does not count.
   - **Lockfile/install command**: the project's lockfile-regeneration command per ecosystem (e.g. `go mod tidy`, `npm install`, `bundle install`, `pip install`). Record it now; Step 3 uses it to regenerate a lockfile when batch-merging causes a lockfile-only conflict, and Step 4 uses it after each vulnerability fix. If none is documented, fall back to the ecosystem's standard command.

   Record any such guidance; it will override the default behavior in the steps below.
5. Initialize an internal **action log** (an in-memory list). Every action taken in the steps below gets appended here. The log is used for the changelog update and the final summary.

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
- `base` — the PR's target branch (Step 3 cuts the sweep branch from this)
- `ecosystem` — Dependabot package-ecosystem parsed from the branch (`go_modules`, `npm_and_yarn`, `github_actions`, …) or `null` for a non-standard branch
- `mergeable` — merge state: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`
- `checks_pass` — boolean or null; `true` only when every check concluded acceptably — `SUCCESS`, `NEUTRAL`, or intentionally `SKIPPED` (so an `if:`-gated job like "Build Summary" no longer makes a genuinely-ready PR look blocked); `false` when a check actually **failed** or has not finished yet; `null` if check info is unavailable (token lacks `checks:read` permission)
- `review_decision` — review decision (may be empty if no reviews required)
- `url` — PR URL

Categorize every PR into one of four groups:

1. **Conflicting** — `mergeable` is `CONFLICTING`
2. **Failing checks** — `checks_pass` is `false` AND `mergeable` is NOT `CONFLICTING`
3. **Ready to merge** — `mergeable` is `MERGEABLE` AND `checks_pass` is `true`
4. **Checks unknown** — `checks_pass` is `null` AND `mergeable` is `MERGEABLE` (treat as ready to merge with `--auto`, which lets GitHub enforce branch protection rules)

For **every** conflicting PR, request a rebase. If Step 1 found project-specific rebase guidance (e.g., a custom rebase script), follow that guidance instead of the default `@dependabot rebase` comment — invoke the project's script or process for each conflicting PR exactly as the project's configuration prescribes. Otherwise, use the default:

```bash
gh pr comment <number> --body "@dependabot rebase"
```

Log each rebase request (PR number, title, URL, and which method was used).

For PRs in the **failing checks** group, do not perform open-ended investigation. Instead, decide based on the project guidance recorded in Step 1:

1. If Step 1 recorded **failure remediation** guidance, run `gh pr checks <number>` to see what failed and compare against the scenarios the guidance covers. If the failure clearly matches one of the prescribed scenarios, apply the prescribed automatic remediation for each matching PR exactly as the guidance describes (e.g., comment the project's rebase trigger, run the project's script against the PR branch, etc.). Log each remediation (PR number, title, URL, which guidance was applied).
2. If Step 1 also recorded **rebase remediation** guidance and the failure type is plausibly caused by Dependabot's naive rebase (a common case for projects with multi-module layouts, vendored dependencies, or coupled lockfiles), apply the project's rebase remediation to the PR even though it isn't strictly `CONFLICTING`. Log it the same way as conflicting rebases.
3. Otherwise — no matching guidance, or the failure looks like a genuine code/test problem unrelated to dependency mechanics — log the PR as "skipped (failing checks)" and move on. Do **not** check out the branch or attempt ad-hoc fixes during the sweep; that belongs to `dependabot-unblock`.

When this step requires running a local script against a PR branch, do the checkout/script/push for each affected PR before continuing to Step 3, and return to the recorded original branch (Step 1.2) before proceeding. Keep a clean working tree between PRs.

### 3. Batch-merge ready PRs onto the sweep branch

Using the PR data already fetched in Step 2, find all ready-to-merge PRs (the
**Ready to merge** and **Checks unknown** groups). If there are none, log that and
skip to Step 4.

**Do not merge ready PRs one at a time.** Merging interdependent Dependabot PRs
individually is an O(N) trap: each remote merge rewrites a shared lockfile, which
re-conflicts the remaining open PRs and forces a `@dependabot rebase` + full CI
wait before the next can go in. That conflict cascade was the dominant wall-clock
cost of past sweeps. Instead, **combine the ready PRs onto the sweep branch**, so
all their changes land together, run CI once (in Step 7), and merge once (in the
single sweep PR).

The sweep branch can only carry PRs that share a `base`. Ready Dependabot PRs
share one base in normal repos, but if they target more than one (e.g. some target
a release branch via Dependabot's `target-branch` config), batch only the PRs
sharing a single base this run — use the most common base (normally the repository
default branch) and leave PRs targeting other bases for a later run. From here on,
`<base>` is that one shared base, and Steps 4–6 use the **same** `<base>`.

Create the sweep branch from the up-to-date base (this is the **same** branch the
vulnerability fixes and changelog will be committed to in Steps 4–5):

```bash
git fetch origin
git checkout -b chore/dependabot-sweep-YYYY-MM-DD origin/<base>
```

Use today's date. If the branch name is taken, append a counter (`-2`, `-3`, …).

Then, for **each** ready PR on `<base>` (oldest first), fold its head branch in:

```bash
git fetch origin <branch>
git merge --no-edit FETCH_HEAD
```

Handle the result (on a conflict, list the conflicted paths with
`git diff --name-only --diff-filter=U` to classify it):

- **Clean merge** — keep it. Log the PR as batch-merged.
- **Conflict only in generated lockfiles** (every conflicted path is a lockfile —
  `go.sum`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`,
  `poetry.lock`, …) **while the manifest merged cleanly** — resolve by
  regenerating the lockfile: run the project's lockfile/install command for that
  ecosystem (recorded in Step 1), `git add` the regenerated lockfile, and
  `git commit --no-edit` to complete the merge. Log it as batch-merged.
- **Any other conflict** (a manifest conflict, or anything not resolvable by
  regenerating a lockfile) — **punt** it: `git merge --abort`, then leave the PR
  open and move on. A punt is a **silent skip**: do not comment, do not request a
  rebase here, and do **not** file a followup for it. Normal Dependabot conflicts
  are expected; punting and picking them up next sweep is the intended behavior.
  Log it as "punted (conflicting)" for the final summary only.

If **zero** PRs batch-merged cleanly, the branch so far carries no dependency
changes; keep it (Steps 4–5 may still add vulnerability fixes and a changelog).
Step 6 guards against pushing a commit-less branch, so an all-punted sweep with no
vuln fixes ends cleanly rather than erroring on `gh pr create`.

When the sweep PR merges in Step 7, each batched Dependabot PR's dependency
reaches its target version on the base branch, so Dependabot auto-closes the
superseded PRs on its next run. (GitHub's `Closes #<number>` keyword only
auto-closes *issues*, not PRs, so the PR body's `Closes` lines just link the
superseded PRs — the actual close is Dependabot's, not the keyword's.)

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

Use the sweep branch for the fixes. If Step 3 already created the sweep branch
(`chore/dependabot-sweep-YYYY-MM-DD` — whether or not any PR actually batched onto
it), you are already on it; commit the fixes there. Otherwise create it now:

```bash
git fetch origin
git checkout -b chore/dependabot-sweep-YYYY-MM-DD origin/<base>
```

Use today's date. `<base>` is the same shared base from Step 3 (the repository
default branch when Step 3 was skipped). If the branch name is already taken,
append a counter (`-2`, `-3`, etc.) until you find an available name.

For each package, in priority order, up to a maximum of **10** packages:

1. Find the manifest file(s) that declare the dependency (use the `manifest` field as a starting point)
2. Update the dependency to the patched version. If multiple alerts affect the same package, use the highest patched version to resolve all of them
3. Run the project's install/lock command to update the lockfile (e.g., `npm install`, `pip install`, `bundle install`, `go mod tidy`, etc.)
4. **Pin npm versions**: If the ecosystem is npm, verify the version written to `package.json` is an exact pinned version (e.g., `1.2.3`). Remove any range prefix (`^`, `~`) that npm may have added. Re-run `npm install` after correcting the version to keep the lockfile in sync.
5. **Version consistency check**: If the update changes a language or runtime version (e.g., Go directive in `go.mod`, Node.js version in `engines`/`.nvmrc`, a `setup-go`/`setup-node` action version), audit all places that declare that version and update them to match:
   - Project config: `go.mod`, `package.json` `engines`, `.nvmrc`, `.node-version`, `.tool-versions`, `.python-version`
   - CI workflows: `.github/workflows/*.yml` (`setup-go`, `setup-node`, `setup-python`, etc.)
   - Containers: `Dockerfile*` (`FROM` directives)
6. Run the project's test suite if one exists
7. If tests pass: commit with message `fix(deps): update <package> to <version> (resolves N alert(s))` and continue to the next package
8. If tests fail: attempt a trivial fix. If not possible, revert the changes for this package and **stop fixing further packages** — do not proceed to remaining packages
9. Log each fix or skip

### 5. Update changelog

If the action log is empty (nothing was done in Steps 2–4), skip to Step 6.

Search the repo root for a changelog file. Check these names case-insensitively: `CHANGELOG.md`, `CHANGELOG`, `CHANGELOG.rst`, `CHANGELOG.txt`, `CHANGES.md`, `CHANGES`, `CHANGES.rst`, `CHANGES.txt`, `HISTORY.md`, `HISTORY`, `HISTORY.rst`, `HISTORY.txt`, `NEWS.md`, `NEWS`, `NEWS.rst`, `NEWS.txt`.

If no changelog file is found, skip to Step 6.

If you are not already on a sweep branch (i.e., Steps 3 and 4 were both skipped),
create one now:

```bash
git fetch origin
git checkout -b chore/dependabot-sweep-YYYY-MM-DD origin/<base>
```

(Same naming convention and collision handling as Step 4.)

Read the existing changelog to understand its format and style. Add a new entry at the top of the changelog (below any title/header) with a date heading for today. Group entries by category:

- **Merged**: `- Merged Dependabot PR #N: <title>` (the PRs batched into this
  sweep branch in Step 3)
- **Rebased**: `- Requested rebase for Dependabot PR #N: <title>`
- **Fixed**: `- Updated <package> to <version> to resolve N <severity> alert(s)`
- **Skipped**: `- Skipped <package> update (test failures)`

Do not add a changelog line for PRs that were punted as conflicting in Step 3 — a
punt is a silent skip and they remain open.

Only include categories that have entries. Match the existing changelog's formatting conventions (heading levels, date format, bullet style, etc.).

Commit:

```
docs: update changelog for dependabot sweep YYYY-MM-DD
```

### 6. Push and create PR

If you are still on the original branch (no local changes were made, no sweep branch was created), skip to Step 7.

You may be on a sweep branch that ended up **empty** — every ready PR punted in Step 3 and Steps 4–5 added nothing. Check before pushing:

```bash
git rev-list --count origin/<base>..HEAD
```

If the count is `0`, the branch has no commits to push. Delete it, return to the original branch, and skip to Step 7 (there is nothing to merge):

```bash
git checkout <original-branch>
git branch -D chore/dependabot-sweep-YYYY-MM-DD
```

Otherwise push the sweep branch:

```bash
git push -u origin HEAD
```

Create a PR against the same base the branch was cut from:

```bash
gh pr create --base <base> --title "chore(deps): dependabot sweep YYYY-MM-DD" --body "<structured body>"
```

The PR body should list all actions taken, organized by category (rebases requested, PRs batch-merged, vulnerabilities fixed, vulnerabilities skipped, PRs punted as conflicting). Use the action log to populate this. List each batch-merged Dependabot PR as `Closes #<number>` so it is linked to this PR; the superseded PR is closed by Dependabot (which detects the bumped version on `<base>`), not by the keyword — see Step 3.

Record the PR number (capture it from the `gh pr create` output, or read it with `gh pr view <branch> --json number`). You will need it in Step 7.

Report the PR URL to the user.

### 7. Wait for checks and merge the sweep PR

This step runs **only if Step 6 created a PR**. If no PR was created, skip to Step 8.

Wait for the sweep PR's status checks to finish. `gh pr checks --watch` blocks until all checks complete, but can hang if a required check never reports, so put a hard timeout around it. Use `gtimeout` when it is installed, and fall back to plain `gh` when it is not (do **not** let a missing `gtimeout` crash the skill):

```bash
if command -v gtimeout >/dev/null 2>&1; then
  gtimeout 30m gh pr checks <number> --watch
else
  gh pr checks <number> --watch
fi
```

Choose a timeout appropriate for the project's CI (30m is a reasonable default). Note the exit codes:

- `gtimeout` exits **124** if the timeout fires before checks finish — treat this as not-green (case 3 below).
- Otherwise the exit code is whatever `gh pr checks` returned.

In the fallback (no `gtimeout`) path, do not wait indefinitely — if checks have not finished after a reasonable interval, treat the PR as not-green (case 3) and leave it for the developer.

Handle the outcome:

1. **No checks reported** — the PR has no CI / status checks (`gh pr checks` reports "no checks reported on the ..." and exits). There are no tests to wait for; proceed to merge.
2. **All checks pass** — the command exits 0. Proceed to merge.
3. **Checks failed or timed out** — the command exits non-zero (a failing check, or `gtimeout` exit 124). Do **not** merge. Run `gh pr checks <number>` to capture which checks failed or are still pending, log it, and leave the PR open for the developer to address. Skip to Step 8. (Batching trades the old per-PR partial-merge for one CI run: if the combined PR fails, none of the batched bumps land this run. That is the intended cost — the developer can split the failing branch or rerun next sweep; do not fall back to merging the PRs individually.)

To merge (cases 1 and 2), merge the sweep PR with a merge commit and delete its branch:

```bash
gh pr merge <number> --merge --delete-branch
```

Log the merge result. If the merge fails — for example, branch protection requires a human review or additional approvals — log the error and leave the PR open. Do **not** retry with `--admin` or any flag that bypasses branch protection rules or rulesets.

When the sweep PR merges, the Dependabot PRs batched in Step 3 are superseded —
Dependabot auto-closes each one once its dependency reaches the target version on
the base branch. You do not need to close them by hand; if any is still open
shortly after, it is safe to leave (Dependabot will close it on its next run).

Record the outcome of this step (merged, left open due to failing checks, or merge failed) for the final report.

### 8. Return and report

Return to the original branch (a successful merge with `--delete-branch` already
left the sweep branch behind; this is still a safe no-op if so):

```bash
git checkout <original-branch>
```

Print a final summary covering:

- PRs unblocked (rebases requested)
- PRs with failing checks (noted but not investigated)
- PRs batch-merged into the sweep PR
- PRs punted as conflicting (left open for next sweep — a silent skip, no followup)
- Vulnerabilities fixed
- Vulnerabilities skipped (test failures)
- Changelog updated (yes/no)
- PR URL (if one was created)
- **Sweep PR status**: merged, or left open because checks failed (list the failing checks) or the merge could not complete (give the reason) — so the developer knows it still needs attention
- Remaining work (anything that still needs attention)

If **nothing was done at all** across all steps, report: "No Dependabot maintenance needed."
