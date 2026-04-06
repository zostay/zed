---
name: pr-review-fix
description: Check out a PR, read its GitHub review comments, evaluate each for validity, fix the good recommendations, and report on what was done.
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

### 3. Fetch review comments

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

Skip comments authored by the current user (`gh api user`) and skip threads that are already marked resolved/outdated unless the user asks otherwise.

### 4. Evaluate each comment

For every unresolved comment thread, read the referenced file at the cited lines to see the current code (it may have changed since the comment was written). Then judge the comment on:

- **Still applicable?** Does the code the comment refers to still exist in that form?
- **Correct?** Is the reviewer's claim actually true given the surrounding code and project conventions?
- **Useful?** Would acting on it improve correctness, security, clarity, or consistency — versus being purely stylistic noise, out of scope, or a matter of taste the author already decided?
- **Actionable here?** Can it be fixed in this PR, or is it follow-up work?

Classify each thread as one of: `fix`, `reject` (with reason), `already-addressed`, `out-of-scope`, or `needs-user-input` (ambiguous / requires a judgment call the user should make).

### 5. Apply the fixes

For each thread classified `fix`, make the change. Group related fixes into coherent edits rather than touching the same file repeatedly. After edits:

- Run the project's formatter/linter and test suite if they exist
- If a fix breaks tests, investigate the root cause before moving on
- Do not expand scope beyond what the comment asked for

### 6. Commit and push the fixes

If any fixes were applied, commit them to the PR branch and push:

- Stage only the files you changed (do not use `git add -A`)
- Write a commit message that summarizes the reviewer feedback being addressed
- Push to the PR's branch with `git push`

Do **not** reply to or resolve the review comments on GitHub automatically — leave that to the user unless they explicitly ask.

### 7. Report

Print a concise report covering:

- The PR (number, title, url) and the branch checked out
- A table or list of every comment thread evaluated, with: author, location (`file:line`), classification, and a one-line rationale
- For `fix` items, what was changed (file paths + brief description)
- For `needs-user-input` items, the specific question the user needs to answer
- Any test/lint results
- Suggested next steps (e.g., review the diff, commit, push, reply to reviewers)
