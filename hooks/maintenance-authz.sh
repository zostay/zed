#!/usr/bin/env bash
#
# maintenance-authz.sh — PreToolUse authorization hook for privileged maintenance.
#
# Registered (see hooks/hooks.json) for Bash tool calls. Its only job is to
# *lift* the normal permission block for a command when the project it runs in
# has a valid, explicit authorization grant (created out-of-band via
# maintenance-authorize.sh). It NEVER denies: with no grant it stays silent and
# defers to the normal permission flow (a prompt in an interactive session, an
# auto-deny in an unattended/dontAsk run) — i.e. the pre-existing behavior.
#
# This is defense-in-depth for the case where a project's `maintenance-<tag>`
# skill is run directly (outside the orchestrator). The orchestrator independently
# checks the grant before it dispatches a `requiresAuthorization` project, so the
# gate holds even where this hook does not fire (e.g. inside a subagent, if the
# running Claude Code does not apply plugin hooks to subagent tool calls).
#
# Grant scope is per project (keyed by the cwd's basename, matching how the
# blocklist matches projects). While a grant is valid, Bash commands in that
# project's root are allowed without a prompt; run privileged steps from the
# project root so the cwd basename matches the granted project name.
#
# Input: PreToolUse JSON on stdin (tool_name, tool_input, cwd, ...).
# Output: permissionDecision "allow" JSON when a grant is present; otherwise
# nothing. Always exits 0 so a hook hiccup can never block maintenance.

set -uo pipefail

# Self-heal PATH so jq/basename/date resolve under a stripped environment.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

# Any failure below should defer (exit 0, no output), never block.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool" = "Bash" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || exit 0
project="$(basename "$cwd")"
[ -n "$project" ] || exit 0

# Resolve the authorize script relative to this hook (hooks/ -> ../scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
AUTH="${SCRIPT_DIR}/../scripts/maintenance-authorize.sh"
[ -x "$AUTH" ] || exit 0

# A valid grant for this project (under any tag) lifts the block for this command.
if "$AUTH" check --project "$project" >/dev/null 2>&1; then
  jq -nc --arg p "$project" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:("maintenance: explicit authorization grant present for project \"" + $p + "\"")}}'
fi

exit 0
