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

# Error to stderr and exit 1 if the named command is not available on PATH.
mtnc_require() {
  local cmd="${1:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Error: required command %s not found on PATH.\n' "$cmd" >&2
    exit 1
  fi
}
