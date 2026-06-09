#!/usr/bin/env bash
#
# maintenance-authorize.sh — explicit, out-of-band authorization grants for
# privileged maintenance tasks (e.g. production deployments).
#
# A project marks its `maintenance-<tag>` skill privileged with
# `requiresAuthorization: true` in the skill front matter. The orchestrator then
# refuses to run that project unattended unless a valid authorization *grant*
# exists. You create a grant deliberately, ahead of the sweep, with `grant`; the
# orchestrator (and the PreToolUse authorization hook) check for it, and it is
# consumed/expired so it does not silently authorize every future run.
#
# Grants live as JSON files under <data-dir>/grants/, one per (tag, project):
#   <tag>__<sanitized-project>.json
#   { "tag", "project", "granted_at", "expires_at", "expires_epoch", "one_time", "note" }
#
# Subcommands:
#   grant   --tag T --project P [--ttl DUR] [--repeat] [--note S]
#                       Create/replace a grant. Default ttl 2h, one-time.
#                       --repeat makes it reusable until it expires (not consumed).
#   check   --project P [--tag T]
#                       Exit 0 if a valid (unexpired) grant exists, else exit 1.
#                       With no --tag, matches a grant for that project under any tag.
#                       Does NOT consume. Prints the matching grant JSON on stdout.
#   consume --tag T --project P
#                       check, then delete the grant if it is one-time. Exit 0 on
#                       a valid grant, else exit 1. Idempotent for --repeat grants.
#   revoke  --tag T --project P
#                       Delete the grant if present (no error if absent).
#   list                List all grants with their status (valid/expired).
#   path    --tag T --project P
#                       Print the grant file path (whether or not it exists).
#
# Durations (DUR): bare seconds, or <n>s / <n>m / <n>h / <n>d. Unknown subcommand
# or bad args -> usage to stderr, exit 2.

set -euo pipefail

# Guarantee the standard tool directories are reachable even when this script is
# launched from a stripped-down environment (e.g. a subshell whose PATH omits
# Homebrew). A minimal PATH can hide bash/dirname/jq/date and stall the sweep.
# Append so any ordering the caller set still wins.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

source "$(dirname "${BASH_SOURCE[0]}")/maintenance-common.sh"

mtnc_require jq

DEFAULT_TTL="2h"

usage() {
  cat >&2 <<'EOF'
Usage: maintenance-authorize.sh <subcommand> [flags]

Subcommands:
  grant   --tag T --project P [--ttl DUR] [--repeat] [--note S]
                      Create/replace an authorization grant (default ttl 2h, one-time).
  check   --project P [--tag T]
                      Exit 0 if a valid grant exists (prints it), else exit 1. No consume.
  consume --tag T --project P
                      check, then delete the grant if it is one-time. Exit 0 if valid.
  revoke  --tag T --project P
                      Delete the grant if present.
  list                List all grants and their status.
  path    --tag T --project P
                      Print the grant file path.

Durations: bare seconds, or <n>s / <n>m / <n>h / <n>d (e.g. 30m, 24h, 2d).
EOF
}

# --- helpers ---------------------------------------------------------------

grants_dir() { printf '%s\n' "$(mtnc_data_dir)/grants"; }

ensure_grants_dir() {
  local d
  d="$(grants_dir)"
  mkdir -p "$d"
  # Grants are a security control; keep the directory private to the owner so
  # other users on a shared host can't read or tamper with grant files.
  chmod 700 "$d" 2>/dev/null || true
  printf '%s\n' "$d"
}

# Sanitize a tag/project token for safe use in a filename: keep [A-Za-z0-9._-],
# replace everything else with '_'.
sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Grant file path for a (tag, project) pair.
grant_file() {
  local tag="$1" project="$2"
  printf '%s/%s__%s.json\n' "$(grants_dir)" "$(sanitize "$tag")" "$(sanitize "$project")"
}

# Parse a duration string into seconds on stdout. Returns 1 on a bad format.
parse_ttl() {
  local s="$1" num unit
  if printf '%s' "$s" | grep -Eq '^[0-9]+$'; then printf '%s' "$s"; return 0; fi
  if printf '%s' "$s" | grep -Eq '^[0-9]+[smhd]$'; then
    num="${s%[smhd]}"; unit="${s: -1}"
    case "$unit" in
      s) printf '%s' "$num" ;;
      m) printf '%s' "$((num * 60))" ;;
      h) printf '%s' "$((num * 3600))" ;;
      d) printf '%s' "$((num * 86400))" ;;
    esac
    return 0
  fi
  return 1
}

# Is the grant file at $1 currently valid (exists, parseable, and not past its
# expiry)? A genuinely null expires_epoch means "never expires". A missing,
# unreadable, or corrupt/malformed grant file is treated as INVALID — it must
# never be able to bypass the expiry check and authorize a privileged task.
# Returns 0 if valid, 1 otherwise.
grant_is_valid() {
  local file="$1" exp now
  [ -f "$file" ] || return 1
  # Reject anything that is not well-formed JSON before trusting its contents.
  jq -e . "$file" >/dev/null 2>&1 || return 1
  exp="$(jq -r '.expires_epoch // "null"' "$file" 2>/dev/null)"
  [ "$exp" = "null" ] && return 0
  printf '%s' "$exp" | grep -Eq '^[0-9]+$' || return 1
  now="$(date +%s)"
  [ "$now" -lt "$exp" ]
}

# Parse --flag value pairs into globals: ARG_TAG ARG_PROJECT ARG_TTL ARG_NOTE
# ARG_REPEAT. Unknown flags -> usage, exit 2.
ARG_TAG=""; ARG_PROJECT=""; ARG_TTL=""; ARG_NOTE=""; ARG_REPEAT=0
# Require that a value-taking flag actually has a value. Called as `need_val "$@"`
# so $1 is the flag and $2 (if present) its value; errors with usage/exit 2 when
# the value is missing — instead of letting `shift 2` blow up under `set -e`.
need_val() {
  [ "$#" -ge 2 ] || { echo "Error: $1 requires a value." >&2; usage; exit 2; }
}
parse_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag)     need_val "$@"; ARG_TAG="$2"; shift 2 ;;
      --project) need_val "$@"; ARG_PROJECT="$2"; shift 2 ;;
      --ttl)     need_val "$@"; ARG_TTL="$2"; shift 2 ;;
      --note)    need_val "$@"; ARG_NOTE="$2"; shift 2 ;;
      --repeat)  ARG_REPEAT=1; shift ;;
      *) echo "Error: unknown flag '$1'." >&2; usage; exit 2 ;;
    esac
  done
}

require_tag()     { [ -n "$ARG_TAG" ]     || { echo "Error: --tag is required." >&2; exit 2; }; }
require_project() { [ -n "$ARG_PROJECT" ] || { echo "Error: --project is required." >&2; exit 2; }; }

# --- subcommands -----------------------------------------------------------

cmd_grant() {
  parse_flags "$@"
  require_tag; require_project
  local ttl="${ARG_TTL:-$DEFAULT_TTL}" secs now_epoch exp_epoch exp_iso one_time
  if ! secs="$(parse_ttl "$ttl")"; then
    echo "Error: invalid --ttl '$ttl' (use seconds, or <n>s/<n>m/<n>h/<n>d)." >&2
    exit 2
  fi
  now_epoch="$(date +%s)"
  exp_epoch="$((now_epoch + secs))"
  # ISO-8601 for the expiry, computed from the epoch in a way that works on both
  # BSD (macOS) and GNU date.
  if exp_iso="$(date -u -r "$exp_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then :;
  elif exp_iso="$(date -u -d "@$exp_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then :;
  else exp_iso=""; fi
  one_time=true; [ "$ARG_REPEAT" -eq 1 ] && one_time=false

  local dir file tmp
  dir="$(ensure_grants_dir)"
  file="$(grant_file "$ARG_TAG" "$ARG_PROJECT")"
  tmp="$(mktemp "${dir}/.grant.XXXXXX")"
  jq -nc \
    --arg tag "$ARG_TAG" \
    --arg project "$ARG_PROJECT" \
    --arg granted_at "$(mtnc_now)" \
    --arg expires_at "$exp_iso" \
    --argjson expires_epoch "$exp_epoch" \
    --argjson one_time "$one_time" \
    --arg note "$ARG_NOTE" \
    '{tag:$tag, project:$project, granted_at:$granted_at,
      expires_at:(if $expires_at=="" then null else $expires_at end),
      expires_epoch:$expires_epoch, one_time:$one_time,
      note:(if $note=="" then null else $note end)}' >"$tmp"
  # Force owner-only perms before publishing: the grant authorizes privileged
  # tasks, so it must not be world/group readable regardless of the umask.
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  echo "Granted authorization for '${ARG_PROJECT}' (tag '${ARG_TAG}'): expires ${exp_iso:-never}, $([ "$one_time" = true ] && echo one-time || echo reusable)." >&2
  printf '%s\n' "$file"
}

cmd_check() {
  parse_flags "$@"
  require_project
  local file
  if [ -n "$ARG_TAG" ]; then
    file="$(grant_file "$ARG_TAG" "$ARG_PROJECT")"
    if grant_is_valid "$file"; then cat "$file"; return 0; fi
    echo "No valid grant for '${ARG_PROJECT}' (tag '${ARG_TAG}')." >&2
    return 1
  fi
  # No tag: accept a valid grant for this project under any tag. Use nullglob
  # with a fully-quoted directory so a data-dir path containing spaces is safe.
  local d f
  d="$(grants_dir)"
  shopt -s nullglob
  for f in "$d"/*__"$(sanitize "$ARG_PROJECT")".json; do
    if grant_is_valid "$f"; then cat "$f"; shopt -u nullglob; return 0; fi
  done
  shopt -u nullglob
  echo "No valid grant for '${ARG_PROJECT}' (any tag)." >&2
  return 1
}

cmd_consume() {
  parse_flags "$@"
  require_tag; require_project
  local file one_time
  file="$(grant_file "$ARG_TAG" "$ARG_PROJECT")"
  if ! grant_is_valid "$file"; then
    echo "No valid grant to consume for '${ARG_PROJECT}' (tag '${ARG_TAG}')." >&2
    return 1
  fi
  cat "$file"
  one_time="$(jq -r '.one_time // true' "$file" 2>/dev/null || printf 'true')"
  if [ "$one_time" = "true" ]; then
    rm -f "$file"
    echo "Consumed one-time grant for '${ARG_PROJECT}' (tag '${ARG_TAG}')." >&2
  fi
  return 0
}

cmd_revoke() {
  parse_flags "$@"
  require_tag; require_project
  local file
  file="$(grant_file "$ARG_TAG" "$ARG_PROJECT")"
  if [ -f "$file" ]; then
    rm -f "$file"
    echo "Revoked grant for '${ARG_PROJECT}' (tag '${ARG_TAG}')." >&2
  else
    echo "No grant to revoke for '${ARG_PROJECT}' (tag '${ARG_TAG}')." >&2
  fi
}

cmd_list() {
  local d f status
  d="$(grants_dir)"
  [ -d "$d" ] || { echo "No grants." >&2; return 0; }
  shopt -s nullglob
  local any=0
  for f in "$d"/*.json; do
    any=1
    if grant_is_valid "$f"; then status="valid"; else status="expired"; fi
    # Grant files are user-writable state; skip a corrupt one with a warning
    # rather than letting jq's failure abort the listing under `set -e`.
    jq -c --arg status "$status" '{tag, project, expires_at, one_time, status:$status}' "$f" 2>/dev/null \
      || echo "warning: skipping unreadable/corrupt grant file: $f" >&2
  done
  shopt -u nullglob
  [ "$any" -eq 1 ] || echo "No grants." >&2
}

cmd_path() {
  parse_flags "$@"
  require_tag; require_project
  grant_file "$ARG_TAG" "$ARG_PROJECT"
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift || true
  case "$sub" in
    grant)   cmd_grant "$@" ;;
    check)   cmd_check "$@" ;;
    consume) cmd_consume "$@" ;;
    revoke)  cmd_revoke "$@" ;;
    list)    cmd_list "$@" ;;
    path)    cmd_path "$@" ;;
    ""|-h|--help|help) usage; [ "$sub" = "" ] && exit 2 || exit 0 ;;
    *) echo "Error: unknown subcommand '$sub'." >&2; usage; exit 2 ;;
  esac
}

main "$@"
