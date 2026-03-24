---
name: dependabot-fix
description: Check GitHub Dependabot alerts for the current repo and fix the highest-priority vulnerability.
---

# Dependabot Fix

Fix the highest-priority open Dependabot vulnerability in the current repository.

## Steps

### 1. Fetch open alerts

Run the helper script to retrieve all open Dependabot alerts:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dependabot-alerts.sh"
```

If the script reports no open alerts, tell the user there are no open Dependabot alerts and stop.

If the script fails, report the error and stop.

### 2. Analyze and prioritize

Parse the JSONL output. Each line is a JSON object with these fields:

- `number` — alert number
- `package` — vulnerable package name
- `ecosystem` — package ecosystem (npm, pip, maven, etc.)
- `manifest` — path to the manifest file (package.json, requirements.txt, etc.)
- `severity` — severity tier: `critical`, `high`, `medium`, or `low`
- `cvss` — CVSS score (0–10, higher is worse)
- `summary` — advisory summary
- `ghsa_id` — GitHub Security Advisory ID
- `patched_version` — first patched version, if known

Group alerts by **package name**. For each package, record:

- The number of open alerts affecting it
- Its highest severity tier
- Its highest CVSS score among those alerts

Rank packages using these criteria in order:

1. **Highest severity tier** (critical > high > medium > low)
2. **Highest CVSS score** within that tier
3. **Most alerts resolved** by fixing that package (greatest impact)

Select the top-ranked package.

### 3. Present the finding

Tell the user which package you're going to fix and why, including:

- Package name and ecosystem
- Severity and CVSS score of the worst alert
- Advisory summary of the worst alert
- How many total alerts fixing this package would resolve
- The patched version (if known)

### 4. Fix the dependency

Investigate and apply the fix:

1. Find the manifest file(s) that declare the dependency (use the `manifest` field from the alerts as a starting point)
2. Update the dependency to the patched version. If multiple alerts affect the same package, ensure the version you choose resolves all of them (use the highest patched version)
3. Run the project's install/lock command to update the lockfile (e.g., `npm install`, `pip install`, `bundle install`, `go mod tidy`, etc.)
4. Run the project's test suite if one exists to verify nothing is broken
5. If tests fail, investigate and fix the breakage

After fixing, summarize what was changed and suggest the user commit the result.
