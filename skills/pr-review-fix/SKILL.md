---
name: pr-review-fix
description: Check out a PR, read its GitHub review comments, evaluate each for validity, fix the good recommendations, and report on what was done. If the PR has no review and none is pending, always generate one (codex, copilot CLI, or a Claude subagent) and post it before fixing.
---

# PR Review Fix

Address reviewer feedback on a pull request: check out the right branch, read the review comments, judge each one, apply the fixes that are warranted, and report.

## Steps

### 1. Identify the PR

If the user named a PR (number or URL), use that. Otherwise determine the PR for the current branch:

```bash
gh pr view --json number,headRefName,headRepositoryOwner,headRepository,baseRefName,state,title,url
```

If no PR is associated with the current branch and the user did not name one, stop and tell the user.

### 2. Check out the PR

Before switching branches, run `git status` to confirm the working tree is clean. If there are uncommitted changes to unrelated files, stop and ask the user how to proceed (do not stash or discard without confirmation).

If the PR is not already checked out, check it out:

```bash
gh pr checkout <number>
```

Then pull the latest commits for that branch so review comments line up with current code:

```bash
git pull --ff-only
```

### 3. Establish the review

**Invariant — this skill never proceeds without a review to act on.** Every run of
this skill must end with Steps 4–8 operating on a concrete review. There are
exactly three ways to obtain one, and one of them *always* applies:

1. **Use existing feedback** if any exists.
2. Otherwise **watch for a pending Copilot review** if one is requested/in-progress.
3. Otherwise **generate one yourself** — this is mandatory, not optional.

You may **never** stop, skip ahead, or report "no review found" because a PR has
no feedback yet. "No existing review and nothing pending" is not a dead end — it is
the explicit trigger to generate a review in 3c. Do **not** ask the user whether to
generate one in this case; just generate it. The only place a question is allowed
is the ~15-minute watch timeout in 3b-watch.

Before fixing anything, make sure the PR actually has a review to act on. The
skill sources feedback in the priority order above.

#### 3a. Inventory the current review state

Gather every feedback surface, plus the PR **timeline** — the timeline is the
reliable signal for a Copilot review that is *requested or in progress*:

```bash
me=$(gh api user --jq .login)

# Reviews, inline review comments, and top-level issue comments
gh pr view <number> --json reviews
gh api "repos/{owner}/{repo}/pulls/<number>/comments" --paginate
gh api "repos/{owner}/{repo}/issues/<number>/comments" --paginate

# Timeline — needed to detect an in-flight Copilot review (see below)
gh api "repos/{owner}/{repo}/issues/<number>/timeline" --paginate
```

Match Copilot case-insensitively with `test("copilot")` on **every** surface —
its login differs per surface: `Copilot` in the timeline `review_requested` /
`reviewed` events, but `copilot-pull-request-reviewer` as a review or comment
author.

**Has Copilot already posted?** Check both a review summary *and* inline review
comments — Copilot often posts inline comments only:

```bash
gh pr view <number> --json reviews \
  --jq '[.reviews[] | select(.author.login | ascii_downcase | test("copilot"))] | length'
gh api "repos/{owner}/{repo}/pulls/<number>/comments" \
  --jq '[.[] | select(.user.login | ascii_downcase | test("copilot"))] | length'
```

**Is a Copilot review requested or in progress but not yet posted?** Do **not**
rely on `reviewRequests` from `gh pr view`: GitHub drops a bot reviewer from that
list the moment it *starts* working, so an actively-running Copilot review shows
an **empty** `reviewRequests` (this is the trap that makes naive detection report
"no Copilot" and wrongly fall through to generating a review). Read the timeline
instead — a `copilot_work_started` event, or a `review_requested` event naming
Copilot, means a Copilot review is on its way:

```bash
gh api "repos/{owner}/{repo}/issues/<number>/timeline" --paginate --jq '
  [ .[]
    | select(
        .event == "copilot_work_started"
        or (.event == "review_requested"
            and ((.requested_reviewer.login // "") | ascii_downcase | test("copilot")))
      )
  ] | length'
```

From this, determine:

- **Does any actionable feedback already exist?** — a Copilot review or Copilot
  inline comments; unresolved inline review comments from any human; **or any
  top-level issue comment from someone other than the current user** (`$me`).
  Steps 4–5 act on all three, so all three count as existing feedback here.
- **Is a Copilot review pending?** — the timeline shows it requested/in-progress
  (above) **and** Copilot has not yet posted a review or inline comments.

#### 3b. Decide how to source the review

Exactly one of these three branches applies — pick the first that matches and act:

- **Actionable feedback already exists** → proceed straight to Step 4 and use it.
- **A Copilot review is pending** (requested/in-progress, nothing posted yet) →
  **watch** for it (3b-watch below).
- **No Copilot pending/present and no other feedback** → you have reached the
  generate trigger. **Go to 3c now and generate a review.** This branch is not
  optional and is not a stopping point: do **not** end the skill here, do **not**
  ask the user whether to generate, and do **not** request Copilot. Generating the
  review yourself is the required action.

**3b-watch — wait for a pending Copilot review.** Poll until Copilot posts
**either a review summary or inline review comments** (checking reviews alone
misses an inline-only review). Sleep ~30s between checks, bounded to ~15 minutes
of wall-clock total. Track the elapsed time in the loop itself so the bound holds
even if a single call hangs, and wrap each network call in `gtimeout` when
available as an extra guard — falling back to bare `gh` when it is absent (never
let a missing `gtimeout` crash the skill):

```bash
deadline=$(( $(date +%s) + 15*60 ))
run() { if command -v gtimeout >/dev/null 2>&1; then gtimeout 30 "$@"; else "$@"; fi; }
while [ "$(date +%s)" -lt "$deadline" ]; do
  reviews=$(run gh pr view <number> --json reviews \
    --jq '[.reviews[] | select(.author.login | ascii_downcase | test("copilot"))] | length')
  inline=$(run gh api "repos/{owner}/{repo}/pulls/<number>/comments" \
    --jq '[.[] | select(.user.login | ascii_downcase | test("copilot"))] | length')
  if [ "${reviews:-0}" -gt 0 ] || [ "${inline:-0}" -gt 0 ]; then break; fi
  sleep 30
done
```

Stop the moment Copilot posts, then proceed to Step 4. If the ~15-minute bound
elapses with nothing from Copilot, **ask the user** how to proceed — wait longer,
generate a review now (3c), or proceed without one. Do **not** loop indefinitely.

#### 3c. Generate the review

You are here because no review exists and none is pending. **Generating a review
now is required** — produce one and post it; never finish the skill without it.

Run the review from a **fresh context** that bases its judgment **solely on the
code changes and the PR's own description, which it discovers itself**. Prefer a
**different agent/model system** over Claude when one is available — codex and the
copilot CLI are independent models and give a genuine second opinion; the Claude
subagent is the always-available fallback so that this step can never fail to
produce a review. Select the first available tool:

1. `command -v codex` → run codex non-interactively: `codex exec "<review-prompt>"`,
   capturing stdout.
2. else `command -v copilot` → run the copilot CLI in non-interactive/print mode
   (confirm the exact flag with `copilot --help`; representative form
   `copilot -p "<review-prompt>"`), capturing stdout.
3. else → dispatch a **Claude Code subagent** (Task/Agent tool, `general-purpose`)
   in a fresh context that performs the review and returns the review text.

Give every path the **same review prompt**, instructing the reviewer to discover
its inputs on its own and review based **only** on them:

- The code changes — `gh pr diff <number>` (or `git diff <baseRef>...HEAD`).
- The PR's claims — `gh pr view <number> --json title,body`.

Ask for concrete, file/line-anchored findings on correctness, security, clarity,
and consistency — not praise. The codex/copilot CLIs run in the checked-out repo
cwd, so they already have the diff locally; tell the Claude subagent the PR
number and repo so it can fetch both itself.

**Post the generated review as a PR comment**, with a short header naming the
tool that produced it:

```bash
tmp=$(mktemp)
printf '## Automated review (%s)\n\n%s\n' "<tool>" "<review-text>" >| "$tmp"
gh pr comment <number> --body-file "$tmp"
rm -f "$tmp"
```

**Hold the generated review text in this session** and carry it forward into
Step 5. Step 4 skips comments authored by the current `gh` user, and the review
you just posted *is* authored by that user — so it will not be re-fetched and
must be passed forward explicitly. Record which tool produced it for the report.

### 4. Fetch review comments

Retrieve both review-level summaries and inline review comments:

```bash
# Inline review comments (file/line-anchored)
gh api "repos/{owner}/{repo}/pulls/<number>/comments" --paginate

# Review summaries (approve/request-changes/comment bodies)
gh api "repos/{owner}/{repo}/pulls/<number>/reviews" --paginate
```

Also check top-level issue comments on the PR, since reviewers sometimes leave feedback there:

```bash
gh api "repos/{owner}/{repo}/issues/<number>/comments" --paginate
```

For each inline comment capture: author, file path, line, the diff hunk, the comment body, the comment id, whether it is part of a resolved thread, and any in_reply_to chain. Group replies into threads.

Skip comments authored by the current user (`gh api user`) and skip threads that are already marked resolved/outdated unless the user asks otherwise. **Exception:** if Step 3 generated a review, treat its findings as input here even though that comment is authored by the current user.

### 5. Evaluate each comment

For every unresolved comment thread, read the referenced file at the cited lines to see the current code (it may have changed since the comment was written). Then judge the comment on:

- **Still applicable?** Does the code the comment refers to still exist in that form?
- **Correct?** Is the reviewer's claim actually true given the surrounding code and project conventions?
- **Useful?** Would acting on it improve correctness, security, clarity, or consistency — versus being purely stylistic noise, out of scope, or a matter of taste the author already decided?
- **Actionable here?** Can it be fixed in this PR, or is it follow-up work?

Classify each thread as one of: `fix`, `reject` (with reason), `already-addressed`, `out-of-scope`, or `needs-user-input` (ambiguous / requires a judgment call the user should make).

A review generated in Step 3 arrives as a single prose body rather than threaded inline comments. Split it into discrete findings and evaluate each one against the same criteria.

### 6. Apply the fixes

For each thread classified `fix`, make the change. Group related fixes into coherent edits rather than touching the same file repeatedly. After edits:

- Run the project's formatter/linter and test suite if they exist
- If a fix breaks tests, investigate the root cause before moving on
- Do not expand scope beyond what the comment asked for

### 7. Commit and push the fixes

If any fixes were applied, commit them to the PR branch and push:

- Stage only the files you changed (do not use `git add -A`)
- Write a commit message that summarizes the reviewer feedback being addressed
- Push to the PR's branch with `git push`

Do **not** reply to or resolve the review comments on GitHub automatically — leave that to the user unless they explicitly ask.

### 8. Report

Print a concise report covering:

- The review source: existing Copilot review, a Copilot review that was watched for, or a review generated by `<tool>` (codex / copilot CLI / Claude subagent)
- The PR (number, title, url) and the branch checked out
- A table or list of every comment thread evaluated, with: author, location (`file:line`), classification, and a one-line rationale
- For `fix` items, what was changed (file paths + brief description)
- For `needs-user-input` items, the specific question the user needs to answer
- Any test/lint results
- Suggested next steps (e.g., review the diff, commit, push, reply to reviewers)
