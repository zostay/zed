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
#   add-project-issue --run R [--job J] --project N [--repo OWNER/REPO]
#                     --kind issue|pr --number N --title T --url U
#                     [--state S] [--author A] [--labels L] [--age-days D]
#                     [--triage T] [--rank N] [--updated-at TS]
#       Record one cursorily-triaged GitHub issue/PR for a project. Prints the
#       row id. INSERT OR REPLACE on UNIQUE(run_id,project_name,kind,number), so
#       re-triaging a project inside one run updates instead of duplicating.
#   add-project-issues --run R [--job J] --project N [--repo OWNER/REPO]
#                      --file PATH
#       Batch form: PATH is JSONL or a JSON array of objects with the per-item
#       keys kind, number, title, url, state, author, labels, age_days, triage,
#       rank, updated_at. Prints one row id per line. An item that fails
#       validation is warned about on stderr and skipped; the rest still land.
#       A failed *database write* is different: it exits non-zero with a count,
#       so a mis-threaded --job or an unwritable DB never looks like success.
#   list-project-issues [--run R] [--project N] [--limit N]
#       Print triaged items as JSONL ordered by (rank ASC, age_days DESC,
#       id ASC) — lowest rank is most deserving of attention.

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
  add-project-issue   --run R [--job J] --project N [--repo OWNER/REPO]
                      --kind issue|pr --number N --title T --url U
                      [--state S] [--author A] [--labels L] [--age-days D]
                      [--triage T] [--rank N] [--updated-at TS]
  add-project-issues  --run R [--job J] --project N [--repo OWNER/REPO] --file PATH
  list-project-issues [--run R] [--project N] [--limit N]
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

# Warn (to stderr, non-fatally) when a summary that is supposed to record what
# happened is blank or whitespace-only. A blank summary almost always means the
# caller's redirect silently produced nothing — e.g. `printf ... > "$(mktemp)"`
# under zsh `noclobber`, where `>` refuses to overwrite the file mktemp already
# created. Surfacing it here makes that bug obvious instead of recording an
# empty summary and reporting success. Non-fatal: the row is still written, but
# the operator sees the warning.
warn_if_blank_summary() {
  local label="$1" text="$2"
  if [ -z "${text//[$' \t\r\n']/}" ]; then
    printf 'Warning: %s summary is empty or whitespace-only; recording it anyway.\n' "$label" >&2
  fi
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
  [ "$have_summary" -eq 1 ] && warn_if_blank_summary "job #$job" "$summary"

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
  [ "$have_summary" -eq 1 ] && warn_if_blank_summary "run #$run" "$summary"

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

# ---- GitHub triage --------------------------------------------------------

# Non-fatal integer test. require_int dies, which is right for a single-item
# write but wrong for a batch: one malformed item must not take the other four
# down with it, so the batch path tests with this and skips instead.
pi_is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# As above, but tolerates a leading '-'. Only rank uses it: rank is advisory
# ordering that gets clamped into 0..100, so a caller reaching for -1 to shout
# "most urgent" should have its row stored at 0, not dropped.
pi_is_signed_int() {
  case "${1:-}" in
    ''|'-') return 1 ;;
    -*) pi_is_int "${1#-}" ;;
    *) pi_is_int "$1" ;;
  esac
}

# Complain about an invalid triage item. Strict (the single-item subcommand)
# makes it fatal; otherwise it is a warning and the caller skips the row.
# Always returns non-zero when it returns at all, so callers can write
# `pi_reject ... || return 1` without tripping set -e.
#
# Status contract for pi_upsert, which the batch caller depends on:
#   0  row written
#   1  item rejected by validation (skipped; the batch keeps going, exits 0)
#   3  the database write itself failed (the batch counts it and exits non-zero)
# A malformed item is the caller's data problem and stays non-fatal; a failed
# write means the snapshot silently did not land and must never look like
# success.
pi_reject() {
  local strict="$1" msg="$2"
  [ "$strict" -eq 1 ] && die "$msg" 2
  printf 'Warning: %s; skipping item.\n' "$msg" >&2
  return 1
}

# Validate one triaged GitHub item and INSERT OR REPLACE it, printing the id of
# the row that now exists. Positional arguments, in order:
#   1 strict  2 label  3 run  4 job  5 project  6 repo  7 kind  8 number
#   9 title  10 url  11 state  12 author  13 labels  14 age_days  15 triage
#  16 rank  17 updated_at
# (Positional because bash has nothing better; the option loops below are the
# readable surface and this is the shared tail they both funnel into.)
pi_upsert() {
  local strict="$1" label="$2" run="$3" job="$4" project="$5" repo="$6" \
        kind="$7" number="$8" title="$9" url="${10}" state="${11}" \
        author="${12}" labels="${13}" age_days="${14}" triage="${15}" \
        rank="${16}" updated_at="${17}"

  [ -n "$project" ] || pi_reject "$strict" "$label: project name is required" || return 1
  [ -n "$title" ]   || pi_reject "$strict" "$label: title is required" || return 1
  case "$kind" in
    issue|pr) ;;
    *) pi_reject "$strict" "$label: kind must be issue or pr (got: '$kind')" || return 1 ;;
  esac
  pi_is_int "$number" || pi_reject "$strict" "$label: number must be a non-negative integer (got: '$number')" || return 1
  # The app turns url straight into an href, so only https:// ever gets stored;
  # javascript:/data:/http:// links are rejected here rather than sanitized in
  # three different readers.
  case "$url" in
    https://*) ;;
    *) pi_reject "$strict" "$label: url must start with https:// (got: '$url')" || return 1 ;;
  esac
  if [ -n "$age_days" ]; then
    pi_is_int "$age_days" || pi_reject "$strict" "$label: age-days must be a non-negative integer (got: '$age_days')" || return 1
  fi
  # Rank is advisory ordering, not data: an out-of-range value clamps to 0..100
  # rather than losing the row — at either end, so a negative rank stores as 0.
  if [ -n "$rank" ]; then
    pi_is_signed_int "$rank" || pi_reject "$strict" "$label: rank must be an integer (got: '$rank')" || return 1
    [ "$rank" -lt 0 ]   && rank=0
    [ "$rank" -gt 100 ] && rank=100
  else
    rank=50
  fi

  local now now_e project_e title_e url_e kind_e
  now="$(mtnc_now)"
  now_e="$(mtnc_sql_escape "$now")"
  project_e="$(mtnc_sql_escape "$project")"
  title_e="$(mtnc_sql_escape "$title")"
  url_e="$(mtnc_sql_escape "$url")"
  kind_e="$(mtnc_sql_escape "$kind")"

  local job_v repo_v state_v author_v labels_v age_v triage_v updated_v
  if [ -n "$job" ];        then job_v="$job";                                    else job_v="NULL";     fi
  if [ -n "$repo" ];       then repo_v="'$(mtnc_sql_escape "$repo")'";           else repo_v="NULL";    fi
  if [ -n "$state" ];      then state_v="'$(mtnc_sql_escape "$state")'";         else state_v="NULL";   fi
  if [ -n "$author" ];     then author_v="'$(mtnc_sql_escape "$author")'";       else author_v="NULL";  fi
  if [ -n "$labels" ];     then labels_v="'$(mtnc_sql_escape "$labels")'";       else labels_v="NULL";  fi
  if [ -n "$age_days" ];   then age_v="$age_days";                               else age_v="NULL";     fi
  if [ -n "$triage" ];     then triage_v="'$(mtnc_sql_escape "$triage")'";       else triage_v="NULL";  fi
  if [ -n "$updated_at" ]; then updated_v="'$(mtnc_sql_escape "$updated_at")'";  else updated_v="NULL"; fi

  # INSERT OR REPLACE deletes the conflicting row and inserts a fresh one, which
  # mints a new id — so read the id back by the UNIQUE key instead of trusting
  # last_insert_rowid() to describe the row the caller asked about.
  #
  # The write is captured rather than streamed so a sqlite3 failure (a foreign
  # key violation from a mis-threaded --job, a read-only database) can be told
  # apart from a validation reject and reported as status 3. Without this the
  # batch loop's `|| continue` swallowed every failed write and the subcommand
  # still exited 0, losing a project's whole triage snapshot silently.
  local ids=""
  if ! ids="$(db_exec <<SQL
INSERT OR REPLACE INTO project_issues
  (run_id, job_id, project_name, repo, kind, number, title, url, state, author,
   labels, age_days, triage, rank, updated_at, created_at)
VALUES ($run, $job_v, '$project_e', $repo_v, '$kind_e', $number, '$title_e', '$url_e',
        $state_v, $author_v, $labels_v, $age_v, $triage_v, $rank, $updated_v, '$now_e');
SELECT id FROM project_issues
 WHERE run_id=$run AND project_name='$project_e' AND kind='$kind_e' AND number=$number;
SQL
  )"; then
    [ "$strict" -eq 1 ] && die "$label: database write failed" 1
    printf 'Error: %s: database write failed.\n' "$label" >&2
    return 3
  fi
  # A write that sqlite3 reported as fine but that left no row behind is still a
  # failure from the caller's point of view — say so rather than printing blank.
  if [ -z "$ids" ]; then
    [ "$strict" -eq 1 ] && die "$label: database write recorded no row" 1
    printf 'Error: %s: database write recorded no row.\n' "$label" >&2
    return 3
  fi
  printf '%s\n' "$ids"
}

cmd_add_project_issue() {
  local run="" job="" project="" repo="" kind="" number="" title="" url="" \
        state="" author="" labels="" age_days="" triage="" rank="" updated_at=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)        run="$2";        shift 2 ;;
      --job)        job="$2";        shift 2 ;;
      --project)    project="$2";    shift 2 ;;
      --repo)       repo="$2";       shift 2 ;;
      --kind)       kind="$2";       shift 2 ;;
      --number)     number="$2";     shift 2 ;;
      --title)      title="$2";      shift 2 ;;
      --url)        url="$2";        shift 2 ;;
      --state)      state="$2";      shift 2 ;;
      --author)     author="$2";     shift 2 ;;
      --labels)     labels="$2";     shift 2 ;;
      --age-days)   age_days="$2";   shift 2 ;;
      --triage)     triage="$2";     shift 2 ;;
      --rank)       rank="$2";       shift 2 ;;
      --updated-at) updated_at="$2"; shift 2 ;;
      *) die "add-project-issue: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]     || die "add-project-issue: --run is required"
  [ -n "$project" ] || die "add-project-issue: --project is required"
  [ -n "$kind" ]    || die "add-project-issue: --kind is required"
  [ -n "$number" ]  || die "add-project-issue: --number is required"
  [ -n "$title" ]   || die "add-project-issue: --title is required"
  [ -n "$url" ]     || die "add-project-issue: --url is required"
  require_int --run "$run"
  [ -n "$job" ] && require_int --job "$job"

  pi_upsert 1 "add-project-issue" "$run" "$job" "$project" "$repo" "$kind" \
    "$number" "$title" "$url" "$state" "$author" "$labels" "$age_days" \
    "$triage" "$rank" "$updated_at"
}

# Pull one key out of a compact JSON object, printing '' for a missing or null
# value. tostring keeps the numeric keys (number, age_days, rank) as plain
# digits so they can go straight into SQL after pi_is_int.
pi_field() {
  printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // "" | tostring'
}

# labels and author are the two keys a caller is most likely to hand over
# straight from `gh --json`, where they arrive as an array of {name} objects and
# a {login} object rather than as strings. Flatten those shapes here so the
# skill does not have to reshape them first.
pi_field_labels() {
  printf '%s' "$1" | jq -r '
    if (.labels | type) == "array"
    then (.labels | map(if type == "object" then (.name // tostring) else tostring end) | join(","))
    else (.labels // "" | tostring) end'
}

pi_field_author() {
  printf '%s' "$1" | jq -r '
    if (.author | type) == "object"
    then (.author.login // .author.name // "")
    else (.author // "" | tostring) end'
}

cmd_add_project_issues() {
  local run="" job="" project="" repo="" file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)     run="$2";     shift 2 ;;
      --job)     job="$2";     shift 2 ;;
      --project) project="$2"; shift 2 ;;
      --repo)    repo="$2";    shift 2 ;;
      --file)    file="$2";    shift 2 ;;
      *) die "add-project-issues: unknown option: $1" 2 ;;
    esac
  done
  [ -n "$run" ]     || die "add-project-issues: --run is required"
  [ -n "$project" ] || die "add-project-issues: --project is required"
  [ -n "$file" ]    || die "add-project-issues: --file is required"
  require_int --run "$run"
  [ -n "$job" ] && require_int --job "$job"
  [ -f "$file" ] || die "add-project-issues: file not found: $file"
  mtnc_require jq

  # Normalize both accepted shapes to one compact object per line. A JSON array
  # is exploded; a JSONL stream passes through as-is. If the file will not parse
  # as a whole (typically one bad JSONL line poisoning the stream), fall back to
  # parsing line by line so the good lines still get recorded.
  local items="" line one first_char jq_err
  first_char="$(awk 'NF { sub(/^[[:space:]]+/, ""); print substr($0, 1, 1); exit }' "$file")"
  if ! items="$(jq -c 'if type == "array" then .[] else . end' < "$file" 2>/dev/null)"; then
    # The line-by-line fallback only makes sense for JSONL, where a line *is* an
    # item. In a JSON array every line is a fragment, so walking it line by line
    # discards the well-formed elements and misreports them as unparseable —
    # fail loudly instead, so the caller knows nothing landed.
    if [ "$first_char" = "[" ]; then
      jq_err="$(jq -c '.' < "$file" 2>&1 >/dev/null || true)"
      die "add-project-issues: $file is a JSON array that does not parse; nothing was recorded${jq_err:+ (${jq_err})}" 2
    fi
    items=""
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "${line//[$' \t\r\n']/}" ] || continue
      if one="$(printf '%s\n' "$line" | jq -c 'if type == "array" then .[] else . end' 2>/dev/null)"; then
        items="${items}${one}"$'\n'
      else
        printf 'Warning: add-project-issues: unparseable JSON line; skipping item: %s\n' "$line" >&2
      fi
    done < "$file"
  fi

  local idx=0 written=0 hard_failures=0 rc=0
  local item kind number title url state author labels age_days triage \
        rank updated_at item_project item_repo
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    idx=$((idx + 1))
    if ! printf '%s' "$item" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf 'Warning: add-project-issues: item %d is not a JSON object; skipping item.\n' "$idx" >&2
      continue
    fi
    # Per-item values win over the flags; the flags are the per-project default.
    item_project="$(pi_field "$item" project_name)"
    [ -n "$item_project" ] || item_project="$project"
    item_repo="$(pi_field "$item" repo)"
    [ -n "$item_repo" ] || item_repo="$repo"
    kind="$(pi_field "$item" kind)"
    [ -n "$kind" ] || kind="issue"
    number="$(pi_field "$item" number)"
    title="$(pi_field "$item" title)"
    url="$(pi_field "$item" url)"
    state="$(pi_field "$item" state)"
    author="$(pi_field_author "$item")"
    labels="$(pi_field_labels "$item")"
    age_days="$(pi_field "$item" age_days)"
    triage="$(pi_field "$item" triage)"
    rank="$(pi_field "$item" rank)"
    updated_at="$(pi_field "$item" updated_at)"

    # Non-strict: pi_upsert warns and returns non-zero on a bad item, and the
    # `||` keeps set -e from ending the batch there. Status 1 is a validation
    # reject (skip and keep going); status 3 is a failed database write, which
    # must not be swallowed — those are counted and turn into a non-zero exit.
    rc=0
    pi_upsert 0 "add-project-issues: item $idx" "$run" "$job" "$item_project" \
      "$item_repo" "$kind" "$number" "$title" "$url" "$state" "$author" \
      "$labels" "$age_days" "$triage" "$rank" "$updated_at" || rc=$?
    if [ "$rc" -eq 0 ]; then
      written=$((written + 1))
    elif [ "$rc" -ge 3 ]; then
      hard_failures=$((hard_failures + 1))
    fi
  done <<< "$items"

  if [ "$hard_failures" -gt 0 ]; then
    die "add-project-issues: $hard_failures of $idx item(s) failed to write to the database ($written written)" 1
  fi
}

cmd_list_project_issues() {
  local run="" project="" limit=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)     run="$2";     shift 2 ;;
      --project) project="$2"; shift 2 ;;
      --limit)   limit="$2";   shift 2 ;;
      *) die "list-project-issues: unknown option: $1" 2 ;;
    esac
  done
  local where=""
  if [ -n "$run" ]; then
    require_int --run "$run"
    where="WHERE run_id=$run"
  fi
  if [ -n "$project" ]; then
    local project_e
    project_e="$(mtnc_sql_escape "$project")"
    if [ -n "$where" ]; then where="$where AND project_name='$project_e'"; else where="WHERE project_name='$project_e'"; fi
  fi
  local limit_clause=""
  if [ -n "$limit" ]; then
    require_int --limit "$limit"
    limit_clause="LIMIT $limit"
  fi

  # rank ASC first: lower rank is more deserving of attention. Ties go to the
  # older item, which is what age_days DESC buys.
  db_exec <<SQL
SELECT json_object(
  'id', id, 'run_id', run_id, 'job_id', job_id,
  'project_name', project_name, 'repo', repo, 'kind', kind, 'number', number,
  'title', title, 'url', url, 'state', state, 'author', author,
  'labels', labels, 'age_days', age_days, 'triage', triage, 'rank', rank,
  'updated_at', updated_at, 'created_at', created_at
) FROM project_issues $where ORDER BY rank ASC, age_days DESC, id ASC $limit_clause;
SQL
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
  add-project-issue)   cmd_add_project_issue "$@" ;;
  add-project-issues)  cmd_add_project_issues "$@" ;;
  list-project-issues) cmd_list_project_issues "$@" ;;
  *)
    printf 'Error: unknown subcommand: %s\n' "$SUBCMD" >&2
    usage
    exit 2
    ;;
esac
