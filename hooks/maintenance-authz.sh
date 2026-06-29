#!/usr/bin/env bash
#
# maintenance-authz.sh — PreToolUse authorization hook for privileged maintenance.
#
# Registered (see hooks/hooks.json) for Bash tool calls. Its only job is to
# *lift* the normal permission block for a command while a maintenance sweep is
# authorized — i.e. while a valid whole-sweep grant exists (created up front via
# maintenance-authorize.sh). It NEVER denies: with no grant it stays silent and
# defers to the normal permission flow (a prompt in an interactive session, an
# auto-deny in an unattended/dontAsk run).
#
# The model is "assume elevated permission for the whole sweep": authorization is
# per-run, not per-project. Bare `gh pr merge`/`gh pr close` already match their
# own allow rules and need no help; this hook exists for the remaining case —
# arbitrary privileged commands like a project's `make deploy` that have no allow
# rule. While the sweep is authorized, those run unblocked; once the run revokes
# its grant (or the grant expires), normal permission handling resumes.
#
# Input: PreToolUse JSON on stdin (tool_name, ...).
# Output: permissionDecision "allow" JSON when a valid sweep grant is present;
# otherwise nothing. Always exits 0 so a hook hiccup can never block maintenance.

set -uo pipefail

# Self-heal PATH so jq resolves under a stripped environment.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

# Any failure below should defer (exit 0, no output), never block.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool" = "Bash" ] || exit 0

# Resolve the authorize script relative to this hook (hooks/ -> ../scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
AUTH="${SCRIPT_DIR}/../scripts/maintenance-authorize.sh"
[ -x "$AUTH" ] || exit 0

# A valid whole-sweep grant (under any tag) lifts the block for this command.
if "$AUTH" check >/dev/null 2>&1; then
  jq -nc \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"maintenance: a sweep is authorized (whole-sweep grant present)"}}'
fi

exit 0
