#!/usr/bin/env bash
#
# Fetch open Dependabot alerts for the current repository.
# Outputs one JSON object per line (JSONL), sorted by CVSS score descending.
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

# Fetch open dependabot alerts, extract key fields, sort by CVSS descending
alerts=$(gh api "/repos/${repo}/dependabot/alerts" \
  --paginate \
  -q '.[] | select(.state == "open") | {
    number: .number,
    package: .security_vulnerability.package.name,
    ecosystem: .security_vulnerability.package.ecosystem,
    manifest: .dependency.manifest_path,
    severity: .security_advisory.severity,
    cvss: (.security_advisory.cvss.score // 0),
    summary: .security_advisory.summary,
    ghsa_id: .security_advisory.ghsa_id,
    patched_version: .security_vulnerability.first_patched_version.identifier
  }' 2>/dev/null) || {
  echo "Error: failed to fetch dependabot alerts. Check that you have access to ${repo} and Dependabot alerts are enabled." >&2
  exit 1
}

if [ -z "$alerts" ]; then
  echo "No open Dependabot alerts for ${repo}."
  exit 0
fi

# Sort by CVSS score descending (numeric, reverse)
echo "$alerts" | jq -s 'sort_by(-.cvss)[]' -c
