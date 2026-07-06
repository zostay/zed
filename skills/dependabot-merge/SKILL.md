---
name: dependabot-merge
description: Batch-merge the open Dependabot PRs that are ready (no conflicts, all checks passing) by combining them onto a single branch and merging once, instead of one PR at a time.
---

# Dependabot Merge

Merge the open Dependabot PRs that are ready to merge (no conflicts, all checks
passing). When two or more are ready, **combine them onto a single integration
branch and merge once** rather than merging each PR individually.

## Why batch

Merging interdependent Dependabot PRs one at a time is an O(N) trap: each merge
rewrites a shared lockfile (`go.sum`, `package-lock.json`, …), which re-conflicts
the remaining open PRs and forces a `@dependabot rebase` + full CI wait before the
next one can go in. With N PRs that is N rebase/CI cycles. Combining the ready PRs
onto one branch lands all their changes together, runs CI **once**, and merges
**once**, eliminating the conflict cascade.

A PR that cannot be folded into the batch cleanly is **punted** — a silent skip,
left open for next time. Do not fight a conflict, request a rebase as part of this
skill, or file a followup for it; normal Dependabot conflicts are expected.

## Steps

### 1. Pre-flight checks

1. Run `git status --porcelain`. If the working tree is dirty (any output), tell
   the user to commit or stash their changes and **stop**.
2. Record the current branch name: `git rev-parse --abbrev-ref HEAD`. You will
   return to this branch at the end.
3. Run `gh auth status` to verify the GitHub CLI is authenticated. If it fails,
   report the error and **stop**.
4. Check the project's Claude configuration (`CLAUDE.md` and any imported files,
   `.claude/CLAUDE.md`, `AGENTS.md`) for dependency-management guidance —
   specifically the project's **lockfile/install command** for each ecosystem
   (e.g. `go mod tidy`, `npm install`, `bundle install`, `pip install`). Record
   it; you will use it to regenerate a lockfile when batching causes a
   lockfile-only conflict. If none is documented, fall back to the ecosystem's
   standard command.
5. Detect whether GitHub auto-merge is available on this repo — Steps 4–6 need it
   for any PR whose `checks_pass` is `null`:

   ```bash
   gh api "repos/{owner}/{repo}" --jq '.allow_auto_merge'
   ```

   Record the result. `true` means `gh pr merge --auto` works; `false` means
   auto-merge is **disabled for the repository** and you must use a plain
   `gh pr merge --merge` instead — GitHub rejects `--auto` on such repos with the
   error "Auto-merge is not allowed for this repository." That error is about a
   repository *setting*, not a review or branch-protection policy. (If the command
   fails or returns nothing — e.g. the token cannot read repo settings — treat
   auto-merge as unavailable and use plain merges.)

### 2. Fetch open Dependabot PRs

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-prs.sh"
```

If the script reports no open Dependabot PRs, tell the user and stop. If the
script fails, report the error and stop.

### 3. Filter for merge-ready PRs

Parse the JSONL output. Each line is a JSON object with these fields:

- `number` — PR number
- `title` — PR title
- `branch` — head branch name
- `base` — the PR's target branch (cut the integration branch from this)
- `ecosystem` — Dependabot package-ecosystem parsed from the branch
  (`go_modules`, `npm_and_yarn`, `github_actions`, `pip`, `bundler`, `docker`, …)
  or `null` if the branch is not a standard Dependabot branch
- `mergeable` — merge state: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`
- `checks_pass` — boolean or null; true if all status checks succeeded, false if
  any failed or are still running, null if check info is unavailable (token lacks
  `checks:read` permission)
- `review_decision` — review decision (may be empty if no reviews required)
- `url` — PR URL

A PR is **ready to merge** when both conditions are met:

1. `mergeable` is `MERGEABLE`
2. `checks_pass` is `true` OR `null` (when null and repo auto-merge is available,
   use `--auto` on the eventual merge so GitHub enforces required checks; when
   auto-merge is disabled — see Step 1 — fall back to a plain merge)

Filter the list to only ready-to-merge PRs.

If no PRs are ready to merge, tell the user there are no Dependabot PRs ready to
merge right now (mention how many open PRs there are and why they aren't ready —
conflicts, pending/failing checks, etc.) and stop.

**Group by target branch.** The integration branch can only carry PRs that share
a `base`. Ready Dependabot PRs share one base in normal repos, but if they do not
(e.g. some target a release branch via Dependabot's `target-branch` config),
batch only the PRs sharing a single base this run — process the most common base
(normally the repository default branch) and leave PRs targeting other bases for
a separate run, so no bump lands on the wrong branch. From here on, `<base>` is
that one shared base.

### 4. Choose a path by count

Among the ready PRs that share `<base>`:

- **Exactly one** ready PR — there is nothing to batch. First tell the user which
  PR you are going to merge (number, title, URL, and that it has no conflicts and
  passing/unknown checks), then merge it directly and skip to Step 7:

  ```bash
  # add --auto only if its checks_pass was null AND repo auto-merge is available (Step 1)
  gh pr merge <number> --merge --delete-branch
  ```

- **Two or more** ready PRs — batch them (Step 5). The integration branch
  combines all ready PRs on `<base>` by default. You may instead split the batch
  **per `ecosystem`** — repeat Steps 5–6 once for each ecosystem group, each
  producing its own integration branch/PR — when that better isolates a project's
  CI; but a single combined branch is the default and the bigger wall-clock win
  (one CI run total).

### 5. Build the integration branch

Create the integration branch for `<base>` (the shared base from Step 3) from the
up-to-date base:

```bash
git fetch origin
git checkout -b chore/dependabot-merge-YYYY-MM-DD origin/<base>
```

Use today's date. If the branch name is already taken, append a counter (`-2`,
`-3`, …) until you find an available name.

Then, for **each** ready PR on `<base>` (oldest first — the list is sorted
oldest-first), fold its head branch into the integration branch:

```bash
git fetch origin <branch>
git merge --no-edit FETCH_HEAD
```

Handle the result (on a conflict, list the conflicted paths with
`git diff --name-only --diff-filter=U` to classify it):

- **Clean merge** — keep it. Record the PR as batched and continue.
- **Conflict only in generated lockfiles** (every conflicted path is a lockfile —
  `go.sum`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`,
  `poetry.lock`) **while the manifest merged cleanly** — resolve by regenerating
  the lockfile rather than punting:
  run the project's lock/install command for that ecosystem (from Step 1),
  `git add` the regenerated lockfile, and `git commit --no-edit` to complete the
  merge. Record the PR as batched.
- **Any other conflict** (a manifest conflict, or anything you cannot resolve by
  regenerating a lockfile) — **punt** it:

  ```bash
  git merge --abort
  ```

  Skip the PR silently (leave it open, do not comment, do not request a rebase,
  do not file a followup) and continue with the next PR.

After folding all ready PRs, count how many were batched:

- **Zero batched** (every PR conflicted) — delete the integration branch
  (`git checkout <original-branch>` then `git branch -D <integration-branch>`),
  report that no PRs could be cleanly batched this run, and skip to Step 8.
- **Exactly one batched** — the integration branch adds no value over merging
  that PR directly. Delete it as above, announce the PR to the user, and merge it
  with `gh pr merge <number> --merge --delete-branch` (add `--auto` only if its
  `checks_pass` was null **and** repo auto-merge is available — see Step 1), then
  skip to Step 7.
- **Two or more batched** — continue to Step 6.

### 6. Push, open a PR, wait for checks, and merge

Push the integration branch and open a single PR against `<base>`:

```bash
git push -u origin HEAD
gh pr create --base <base> \
  --title "chore(deps): batch merge N Dependabot PRs (YYYY-MM-DD)" \
  --body "<structured body>"
```

**Record the new PR's number** from the `gh pr create` output (or read it with
`gh pr view --json number --jq .number` while still on the branch) — the
`<number>` in the watch/merge commands below is this integration PR, **not** the
batched Dependabot PR numbers used in Steps 3–5.

The body should list every batched PR as `- Closes #<number>: <title>` (use
`Closes` so the superseded Dependabot PRs are linked; Dependabot also
auto-closes each one once its dependency reaches the target version on `<base>`
after this PR merges). Note any PRs that were punted as conflicting, if any.

Wait for the integration PR's status checks to finish. `gh pr checks --watch`
blocks until checks complete but can hang if a required check never reports, so
put a hard timeout around it. Use `gtimeout` when installed and fall back to plain
`gh` when it is not (do **not** let a missing `gtimeout` crash the skill):

```bash
if command -v gtimeout >/dev/null 2>&1; then
  gtimeout 30m gh pr checks <number> --watch
else
  gh pr checks <number> --watch
fi
```

`gtimeout` exits **124** if the timeout fires before checks finish — treat that as
not-green. Handle the outcome:

1. **No checks reported** — the PR has no CI (`gh pr checks` says so and exits).
   Proceed to merge.
2. **All checks pass** — exits 0. Proceed to merge.
3. **Checks failed or timed out** — exits non-zero (a failing check, or `gtimeout`
   exit 124). Do **not** merge. Run `gh pr checks <number>` to capture what failed
   or is pending, leave the integration PR open for the developer, and skip to
   Step 8.

To merge (cases 1 and 2), merge the integration PR and delete its branch:

```bash
gh pr merge <number> --merge --delete-branch
```

If the merge fails, **quote the actual error message** rather than guessing a
cause — a rejected merge can mean required status checks are still pending, a
required review is missing, or (if you passed `--auto`) auto-merge is disabled on
the repo. Do not report it as a self-merge or human-review requirement unless the
error literally says so. Report the error, leave the PR open, and do **not** retry
with `--admin` or any flag that bypasses protections.

Whether the integration PR merged or was left open, skip to Step 8 — Step 7 covers
only the direct single-PR merge paths.

### 7. (single-PR paths) Confirm the merge

For the direct-merge paths (Step 4 one-PR case, or Step 5 one-batched case),
report the result. If you used `--auto` (checks were unknown and auto-merge is
available), the merge is queued to land once checks pass — say "auto-merge
enabled," not "merged." If the merge fails, **quote the actual error** rather than
inferring a policy (see Step 6); a common cause is passing `--auto` on a repo where
auto-merge is disabled — fall back to a plain
`gh pr merge <number> --merge --delete-branch`. Continue to Step 8. Do **not**
retry with `--admin`.

### 8. Return and report

Return to the original branch (the integration branch, if any, was already deleted
in Steps 5–6):

```bash
git checkout <original-branch>
```

If a left-open integration branch remains (Step 6 case 3, checks failed), leave it
for the developer. Then report:

- Which PRs were merged (directly or via the integration PR), with numbers/titles
  — note any that are auto-merge-queued rather than already merged
- The integration PR URL, if one was created, and whether it merged or was left
  open (and why — failing checks, merge blocked)
- Which PRs were punted as conflicting (so the developer knows they remain open)

If nothing was merged and nothing could be batched, say so plainly.
