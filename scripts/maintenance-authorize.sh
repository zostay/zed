#!/usr/bin/env bash
#
# maintenance-authorize.sh — one whole-sweep authorization grant per maintenance run.
#
# The maintenance model is "assume elevated permission for the whole sweep":
# authorize **once, up front, for the entire run** rather than per privileged
# project. A single grant (keyed by the sweep's `<tag>`) covers the whole run.
# While it is valid, the PreToolUse hook (hooks/maintenance-authz.sh) lifts the
# normal permission block for privileged commands — bare `gh pr merge`/`gh pr close`
# already match their own allow rules, but arbitrary privileged commands like a
# project's `make deploy` are covered by the grant for the duration of the run.
#
# This replaces the old per-(tag, project) grant + TTL + one-time consume-on-use
# machinery. There is no per-project gate any more: an interactive sweep asks once
# up front and creates the grant; an unattended sweep relies on a grant created
# ahead of time; the run revokes the grant when it finishes (a generous default
# TTL is only a backstop if the run dies before it can).
#
# Grants live as JSON files under <data-dir>/grants/, one per tag:
#   sweep__<sanitized-tag>.json
#   { "tag", "granted_at", "expires_at", "expires_epoch", "note" }
#
# Subcommands:
#   grant   --tag T [--ttl DUR] [--note S]
#                       Create/replace the whole-sweep grant for tag T. Default
#                       ttl 12h (a backstop — the run revokes on completion).
#   check   [--tag T]
#                       Exit 0 if a valid (unexpired) sweep grant exists, else 1.
#                       With --tag, checks that tag; without, matches a valid grant
#                       for ANY tag (this is what the hook uses). Does NOT mutate.
#                       Prints the matching grant JSON on stdout.
#   revoke  --tag T     Delete the grant if present (no error if absent).
#   list                List all sweep grants with their status (valid/expired).
#   path    --tag T     Print the grant file path (whether or not it exists).
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

# A generous default: only a backstop. The run revokes its grant on completion,
# so this just bounds how long an orphaned grant (a run that died mid-sweep)
# stays valid. It must comfortably exceed the wall-clock of a long serial sweep —
# the run-#6 failure was a 2h grant expiring under a 2h+ run.
DEFAULT_TTL="12h"

usage() {
  cat >&2 <<'EOF'
Usage: maintenance-authorize.sh <subcommand> [flags]

Subcommands:
  grant   --tag T [--ttl DUR] [--note S]
                      Create/replace the whole-sweep grant for tag T (default ttl 12h).
  check   [--tag T]
                      Exit 0 if a valid sweep grant exists (prints it), else exit 1.
                      With --tag checks that tag; without, matches any tag (hook use).
  revoke  --tag T     Delete the grant if present.
  list                List all sweep grants and their status.
  path    --tag T     Print the grant file path.

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

# Sanitize a tag token for safe use in a filename: keep [A-Za-z0-9._-], replace
# everything else with '_'.
sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Grant file path for a sweep tag.
grant_file() {
  local tag="$1"
  printf '%s/sweep__%s.json\n' "$(grants_dir)" "$(sanitize "$tag")"
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

# Parse --flag value pairs into globals: ARG_TAG ARG_TTL ARG_NOTE. Unknown flags
# -> usage, exit 2.
ARG_TAG=""; ARG_TTL=""; ARG_NOTE=""
# Require that a value-taking flag actually has a value. Called as `need_val "$@"`
# so $1 is the flag and $2 (if present) its value; errors with usage/exit 2 when
# the value is missing — instead of letting `shift 2` blow up under `set -e`.
need_val() {
  [ "$#" -ge 2 ] || { echo "Error: $1 requires a value." >&2; usage; exit 2; }
}
parse_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag)  need_val "$@"; ARG_TAG="$2"; shift 2 ;;
      --ttl)  need_val "$@"; ARG_TTL="$2"; shift 2 ;;
      --note) need_val "$@"; ARG_NOTE="$2"; shift 2 ;;
      *) echo "Error: unknown flag '$1'." >&2; usage; exit 2 ;;
    esac
  done
}

require_tag() { [ -n "$ARG_TAG" ] || { echo "Error: --tag is required." >&2; exit 2; }; }

# --- subcommands -----------------------------------------------------------

cmd_grant() {
  parse_flags "$@"
  require_tag
  local ttl="${ARG_TTL:-$DEFAULT_TTL}" secs now_epoch exp_epoch exp_iso
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

  local dir file tmp
  dir="$(ensure_grants_dir)"
  file="$(grant_file "$ARG_TAG")"
  tmp="$(mktemp "${dir}/.grant.XXXXXX")"
  jq -nc \
    --arg tag "$ARG_TAG" \
    --arg granted_at "$(mtnc_now)" \
    --arg expires_at "$exp_iso" \
    --argjson expires_epoch "$exp_epoch" \
    --arg note "$ARG_NOTE" \
    '{tag:$tag, granted_at:$granted_at,
      expires_at:(if $expires_at=="" then null else $expires_at end),
      expires_epoch:$expires_epoch,
      note:(if $note=="" then null else $note end)}' >"$tmp"
  # Force owner-only perms before publishing: the grant authorizes privileged
  # tasks, so it must not be world/group readable regardless of the umask.
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  echo "Authorized the '${ARG_TAG}' sweep: expires ${exp_iso:-never}." >&2
  printf '%s\n' "$file"
}

cmd_check() {
  parse_flags "$@"
  local file
  if [ -n "$ARG_TAG" ]; then
    file="$(grant_file "$ARG_TAG")"
    if grant_is_valid "$file"; then cat "$file"; return 0; fi
    echo "No valid sweep grant for tag '${ARG_TAG}'." >&2
    return 1
  fi
  # No tag: accept any valid sweep grant. This is the hook's question — "is some
  # sweep currently authorized?" — since the hook sees only the command, not the
  # tag. Use nullglob with a fully-quoted directory so a data-dir path containing
  # spaces is safe.
  local d f
  d="$(grants_dir)"
  shopt -s nullglob
  for f in "$d"/sweep__*.json; do
    # Unset nullglob before `cat` so that, under `set -e`, a `cat` failure (e.g.
    # the file vanished between the validity check and here) can't abort with the
    # shell option still toggled on.
    if grant_is_valid "$f"; then shopt -u nullglob; cat "$f"; return 0; fi
  done
  shopt -u nullglob
  echo "No valid sweep grant (any tag)." >&2
  return 1
}

cmd_revoke() {
  parse_flags "$@"
  require_tag
  local file
  file="$(grant_file "$ARG_TAG")"
  if [ -f "$file" ]; then
    rm -f "$file"
    echo "Revoked the '${ARG_TAG}' sweep grant." >&2
  else
    echo "No sweep grant to revoke for tag '${ARG_TAG}'." >&2
  fi
}

cmd_list() {
  local d f status
  d="$(grants_dir)"
  [ -d "$d" ] || { echo "No grants." >&2; return 0; }
  shopt -s nullglob
  local any=0
  for f in "$d"/sweep__*.json; do
    any=1
    if grant_is_valid "$f"; then status="valid"; else status="expired"; fi
    # Grant files are user-writable state; skip a corrupt one with a warning
    # rather than letting jq's failure abort the listing under `set -e`.
    jq -c --arg status "$status" '{tag, expires_at, status:$status}' "$f" 2>/dev/null \
      || echo "warning: skipping unreadable/corrupt grant file: $f" >&2
  done
  shopt -u nullglob
  [ "$any" -eq 1 ] || echo "No grants." >&2
}

cmd_path() {
  parse_flags "$@"
  require_tag
  grant_file "$ARG_TAG"
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift || true
  case "$sub" in
    grant)  cmd_grant "$@" ;;
    check)  cmd_check "$@" ;;
    revoke) cmd_revoke "$@" ;;
    list)   cmd_list "$@" ;;
    path)   cmd_path "$@" ;;
    ""|-h|--help|help) usage; [ "$sub" = "" ] && exit 2 || exit 0 ;;
    *) echo "Error: unknown subcommand '$sub'." >&2; usage; exit 2 ;;
  esac
}

main "$@"
