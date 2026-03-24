#!/usr/bin/env bash
#
# Fetch open Dependabot PRs for the current repository and their merge readiness.
# Outputs one JSON object per line (JSONL), sorted by oldest first.
#

set -euo pipefail

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

# Fetch open Dependabot PRs (oldest first)
pr_numbers=$(gh pr list \
  --author "app/dependabot" \
  --state open \
  --json number \
  --jq '.[].number' 2>/dev/null) || {
  echo "Error: failed to list Dependabot PRs. Check that you have access to ${repo}." >&2
  exit 1
}

if [ -z "$pr_numbers" ]; then
  echo "No open Dependabot PRs for ${repo}."
  exit 0
fi

# For each PR, fetch detailed merge-readiness info and emit JSONL
for pr in $pr_numbers; do
  pr_json=$(gh pr view "$pr" \
    --json number,title,headRefName,mergeable,reviewDecision,url,statusCheckRollup 2>/dev/null) || continue

  # Determine if all checks pass: SUCCESS or NEUTRAL means passing.
  # If there are no checks, we consider it passing.
  checks_pass=$(echo "$pr_json" | jq -r '
    if (.statusCheckRollup | length) == 0 then
      true
    else
      [.statusCheckRollup[] | .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL")] | all
    end
  ')

  echo "$pr_json" | jq -c \
    --argjson checks_pass "$checks_pass" \
    '{
      number: .number,
      title: .title,
      branch: .headRefName,
      mergeable: .mergeable,
      checks_pass: $checks_pass,
      review_decision: .reviewDecision,
      url: .url
    }'
done
