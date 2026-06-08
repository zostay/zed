#!/usr/bin/env bash
#
# Observability writer CLI for the maintenance skill.
#
# Records runs, jobs, and events into the SQLite observability database so the
# web app can show live maintenance activity. Every write opens sqlite3 with
# PRAGMA busy_timeout=10000 so concurrent subagent writers serialize safely
# (WAL mode is enabled by schema.sql). All string values are escaped via
# mtnc_sql_escape and all timestamps are generated with mtnc_now.
#
# Usage:
#   maintenance-db.sh [--db PATH] <subcommand> [options]
#
# Subcommands:
#   init
#       Ensure the data dir exists and create the DB from schema.sql
#       (idempotent). Prints the db path.
#   start-run --tag T [--mode M] [--options JSON] [--options-file PATH]
#       Insert a run. Prints the new run_id (bare integer) on stdout.
#   set-stage --run R --stage S
#       Update runs.stage.
#   add-job --run R --path P --name N [--skill S]
#       Insert a job (idempotent via INSERT OR IGNORE on UNIQUE(run_id,path)).
#       Prints the job_id (existing or new) on stdout.
#   start-job --job J
#       Set status='running', started_at=now.
#   finish-job --job J --status STATUS [--summary MD] [--summary-file PATH]
#                                      [--error MSG]
#       Set status (success|followup|failure|skipped), finished_at=now,
#       summary, error.
#   log --run R [--job J] [--level L] --message M
#       Insert an event. level defaults to info.
#   finish-run --run R --status STATUS [--summary MD] [--summary-file PATH]
#       Set status (completed|needs_followup|failed|cancelled), finished_at=now,
#       stage='done', summary.
#   add-followup --run R [--job J] [--project N] --title T [--detail D]
#       Open a followup ticket. Prints the new ticket number (bare integer).
#       Also logs a warn event so the ticket appears live in the activity feed.
#   update-followup --id ID --action ACTION --comment C
#       Append progress to a ticket. ACTION is update (comment only), done
#       (close completed), or nope (close as won't-do). Closing the last open
#       ticket of a needs_followup run flips that run to completed. Prints a
#       JSON object describing the resulting ticket + run state.
#   list-followups [--run R] [--status S]
#       Print followup tickets as JSONL (newest run first), optionally filtered
#       by run and/or status.
#   get-followup --id ID
#       Print one ticket as a JSON object including its comment timeline.

set -euo pipefail

# Guarantee the standard tool directories are reachable even when this script is
# launched from a stripped-down environment (e.g. a subshell whose PATH omits
# Homebrew). A minimal PATH can hide bash/dirname/sqlite3/jq/find/python3 and
# stall the whole sweep. Append so any ordering the caller set still wins.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

source "$(dirname "${BASH_SOURCE[0]}")/maintenance-common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_PATH="${SCRIPT_DIR}/schema.sql"

usage() {
  cat >&2 <<'EOF'
Usage: maintenance-db.sh [--db PATH] <subcommand> [options]

Subcommands:
  init
  start-run       --tag T [--mode M] [--options JSON] [--options-file PATH]
  set-stage       --run R --stage S
  add-job         --run R --path P --name N [--skill S]
  start-job       --job J
  finish-job      --job J --status STATUS [--summary MD] [--summary-file PATH] [--error MSG]
  log             --run R [--job J] [--level L] --message M
  finish-run      --run R --status STATUS [--summary MD] [--summary-file PATH]
  add-followup    --run R [--job J] [--project N] --title T [--detail D]
  update-followup --id ID --action update|done|nope --comment C
  list-followups  [--run R] [--status S]
  get-followup    --id ID
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Validate that a value is a non-negative integer. Row ids are produced by this
# script itself, but guarding them keeps a crafted --run/--job value (e.g.
# --run "1; DROP TABLE runs;--") from being spliced into SQL.
require_int() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a non-negative integer (got: '$2')" 2 ;;
  esac
}

# Read a file's full contents into a variable, or die if it is unreadable.
read_file() {
  local path="$1"
  [ -f "$path" ] || die "file not found: $path"
  cat -- "$path"
}

# Run sqlite3 against the database with busy_timeout, feeding the SQL on stdin.
# Usage: db_exec <<SQL ... SQL   (the caller supplies the statements)
# The busy_timeout PRAGMA emits its numeric result, so it is run with output
# redirected to /dev/null before stdout is restored for the caller's SQL.
db_exec() {
  sqlite3 "$DB" <<SQL
.output /dev/null
PRAGMA busy_timeout=10000;
PRAGMA foreign_keys=ON;
.output stdout
$(cat)
SQL
}

mtnc_require sqlite3

# ---- global option parsing: pull out an optional leading --db PATH ----------
DB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --db)
      [ "$#" -ge 2 ] || die "--db requires a value"
      DB="$2"
      shift 2
      ;;
    --db=*)
      DB="${1#--db=}"
      shift
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 1 ] || { usage; exit 2; }

SUBCMD="$1"
shift

if [ -z "$DB" ]; then
  DB="$(mtnc_db_path)"
fi

cmd_init() {
  local dir
  dir="$(mtnc_ensure_data_dir)"
  [ -f "$SCHEMA_PATH" ] || die "schema not found: $SCHEMA_PATH"
  # Applying the schema runs PRAGMA journal_mode=WAL, which emits 'wal'; send
  # all schema output to /dev/null so only the db path lands on stdout.
  sqlite3 "$DB" >/dev/null <<SQL
PRAGMA busy_timeout=10000;
$(cat -- "$SCHEMA_PATH")
SQL
  printf '%s\n' "$DB"
}

cmd_start_run() {
  local tag="" mode="" options="" options_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag)          tag="$2";          shift 2 ;;
      --mode)         mode="$2";         shift 2 ;;
      --options)      options="$2";      shift 2 ;;
      --options-file) options_file="$2"; shift 2 ;;
      *) die "start-run: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$tag" ] || die "start-run: --tag is required"
  if [ -n "$options_file" ]; then
    options="$(read_file "$options_file")"
  fi

  local now tag_e mode_v options_v
  now="$(mtnc_now)"
  tag_e="$(mtnc_sql_escape "$tag")"
  if [ -n "$mode" ]; then
    mode_v="'$(mtnc_sql_escape "$mode")'"
  else
    mode_v="NULL"
  fi
  if [ -n "$options" ]; then
    options_v="'$(mtnc_sql_escape "$options")'"
  else
    options_v="NULL"
  fi

  db_exec <<SQL
INSERT INTO runs (tag, mode, status, stage, started_at, options)
VALUES ('$tag_e', $mode_v, 'running', 'starting', '$(mtnc_sql_escape "$now")', $options_v);
SELECT last_insert_rowid();
SQL
}

cmd_set_stage() {
  local run="" stage=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)   run="$2";   shift 2 ;;
      --stage) stage="$2"; shift 2 ;;
      *) die "set-stage: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]   || die "set-stage: --run is required"
  [ -n "$stage" ] || die "set-stage: --stage is required"
  require_int --run "$run"

  db_exec <<SQL
UPDATE runs SET stage='$(mtnc_sql_escape "$stage")' WHERE id=$run;
SQL
}

cmd_add_job() {
  local run="" path="" name="" skill=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)   run="$2";   shift 2 ;;
      --path)  path="$2";  shift 2 ;;
      --name)  name="$2";  shift 2 ;;
      --skill) skill="$2"; shift 2 ;;
      *) die "add-job: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]  || die "add-job: --run is required"
  [ -n "$path" ] || die "add-job: --path is required"
  [ -n "$name" ] || die "add-job: --name is required"
  require_int --run "$run"

  local path_e name_e skill_v
  path_e="$(mtnc_sql_escape "$path")"
  name_e="$(mtnc_sql_escape "$name")"
  if [ -n "$skill" ]; then
    skill_v="'$(mtnc_sql_escape "$skill")'"
  else
    skill_v="NULL"
  fi

  # INSERT OR IGNORE keeps this idempotent on UNIQUE(run_id, project_path);
  # then look up the id (the new row's or the pre-existing one's).
  db_exec <<SQL
INSERT OR IGNORE INTO jobs (run_id, project_path, project_name, skill_name)
VALUES ($run, '$path_e', '$name_e', $skill_v);
SELECT id FROM jobs WHERE run_id=$run AND project_path='$path_e';
SQL
}

cmd_start_job() {
  local job=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job) job="$2"; shift 2 ;;
      *) die "start-job: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$job" ] || die "start-job: --job is required"
  require_int --job "$job"

  local now
  now="$(mtnc_now)"
  db_exec <<SQL
UPDATE jobs SET status='running', started_at='$(mtnc_sql_escape "$now")' WHERE id=$job;
SQL
}

cmd_finish_job() {
  local job="" status="" summary="" summary_file="" error="" have_summary=0 have_error=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job)          job="$2";                       shift 2 ;;
      --status)       status="$2";                    shift 2 ;;
      --summary)      summary="$2";   have_summary=1; shift 2 ;;
      --summary-file) summary_file="$2";              shift 2 ;;
      --error)        error="$2";     have_error=1;   shift 2 ;;
      *) die "finish-job: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$job" ]    || die "finish-job: --job is required"
  [ -n "$status" ] || die "finish-job: --status is required"
  require_int --job "$job"
  if [ -n "$summary_file" ]; then
    summary="$(read_file "$summary_file")"
    have_summary=1
  fi

  local now sets
  now="$(mtnc_now)"
  sets="status='$(mtnc_sql_escape "$status")', finished_at='$(mtnc_sql_escape "$now")'"
  if [ "$have_summary" -eq 1 ]; then
    sets="$sets, summary='$(mtnc_sql_escape "$summary")'"
  fi
  if [ "$have_error" -eq 1 ]; then
    sets="$sets, error='$(mtnc_sql_escape "$error")'"
  fi

  db_exec <<SQL
UPDATE jobs SET $sets WHERE id=$job;
SQL
}

cmd_log() {
  local run="" job="" level="info" message="" have_message=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)     run="$2";                     shift 2 ;;
      --job)     job="$2";                      shift 2 ;;
      --level)   level="$2";                    shift 2 ;;
      --message) message="$2"; have_message=1;  shift 2 ;;
      *) die "log: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]          || die "log: --run is required"
  [ "$have_message" -eq 1 ] || die "log: --message is required"
  require_int --run "$run"
  [ -n "$job" ] && require_int --job "$job"

  local now job_v
  now="$(mtnc_now)"
  if [ -n "$job" ]; then
    job_v="$job"
  else
    job_v="NULL"
  fi

  db_exec <<SQL
INSERT INTO events (run_id, job_id, ts, level, message)
VALUES ($run, $job_v, '$(mtnc_sql_escape "$now")', '$(mtnc_sql_escape "$level")', '$(mtnc_sql_escape "$message")');
SQL
}

cmd_finish_run() {
  local run="" status="" summary="" summary_file="" have_summary=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)          run="$2";                     shift 2 ;;
      --status)       status="$2";                  shift 2 ;;
      --summary)      summary="$2"; have_summary=1; shift 2 ;;
      --summary-file) summary_file="$2";            shift 2 ;;
      *) die "finish-run: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]    || die "finish-run: --run is required"
  [ -n "$status" ] || die "finish-run: --status is required"
  require_int --run "$run"
  if [ -n "$summary_file" ]; then
    summary="$(read_file "$summary_file")"
    have_summary=1
  fi

  local now sets
  now="$(mtnc_now)"
  sets="status='$(mtnc_sql_escape "$status")', finished_at='$(mtnc_sql_escape "$now")', stage='done'"
  if [ "$have_summary" -eq 1 ]; then
    sets="$sets, summary='$(mtnc_sql_escape "$summary")'"
  fi

  db_exec <<SQL
UPDATE runs SET $sets WHERE id=$run;
SQL
}

cmd_add_followup() {
  local run="" job="" project="" title="" detail="" have_detail=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)     run="$2";                   shift 2 ;;
      --job)     job="$2";                    shift 2 ;;
      --project) project="$2";                shift 2 ;;
      --title)   title="$2";                  shift 2 ;;
      --detail)  detail="$2"; have_detail=1;  shift 2 ;;
      *) die "add-followup: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]   || die "add-followup: --run is required"
  [ -n "$title" ] || die "add-followup: --title is required"
  require_int --run "$run"
  [ -n "$job" ] && require_int --job "$job"

  local now title_e job_v project_v detail_v
  now="$(mtnc_now)"
  title_e="$(mtnc_sql_escape "$title")"
  if [ -n "$job" ]; then job_v="$job"; else job_v="NULL"; fi
  if [ -n "$project" ]; then project_v="'$(mtnc_sql_escape "$project")'"; else project_v="NULL"; fi
  if [ "$have_detail" -eq 1 ]; then detail_v="'$(mtnc_sql_escape "$detail")'"; else detail_v="NULL"; fi

  # Insert the ticket and capture its number.
  local id
  id="$(db_exec <<SQL
INSERT INTO followups (run_id, job_id, project_name, title, detail, status, created_at)
VALUES ($run, $job_v, $project_v, '$title_e', $detail_v, 'open', '$(mtnc_sql_escape "$now")');
SELECT last_insert_rowid();
SQL
)"
  require_int "internal ticket id" "$id"

  # Opening comment (detail if given, else the title) + a live activity event.
  local open_comment open_comment_e ev_msg_e
  if [ "$have_detail" -eq 1 ]; then open_comment="$detail"; else open_comment="$title"; fi
  open_comment_e="$(mtnc_sql_escape "$open_comment")"
  ev_msg_e="$(mtnc_sql_escape "Followup #${id} opened: ${title}")"
  db_exec <<SQL
INSERT INTO followup_comments (followup_id, ts, action, comment)
VALUES ($id, '$(mtnc_sql_escape "$now")', 'opened', '$open_comment_e');
INSERT INTO events (run_id, job_id, ts, level, message)
VALUES ($run, $job_v, '$(mtnc_sql_escape "$now")', 'warn', '$ev_msg_e');
SQL
  printf '%s\n' "$id"
}

cmd_update_followup() {
  local id="" action="" comment="" have_comment=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)      id="$2";                       shift 2 ;;
      --action)  action="$2";                   shift 2 ;;
      --comment) comment="$2"; have_comment=1;  shift 2 ;;
      *) die "update-followup: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$id" ]     || die "update-followup: --id is required"
  [ -n "$action" ] || die "update-followup: --action is required"
  [ "$have_comment" -eq 1 ] || die "update-followup: --comment is required"
  require_int --id "$id"
  case "$action" in
    update|done|nope) ;;
    *) die "update-followup: --action must be one of update|done|nope (got: '$action')" 2 ;;
  esac

  # Look up the ticket's run and current status.
  local row run_id cur_status
  row="$(db_exec <<SQL
SELECT run_id || '|' || status FROM followups WHERE id=$id;
SQL
)"
  [ -n "$row" ] || die "update-followup: no followup ticket #$id"
  run_id="${row%%|*}"
  cur_status="${row##*|}"

  local now now_e comment_e sets
  now="$(mtnc_now)"
  now_e="$(mtnc_sql_escape "$now")"
  comment_e="$(mtnc_sql_escape "$comment")"
  sets="updated_at='$now_e'"
  case "$action" in
    done) sets="$sets, status='done', closed_at='$now_e'" ;;
    nope) sets="$sets, status='wontdo', closed_at='$now_e'" ;;
  esac

  db_exec <<SQL
UPDATE followups SET $sets WHERE id=$id;
INSERT INTO followup_comments (followup_id, ts, action, comment)
VALUES ($id, '$now_e', '$(mtnc_sql_escape "$action")', '$comment_e');
SQL

  # When a close resolves the last open ticket of a needs_followup run, the run
  # graduates to completed.
  local run_completed="false"
  if [ "$action" != "update" ]; then
    local open_count run_status
    open_count="$(db_exec <<SQL
SELECT COUNT(*) FROM followups WHERE run_id=$run_id AND status='open';
SQL
)"
    run_status="$(db_exec <<SQL
SELECT status FROM runs WHERE id=$run_id;
SQL
)"
    if [ "$open_count" = "0" ] && [ "$run_status" = "needs_followup" ]; then
      db_exec <<SQL
UPDATE runs SET status='completed' WHERE id=$run_id;
INSERT INTO events (run_id, ts, level, message)
VALUES ($run_id, '$now_e', 'success', 'All followups resolved; run marked completed.');
SQL
      run_completed="true"
    fi
  fi

  # Emit a small JSON receipt for the caller (the maint-followup skill).
  db_exec <<SQL
SELECT json_object(
  'ticket', $id,
  'status', (SELECT status FROM followups WHERE id=$id),
  'run_id', $run_id,
  'open_remaining', (SELECT COUNT(*) FROM followups WHERE run_id=$run_id AND status='open'),
  'run_completed', json('$run_completed')
);
SQL
}

cmd_list_followups() {
  local run="" status=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)    run="$2";    shift 2 ;;
      --status) status="$2"; shift 2 ;;
      *) die "list-followups: unknown option: $1" 2 ;;
    esac
  done
  local where=""
  if [ -n "$run" ]; then
    require_int --run "$run"
    where="WHERE run_id=$run"
  fi
  if [ -n "$status" ]; then
    local status_e
    status_e="$(mtnc_sql_escape "$status")"
    if [ -n "$where" ]; then where="$where AND status='$status_e'"; else where="WHERE status='$status_e'"; fi
  fi

  db_exec <<SQL
SELECT json_object(
  'ticket', id, 'run_id', run_id, 'job_id', job_id,
  'project_name', project_name, 'title', title, 'status', status,
  'created_at', created_at, 'closed_at', closed_at
) FROM followups $where ORDER BY run_id DESC, id ASC;
SQL
}

cmd_get_followup() {
  local id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      *) die "get-followup: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$id" ] || die "get-followup: --id is required"
  require_int --id "$id"

  local out
  out="$(db_exec <<SQL
SELECT json_object(
  'ticket', f.id, 'run_id', f.run_id, 'job_id', f.job_id,
  'project_name', f.project_name, 'title', f.title, 'detail', f.detail,
  'status', f.status, 'created_at', f.created_at,
  'updated_at', f.updated_at, 'closed_at', f.closed_at,
  'comments', (
    SELECT json_group_array(json_object('ts', ts, 'action', action, 'comment', comment))
    FROM (SELECT * FROM followup_comments WHERE followup_id=f.id ORDER BY id)
  )
) FROM followups f WHERE f.id=$id;
SQL
)"
  [ -n "$out" ] || die "get-followup: no followup ticket #$id"
  printf '%s\n' "$out"
}

case "$SUBCMD" in
  init)            cmd_init "$@" ;;
  start-run)       cmd_start_run "$@" ;;
  set-stage)       cmd_set_stage "$@" ;;
  add-job)         cmd_add_job "$@" ;;
  start-job)       cmd_start_job "$@" ;;
  finish-job)      cmd_finish_job "$@" ;;
  log)             cmd_log "$@" ;;
  finish-run)      cmd_finish_run "$@" ;;
  add-followup)    cmd_add_followup "$@" ;;
  update-followup) cmd_update_followup "$@" ;;
  list-followups)  cmd_list_followups "$@" ;;
  get-followup)    cmd_get_followup "$@" ;;
  *)
    printf 'Error: unknown subcommand: %s\n' "$SUBCMD" >&2
    usage
    exit 2
    ;;
esac
