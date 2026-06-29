#!/usr/bin/env bash
#
# Fetch open Dependabot PRs for the current repository and their merge readiness.
# Outputs one JSON object per line (JSONL), sorted by oldest first.
#
# Output fields:
#   number, title, branch, base, ecosystem, mergeable, checks_pass,
#   review_decision, url
#
# `base` is the PR's target branch (baseRefName) — the branch a batch
# integration branch should be cut from. `ecosystem` is the Dependabot
# package-ecosystem parsed from the branch name (dependabot/<ecosystem>/...,
# e.g. go_modules, npm_and_yarn, github_actions, pip, bundler, docker) or null
# when the branch does not follow that convention. Both let a caller group ready
# PRs and batch-merge them onto one branch instead of one PR at a time.
#
# checks_pass is true/false when status check info is available, or null when
# the token lacks checks:read permission (statusCheckRollup inaccessible). It is
# true only when every check concluded acceptably (SUCCESS/NEUTRAL/SKIPPED), so
# intentionally skipped/neutral checks (e.g. a "Build Summary" job gated by `if:`)
# do NOT make a genuinely-ready PR look blocked; it is false when a check actually
# failed or has not finished yet.
#

set -euo pipefail

# Guarantee the standard tool directories are reachable even when this script is
# launched from a stripped-down environment (e.g. a sandboxed subshell whose PATH
# omits Homebrew). A minimal PATH can hide gh/jq and stall the sweep. Append so
# any ordering the caller set still wins.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

# Check that gh CLI is available
if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI is not installed or not in PATH." >&2
  exit 1
fi

# Check that we're in a git repository and can determine the remote
repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
  echo "Error: unable to determine repository. Are you in a git repo with a GitHub remote?" >&2
  exit 1
}

base_fields="number,title,headRefName,baseRefName,mergeable,reviewDecision,url"

# Try fetching with statusCheckRollup (requires checks:read token permission).
# If that fails, fall back to fetching without it.
has_checks=true
pr_json=$(gh pr list \
  --author "app/dependabot" \
  --state open \
  --limit 100 \
  --json "${base_fields},statusCheckRollup" 2>/dev/null) || {
  has_checks=false
  pr_json=$(gh pr list \
    --author "app/dependabot" \
    --state open \
    --limit 100 \
    --json "${base_fields}" 2>/dev/null) || {
    echo "Error: failed to list Dependabot PRs. Check that you have access to ${repo}." >&2
    exit 1
  }
}

# Check if any PRs were found
pr_count=$(echo "$pr_json" | jq 'length')
if [ "$pr_count" -eq 0 ]; then
  echo "No open Dependabot PRs for ${repo}."
  exit 0
fi

# Emit JSONL, oldest first (gh returns newest first, so reverse)
if [ "$has_checks" = true ]; then
  echo "$pr_json" | jq -c 'reverse | .[] | {
    number: .number,
    title: .title,
    branch: .headRefName,
    base: .baseRefName,
    ecosystem: (
      if (.headRefName // "" | startswith("dependabot/"))
      then (.headRefName | split("/")[1])
      else null end
    ),
    mergeable: .mergeable,
    checks_pass: (
      if (.statusCheckRollup | length) == 0 then
        true
      else
        # True only when every check has concluded acceptably: SUCCESS, NEUTRAL,
        # or intentionally SKIPPED. Skipped/neutral are intentional no-ops and must
        # NOT count as failures (the old `status=="COMPLETED" and conclusion in
        # {SUCCESS,NEUTRAL}` test made an `if:`-gated "Build Summary" job mark a
        # genuinely-ready PR as blocked). A real failure (FAILURE/TIMED_OUT/…) or a
        # check that has not finished yet keeps the PR out of "ready" — pending is
        # re-evaluated on the next fetch rather than merged early. statusCheckRollup
        # mixes CheckRun nodes (.conclusion) and StatusContext nodes (.state);
        # normalize across both.
        [ .statusCheckRollup[]
          | ((.conclusion // .state) // "") | ascii_upcase
          | . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED"
        ] | all
      end
    ),
    review_decision: .reviewDecision,
    url: .url
  }'
else
  echo "$pr_json" | jq -c 'reverse | .[] | {
    number: .number,
    title: .title,
    branch: .headRefName,
    base: .baseRefName,
    ecosystem: (
      if (.headRefName // "" | startswith("dependabot/"))
      then (.headRefName | split("/")[1])
      else null end
    ),
    mergeable: .mergeable,
    checks_pass: null,
    review_decision: .reviewDecision,
    url: .url
  }'
fi
