#!/usr/bin/env bash
#
# maintenance-config.sh — configuration manager for the maintenance skill.
#
# Manages config.json, whose shape is:
#   { "searchRoots": ["~/projects"], "blocklist": [] }
#
# Subcommands:
#   init             create config.json with the default if absent; print path.
#   show             pretty-print config JSON (creating default first if missing).
#   roots            print each search root on its own line, with ~ expanded to $HOME.
#   blocklist        print each blocklist entry on its own line (no expansion).
#   add-root P       add a search root if not already present.
#   remove-root P    remove a search root.
#   add-block P      add a blocklist entry if not already present.
#   remove-block P   remove a blocklist entry.
#
# All mutations write atomically (temp file + mv). Unknown subcommand -> usage, exit 2.

set -euo pipefail

# Guarantee the standard tool directories are reachable even when this script is
# launched from a stripped-down environment (e.g. a subshell whose PATH omits
# Homebrew). A minimal PATH can hide bash/dirname/sqlite3/jq/find/python3 and
# stall the whole sweep. Append so any ordering the caller set still wins.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

source "$(dirname "${BASH_SOURCE[0]}")/maintenance-common.sh"

mtnc_require jq

DEFAULT_CONFIG='{ "searchRoots": ["~/projects"], "blocklist": [] }'

usage() {
  cat >&2 <<'EOF'
Usage: maintenance-config.sh <subcommand> [args]

Subcommands:
  init               Create config.json with defaults if absent; print its path.
  show               Pretty-print the configuration JSON.
  roots              Print each search root on its own line (~ expanded to $HOME).
  blocklist          Print each blocklist entry on its own line.
  add-root <path>    Add a search root.
  remove-root <path> Remove a search root.
  add-block <path>   Add a blocklist entry.
  remove-block <path> Remove a blocklist entry.
EOF
}

# Resolve the config path (in the data dir).
config_path() {
  mtnc_config_path
}

# Ensure config.json exists, creating the default (atomically) if it does not.
# Echoes the config path.
ensure_config() {
  local cfg
  cfg="$(config_path)"
  if [ ! -f "$cfg" ]; then
    mtnc_ensure_data_dir >/dev/null
    local tmp
    tmp="$(mktemp "${cfg}.XXXXXX")"
    printf '%s\n' "$DEFAULT_CONFIG" | jq '.' >"$tmp"
    mv -f "$tmp" "$cfg"
  fi
  printf '%s\n' "$cfg"
}

# Atomically apply a jq filter to the config file. Extra args after the filter
# are passed through to jq (e.g. --arg name value).
apply_jq() {
  local filter="$1"; shift
  local cfg tmp
  cfg="$(ensure_config)"
  tmp="$(mktemp "${cfg}.XXXXXX")"
  if jq "$@" "$filter" "$cfg" >"$tmp"; then
    mv -f "$tmp" "$cfg"
  else
    rm -f "$tmp"
    return 1
  fi
}

cmd_init() {
  ensure_config
}

cmd_show() {
  local cfg
  cfg="$(ensure_config)"
  jq '.' "$cfg"
}

cmd_roots() {
  local cfg
  cfg="$(ensure_config)"
  # Expand a leading ~ (or ~/...) to $HOME for each root.
  jq -r '.searchRoots[]?' "$cfg" | while IFS= read -r root; do
    case "$root" in
      "~")    printf '%s\n' "$HOME" ;;
      "~/"*)  printf '%s\n' "${HOME}/${root#\~/}" ;;
      *)      printf '%s\n' "$root" ;;
    esac
  done
}

cmd_blocklist() {
  local cfg
  cfg="$(ensure_config)"
  jq -r '.blocklist[]?' "$cfg"
}

cmd_add_root() {
  local p="${1:-}"
  if [ -z "$p" ]; then echo "Error: add-root requires a path." >&2; exit 2; fi
  apply_jq '.searchRoots = ((.searchRoots // []) + [$p] | unique)' --arg p "$p"
}

cmd_remove_root() {
  local p="${1:-}"
  if [ -z "$p" ]; then echo "Error: remove-root requires a path." >&2; exit 2; fi
  apply_jq '.searchRoots = ((.searchRoots // []) - [$p])' --arg p "$p"
}

cmd_add_block() {
  local p="${1:-}"
  if [ -z "$p" ]; then echo "Error: add-block requires a path." >&2; exit 2; fi
  apply_jq '.blocklist = ((.blocklist // []) + [$p] | unique)' --arg p "$p"
}

cmd_remove_block() {
  local p="${1:-}"
  if [ -z "$p" ]; then echo "Error: remove-block requires a path." >&2; exit 2; fi
  apply_jq '.blocklist = ((.blocklist // []) - [$p])' --arg p "$p"
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift || true
  case "$sub" in
    init)         cmd_init "$@" ;;
    show)         cmd_show "$@" ;;
    roots)        cmd_roots "$@" ;;
    blocklist)    cmd_blocklist "$@" ;;
    add-root)     cmd_add_root "$@" ;;
    remove-root)  cmd_remove_root "$@" ;;
    add-block)    cmd_add_block "$@" ;;
    remove-block) cmd_remove_block "$@" ;;
    ""|-h|--help|help) usage; [ "$sub" = "" ] && exit 2 || exit 0 ;;
    *) echo "Error: unknown subcommand '$sub'." >&2; usage; exit 2 ;;
  esac
}

main "$@"
