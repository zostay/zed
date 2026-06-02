#!/usr/bin/env bash
#
# maintenance-monitor.sh — lifecycle manager for the observability web app.
#
# Controls the Python stdlib HTTP server (app/server.py) that serves the
# maintenance observability UI. Single-instance: enforced via a liveness check
# on monitor.pid. The server itself owns port probing and writes the actual
# bound port to monitor.port; this script only reads it.
#
# Subcommands:
#   start [--headless] [--port N] [--no-open]  — start (or attach to) the server
#   stop                                        — stop the running server (idempotent)
#   status                                      — print running/stopped, PID, port, URL
#   url                                         — print URL if running, else exit 1
#   restart                                     — stop then start
#

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/maintenance-common.sh"

# Default starting port; the server probes upward from here if it is busy.
DEFAULT_PORT=7373

usage() {
  cat >&2 <<'EOF'
Usage: maintenance-monitor.sh <subcommand> [options]

Subcommands:
  start [--headless] [--port N] [--no-open]  Start (or attach to) the web app.
  stop                                        Stop the running web app (idempotent).
  status                                      Print running/stopped, PID, port, URL.
  url                                         Print the URL if running, else exit 1.
  restart                                     Stop then start.
EOF
}

# --- helpers ---------------------------------------------------------------

# Path helpers (resolved against the data dir).
monitor_pid_path()  { echo "$(mtnc_data_dir)/monitor.pid"; }
monitor_port_path() { echo "$(mtnc_data_dir)/monitor.port"; }
monitor_log_path()  { echo "$(mtnc_data_dir)/monitor.log"; }

# Echo the PID recorded in monitor.pid (empty if no/empty file).
read_pid() {
  local pid_file
  pid_file="$(monitor_pid_path)"
  if [ -s "$pid_file" ]; then
    head -n1 "$pid_file" | tr -d '[:space:]'
  fi
}

# Echo the port recorded in monitor.port (empty if no/empty file).
read_port() {
  local port_file
  port_file="$(monitor_port_path)"
  if [ -s "$port_file" ]; then
    head -n1 "$port_file" | tr -d '[:space:]'
  fi
}

# Return 0 if the given PID is a live process.
pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Return 0 if the monitor is currently running (pid file present + alive).
is_running() {
  local pid
  pid="$(read_pid)"
  pid_alive "$pid"
}

# Echo the URL for the current bound port (empty if no port recorded).
monitor_url() {
  local port
  port="$(read_port)"
  if [ -n "$port" ]; then
    echo "http://127.0.0.1:${port}"
  fi
}

# Open a URL in the default browser, trying platform-specific launchers.
# Any failure is ignored — we never want browser launch to fail the command.
open_browser() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v start >/dev/null 2>&1; then
    start "$url" >/dev/null 2>&1 || true
  fi
  return 0
}

# Remove the pid/port state files.
clear_state() {
  rm -f "$(monitor_pid_path)" "$(monitor_port_path)"
}

# --- subcommands -----------------------------------------------------------

cmd_start() {
  local headless=false
  local no_open=false
  local start_port="$DEFAULT_PORT"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --headless) headless=true; shift ;;
      --no-open)  no_open=true; shift ;;
      --port)
        if [ "$#" -lt 2 ]; then
          echo "Error: --port requires a value." >&2
          exit 2
        fi
        start_port="$2"; shift 2 ;;
      --port=*)   start_port="${1#--port=}"; shift ;;
      *)
        echo "Error: unknown option for start: $1" >&2
        usage
        exit 2 ;;
    esac
  done

  # Decide whether to open a browser at all.
  local do_open=true
  if [ "$headless" = true ] || [ "$no_open" = true ]; then
    do_open=false
  fi

  # If already running, attach to it: print URL, optionally open, exit.
  if is_running; then
    local url
    url="$(monitor_url)"
    if [ -n "$url" ]; then
      echo "$url"
      if [ "$do_open" = true ]; then
        open_browser "$url"
      fi
    else
      echo "Monitor is running (PID $(read_pid)) but no port recorded yet." >&2
    fi
    return 0
  fi

  # Not running (or stale state) — clean up any leftover state and launch.
  clear_state

  local data_dir db_path pid_file port_file log_file server
  data_dir="$(mtnc_ensure_data_dir)"
  db_path="$(mtnc_db_path)"
  pid_file="$(monitor_pid_path)"
  port_file="$(monitor_port_path)"
  log_file="$(monitor_log_path)"
  server="${CLAUDE_PLUGIN_ROOT:-}/app/server.py"

  mtnc_require python3

  if [ ! -f "$server" ]; then
    echo "Error: server not found at ${server}." >&2
    echo "Is CLAUDE_PLUGIN_ROOT set correctly?" >&2
    exit 1
  fi

  # Launch the server detached so it survives this shell. The server probes
  # for a free port starting at --port and writes the actual port to
  # --port-file and its own PID to --pid-file.
  nohup python3 "$server" \
    --port "$start_port" \
    --db "$db_path" \
    --port-file "$port_file" \
    --pid-file "$pid_file" \
    >> "$log_file" 2>&1 &
  disown || true

  # Poll until the server records its bound port (or we time out).
  # 20 iterations * 0.5s = ~10s timeout, using integer iteration counting.
  local i=0
  local max_iters=20
  local port=""
  while [ "$i" -lt "$max_iters" ]; do
    port="$(read_port)"
    if [ -n "$port" ]; then
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done

  if [ -z "$port" ]; then
    echo "Error: web app did not report a port within 10s." >&2
    echo "Check the log at ${log_file}." >&2
    exit 1
  fi

  local url="http://127.0.0.1:${port}"
  echo "$url"
  if [ "$do_open" = true ]; then
    open_browser "$url"
  fi
}

cmd_stop() {
  local pid
  pid="$(read_pid)"

  if ! pid_alive "$pid"; then
    # Not running — still clean up any stale state. Idempotent.
    clear_state
    echo "Monitor not running."
    return 0
  fi

  # Ask politely first.
  kill -TERM "$pid" 2>/dev/null || true

  # Wait up to a short grace period (~5s) for it to exit.
  local i=0
  while [ "$i" -lt 10 ] && pid_alive "$pid"; do
    sleep 0.5
    i=$((i + 1))
  done

  # Force-kill if still alive.
  if pid_alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi

  clear_state
  echo "Monitor stopped (PID ${pid})."
}

cmd_status() {
  if is_running; then
    local pid port url
    pid="$(read_pid)"
    port="$(read_port)"
    url="$(monitor_url)"
    echo "Status: running"
    echo "PID:    ${pid}"
    echo "Port:   ${port:-unknown}"
    echo "URL:    ${url:-unknown}"
  else
    echo "Status: stopped"
  fi
}

cmd_url() {
  if is_running; then
    local url
    url="$(monitor_url)"
    if [ -n "$url" ]; then
      echo "$url"
      return 0
    fi
  fi
  return 1
}

cmd_restart() {
  cmd_stop
  cmd_start "$@"
}

# --- dispatch --------------------------------------------------------------

main() {
  if [ "$#" -lt 1 ]; then
    usage
    exit 2
  fi

  local sub="$1"
  shift

  case "$sub" in
    start)   cmd_start "$@" ;;
    stop)    cmd_stop "$@" ;;
    status)  cmd_status "$@" ;;
    url)     cmd_url "$@" ;;
    restart) cmd_restart "$@" ;;
    *)
      echo "Error: unknown subcommand: ${sub}" >&2
      usage
      exit 2 ;;
  esac
}

main "$@"
