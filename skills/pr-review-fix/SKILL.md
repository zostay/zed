---
name: pr-review-fix
description: Check out a PR, gather every review on it — human and automated — evaluate each finding for validity, fix the good ones, then reply to and resolve the threads on GitHub. If no current automated review exists, always generate one locally (copilot CLI, codex CLI, or Claude's code-review skill) and post it before fixing.
---

# PR Review Fix

Address reviewer feedback on a pull request: check out the right branch, gather
every review the PR has, judge each finding, apply the fixes that are warranted,
answer and resolve the threads on GitHub, and report — leaving open only the
things a human actually has to decide.

## Two standing requirements

Every run of this skill satisfies both of these. They are independent:

1. **Every review on the PR is evaluated** — not just reviews from agents. A
   human reviewer's comments go through the same evaluation and get the same
   fixes as an agent's.
2. **The PR has a current automated review.** A human review does *not* remove
   this requirement — humans and review agents miss different things. If no
   current automated review exists, you generate one (Step 3c) and post it.

This skill does **not** request or wait for a GitHub-hosted review agent.
Automated reviews are run **locally** — the `copilot` CLI is the primary path.
If the timeline happens to show a hosted review in flight, note it in the report,
but do not block on it.

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

### 3. Establish the reviews

**Invariant — this skill never proceeds without a review to act on.** Steps 4–9
always operate on a concrete set of findings. "The PR has no feedback yet" is not
a stopping point: it is the trigger to generate a review in 3c. Do not ask the
user whether to generate one; just generate it.

#### 3a. Inventory every review surface

One GraphQL query gets the reviews, the inline threads, their resolution state,
and — critically — whether each author is a **human or a bot**:

```bash
gh api graphql -F owner=<owner> -F repo=<repo> -F number=<number> -f query='
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      headRefOid
      commits(last:1) { nodes { commit { committedDate } } }
      reviews(first:50) {
        nodes { author { login __typename } state body submittedAt }
      }
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated path line
          comments(first:50) {
            nodes { databaseId author { login __typename } body diffHunk createdAt }
          }
        }
      }
    }
  }
}'
```

Top-level comments are not in `reviewThreads`, so fetch them too — reviewers
often leave feedback there:

```bash
gh api "repos/{owner}/{repo}/issues/<number>/comments" --paginate
me=$(gh api user --jq .login)
```

**Classify every author as `agent` or `human`.** The distinction drives Step 8,
so make it explicitly for each finding:

- **agent** — GraphQL `__typename` is `Bot`; or the login ends in `[bot]`; or the
  login matches a known review agent case-insensitively (`copilot`,
  `coderabbit`, `sonar`, `codex`, `github-actions`); or the comment is one this
  skill posted itself, recognisable by its `## Automated review (<tool>)` header.
- **human** — everything else.

Note that a bot's login differs per surface — Copilot appears as `Copilot` in
timeline events but `copilot-pull-request-reviewer` as a review or comment
author — so match case-insensitively on substrings rather than exact logins.

Skip comments authored by `$me`, **except** an `## Automated review (<tool>)`
comment, which is an agent finding regardless of who posted it.

#### 3b. Decide whether to generate an automated review

An automated review counts as **current** when an agent-authored review, agent
inline thread, or `## Automated review` comment exists **and** was posted at or
after the newest commit on the branch (`commits.nodes[0].commit.committedDate`
from 3a). An automated review that predates the latest push was written against
code that no longer exists — regenerate.

- **A current automated review exists** → go to Step 4 and evaluate everything
  found in 3a, human and agent alike.
- **No current automated review** → go to 3c. This applies *even when human
  review comments are present*: a human review never satisfies requirement 2.

#### 3c. Generate the automated review

Run the review from a **fresh context** that bases its judgment solely on the code
changes and the PR's own description, which it discovers itself. Prefer a model
system other than Claude when one is available — an independent model gives a
genuine second opinion. Select the first available tool:

1. **`command -v copilot`** → the GitHub Copilot CLI, run non-interactively.
   `--allow-all-tools` is required for non-interactive mode; the review prompt
   tells it to read and report only, never to edit:

   ```bash
   out=$(mktemp)
   copilot -p "<review-prompt>" \
     --allow-all-tools --no-color --log-level none >| "$out"
   ```

   Confirm the flags with `copilot --help` if the invocation errors — the CLI
   changes. Add `-C <repo-path>` if the cwd is not the checkout. This spends the
   operator's own Copilot quota, so run it once per review, not per finding.

2. **else `command -v codex`** → `codex exec "<review-prompt>"`, capturing stdout.

3. **else** → fall back to **Claude's `code-review` skill** (invoke the skill with
   the PR number as its target). This is the last resort because it is not an
   independent model, but it must never be skipped — the invariant holds. If that
   skill is unavailable, dispatch a `general-purpose` Claude Code subagent in a
   fresh context that performs the review and returns the review text.

Give every path the **same review prompt**, instructing the reviewer to discover
its inputs itself and review based only on them:

- The code changes — `gh pr diff <number>` (or `git diff <baseRef>...HEAD`).
- The PR's claims — `gh pr view <number> --json title,body`.

Ask for concrete, file/line-anchored findings on correctness, security, clarity,
and consistency — not praise. The copilot and codex CLIs run in the checked-out
repo cwd and already have the diff locally; tell a Claude subagent the PR number
and repo so it can fetch both itself.

**Post the generated review to the PR** — always, including when it came from the
`code-review` fallback. The ticket is the record of what was reviewed, and a
review that exists only in this session is invisible to everyone else:

```bash
tmp=$(mktemp)
printf '## Automated review (%s)\n\n%s\n' "<tool>" "<review-text>" >| "$tmp"
gh pr comment <number> --body-file "$tmp"
rm -f "$tmp"
```

**Triage a generated review yourself.** Its findings are agent findings: split
them into discrete items, evaluate each in Step 5, and fix the ones you judge
important. Do not hand the raw output to the user and ask which to act on.

**Hold the generated review text in this session** and carry it into Step 4 —
Step 4 skips comments authored by `$me`, and the review you just posted is
authored by `$me`. Record which tool produced it for the report.

### 4. Assemble the findings

Build one list of findings from every surface, and tag each with its provenance
(`agent` or `human`) from 3a. Sources:

- **Inline review threads** (from the 3a GraphQL query) — capture the thread node
  `id`, the `databaseId` of the thread's *first* comment (needed to reply), the
  author, `path:line`, the diff hunk, the body, and `isResolved` / `isOutdated`.
- **Review summaries** — the `reviews` nodes with a non-empty `body`.
- **Top-level issue comments** from anyone other than `$me`.
- **The review generated in Step 3c**, if any — a single prose body; split it into
  discrete findings.

Skip threads already resolved or outdated unless the user asks otherwise.

A review summary or issue comment may contain several distinct findings. Split
those, too — each gets its own evaluation and disposition.

### 5. Evaluate each finding

For every finding, read the referenced file at the cited lines to see the current
code (it may have changed since the comment was written). Then judge it on:

- **Still applicable?** Does the code the finding refers to still exist in that form?
- **Correct?** Is the claim actually true given the surrounding code and project conventions?
- **Useful?** Would acting on it improve correctness, security, clarity, or consistency — versus being purely stylistic noise, out of scope, or a matter of taste the author already decided?
- **Actionable here?** Can it be fixed in this PR, or is it follow-up work?

Classify each finding as exactly one of:

- **`fix`** — correct and worth doing here.
- **`already-addressed`** — the current code already satisfies it.
- **`incorrect`** — the claim is wrong, or no longer applies. You can say *why*.
- **`out-of-scope`** — real, but belongs in separate work.
- **`unclear`** — you cannot confirm or refute it without information you do not
  have: the reviewer's intent, a product decision, or context outside the repo.

Judge human and agent findings by the same standard. Provenance changes what you
*do with the thread* in Step 8, never whether the finding is correct.

### 6. Apply the fixes

For each finding classified `fix`, make the change. Group related fixes into coherent edits rather than touching the same file repeatedly. After edits:

- Run the project's formatter/linter and test suite if they exist
- If a fix breaks tests, investigate the root cause before moving on
- Do not expand scope beyond what the finding asked for

### 7. Commit and push the fixes

If any fixes were applied, commit them to the PR branch and push:

- Stage only the files you changed (do not use `git add -A`)
- Write a commit message that summarizes the reviewer feedback being addressed
- Push to the PR's branch with `git push`

Push **before** Step 8, so the replies you post can point at a commit that exists.

### 8. Reply and resolve on GitHub

Close the loop on the ticket. What you do depends on the classification **and the
provenance**:

| Classification | Agent finding | Human finding |
| --- | --- | --- |
| `fix` | Resolve. Reply only if the fix differs from what was suggested. | Resolve. Reply only if the fix differs from what was suggested. |
| `already-addressed` | Reply naming where it is handled, resolve. | Reply naming where it is handled, resolve. |
| `incorrect` | Reply explaining why, resolve. | Reply explaining why, resolve. |
| `out-of-scope` | Reply naming the deferral (link a follow-up issue if you filed one), resolve. | Reply naming the deferral. Resolve **only** if you filed a follow-up issue; otherwise leave open and flag it. |
| `unclear` | Reply saying what was ambiguous and what you assumed, resolve. | Reply asking the specific question. **Leave unresolved** and flag it in the report. |

The two rules the table encodes:

- **An agent thread may always be resolved**, including when it is ambiguous —
  nobody is waiting on an answer. When you resolve an ambiguous agent finding,
  leave a reply saying what was unclear and how you read it, so the resolution is
  not silent.
- **A human thread stays open whenever the human is the only one who can settle
  it** — you could not confirm the finding, or you need information they have.
  Every other human thread is answered and resolved.

**Reply to an inline thread** using the `databaseId` of its first comment:

```bash
gh api --method POST \
  "repos/{owner}/{repo}/pulls/<number>/comments/<first-comment-databaseId>/replies" \
  -f body="$(cat reply.md)"
```

**Resolve a thread** with the GraphQL mutation, using the thread node `id`:

```bash
gh api graphql -f id='<thread-node-id>' -f query='
mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }'
```

**Review summaries and top-level comments are not threads** — there is nothing to
resolve and no inline reply endpoint. Answer them in a **single** consolidated PR
comment rather than one comment per finding:

```bash
gh pr comment <number> --body-file responses.md
```

That comment should list each such finding, its disposition, and a one-line
rationale, and end with the questions left for a human (if any). Findings from
the review generated in Step 3c belong here too — do not reply to your own
`## Automated review` comment thread; summarize what you did with it.

Keep replies short and factual: what you did or why the finding does not hold.
No apologies, no restating the finding back at length.

### 9. Report

Print a concise report covering:

- **Reviews found** — each reviewer, human or agent, and what they contributed
- **The automated review source** — an existing agent review, or one generated by
  `<tool>` (copilot CLI / codex CLI / Claude `code-review` / Claude subagent)
- The PR (number, title, url) and the branch checked out
- A table of every finding evaluated, with: author, **provenance (human/agent)**,
  location (`file:line`), classification, disposition on GitHub (replied /
  resolved / left open), and a one-line rationale
- For `fix` items, what was changed (file paths + brief description)
- **Needs the human** — a separate, prominent list of every human finding left
  unresolved, each with the specific question that must be answered. This is the
  only category the user has to act on; do not bury it in the table.
- Any test/lint results
- Suggested next steps
