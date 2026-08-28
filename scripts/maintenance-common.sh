#!/usr/bin/env bash
#
# Shared library for the maintenance skill scripts. Source this file; it only
# defines functions and never performs side effects on source.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/maintenance-common.sh"
#
# Functions defined:
#   mtnc_data_dir        — echo the resolved data dir (does NOT create it)
#   mtnc_ensure_data_dir — mkdir -p the data dir, echo it
#   mtnc_db_path         — echo $MAINTENANCE_DB if set, else <data_dir>/observability.db
#   mtnc_config_path     — echo <data_dir>/config.json
#   mtnc_now             — echo current UTC time ISO-8601 (e.g. 2026-06-01T17:04:05Z)
#   mtnc_sql_escape <s>  — echo string with single quotes doubled for inline SQL literals
#   mtnc_require <cmd>   — error to stderr and exit 1 if <cmd> is not on PATH
#   mtnc_plugin_root     — echo the plugin's root directory
#   mtnc_plugin_version  — echo the plugin version from .claude-plugin/plugin.json

# Resolve the data directory in priority order:
#   1. $MAINTENANCE_DATA_DIR if set (test/override hook)
#   2. $CLAUDE_PLUGIN_DATA/maintenance if CLAUDE_PLUGIN_DATA is set
#   3. ${XDG_DATA_HOME:-$HOME/.local/share}/zed-maintenance otherwise
mtnc_data_dir() {
  if [ -n "${MAINTENANCE_DATA_DIR:-}" ]; then
    printf '%s\n' "$MAINTENANCE_DATA_DIR"
  elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_DATA}/maintenance"
  else
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/zed-maintenance"
  fi
}

# Ensure the data directory exists, then echo it.
mtnc_ensure_data_dir() {
  local dir
  dir="$(mtnc_data_dir)"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Echo the SQLite database path.
mtnc_db_path() {
  if [ -n "${MAINTENANCE_DB:-}" ]; then
    printf '%s\n' "$MAINTENANCE_DB"
  else
    printf '%s\n' "$(mtnc_data_dir)/observability.db"
  fi
}

# Echo the config.json path.
mtnc_config_path() {
  printf '%s\n' "$(mtnc_data_dir)/config.json"
}

# Echo the current UTC time as ISO-8601, e.g. 2026-06-01T17:04:05Z.
mtnc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Echo the argument with every single quote doubled ('->'') so it is safe to
# splice into a single-quoted SQL string literal.
mtnc_sql_escape() {
  local s="${1:-}"
  local q="'"
  printf '%s\n' "${s//$q/$q$q}"
}

# Echo the plugin's root directory — the one holding .claude-plugin/ and app/.
#
# Derived from this file's own location (scripts/../) rather than from
# CLAUDE_PLUGIN_ROOT, so it is correct even when a script is invoked directly
# with that variable unset. CLAUDE_PLUGIN_ROOT still wins when it is set, since
# the harness knows which copy of the plugin it actually loaded — which matters
# when several versions are installed side by side in the plugin cache.
mtnc_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  printf '%s\n' "${here:-.}"
}

# Echo the plugin version recorded in .claude-plugin/plugin.json, or the literal
# string "unknown" when it cannot be read.
#
# Parsed with grep/sed rather than jq: this is consumed by the monitor, which
# otherwise needs no JSON tooling, and plugin.json's version is a plain string
# field. "unknown" is deliberately a value rather than an error — callers compare
# versions for equality, and two unknowns comparing equal is the right outcome
# (it must not look like a version *change* on every single call).
mtnc_plugin_version() {
  local manifest version
  manifest="$(mtnc_plugin_root)/.claude-plugin/plugin.json"
  if [ ! -r "$manifest" ]; then
    printf 'unknown\n'
    return 0
  fi
  version="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" 2>/dev/null \
    | head -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')"
  printf '%s\n' "${version:-unknown}"
}

# Error to stderr and exit 1 if the named command is not available on PATH.
mtnc_require() {
  local cmd="${1:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Error: required command %s not found on PATH.\n' "$cmd" >&2
    exit 1
  fi
}
