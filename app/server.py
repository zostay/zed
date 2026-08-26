#!/usr/bin/env python3
"""
Observability web app for the zed `maintenance` skill.

Single-file Python 3 standard-library HTTP server. Serves a small static UI and a
JSON + SSE API backed by a read-only SQLite connection to the maintenance
`observability.db`.

Design notes:
- ThreadingHTTPServer so a long-lived SSE stream never blocks other requests.
- A fresh read-only SQLite connection per request (simplest + thread-safe). The
  writers (subagents) use WAL mode, so readers never block them and vice-versa.
- Exactly one write surface: POST /api/runs/<id>/interactive/<task>/start, which
  records that the human clicked Start on an interactive task. The app cannot
  dispatch anything itself — it has no channel to the Claude Code session — so it
  writes the intent as a row and the orchestrator polls for it. Everything else
  stays read-only.
- Resilient to a missing/locked DB: API endpoints degrade to empty, well-formed
  payloads instead of 500s where reasonable.

CLI:
  --port      starting TCP port (default 7373); probes upward +50 if busy
  --db        path to the sqlite database (required)
  --port-file path to write the actually-bound port to
  --pid-file  path to write this process's pid to
  --host      bind host (default 127.0.0.1)
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".map": "application/json; charset=utf-8",
}

JOB_STATUSES = ("pending", "running", "success", "followup", "failure",
                "skipped", "awaiting_interactive")
FOLLOWUP_STATUSES = ("open", "done", "wontdo")
INTERACTIVE_STATUSES = ("discovered", "requested", "started", "done", "abandoned")
# The three states in which an interactive task still owes the run something, and
# so keeps it out of a terminal status.
INTERACTIVE_OPEN = ("discovered", "requested", "started")

# Routing patterns
RE_RUN = re.compile(r"^/api/runs/(\d+)$")
RE_RUN_EVENTS = re.compile(r"^/api/runs/(\d+)/events$")
RE_STREAM = re.compile(r"^/api/stream/(\d+)$")
RE_TASK_START = re.compile(r"^/api/runs/(\d+)/interactive/(\d+)/start$")


# --------------------------------------------------------------------------- #
# Database access
# --------------------------------------------------------------------------- #

class DB:
    """Holds the db path and hands out fresh read-only connections per request."""

    def __init__(self, path):
        self.path = path
        # Build a file: URI so we can open read-only. Encode characters that the
        # SQLite URI parser treats specially.
        abspath = os.path.abspath(path)
        # On POSIX a leading slash is required after file:
        self.uri = "file:%s?mode=ro" % _uri_path(abspath)

    def connect(self):
        """Open a fresh read-only connection. Raises sqlite3.Error on failure."""
        conn = sqlite3.connect(self.uri, uri=True, timeout=5.0)
        conn.row_factory = sqlite3.Row
        # Defensive: keep our reads non-blocking-ish even under heavy write load.
        try:
            conn.execute("PRAGMA busy_timeout=3000;")
        except sqlite3.Error:
            pass
        return conn

    def connect_rw(self):
        """Open a fresh read-write connection. Raises sqlite3.Error on failure.

        This app is a viewer and every other code path opens the database
        read-only on purpose. The single exception is the Start button on an
        interactive task: the app has no channel back to the Claude Code session,
        so it records the human's intent as a row and the orchestrator picks it
        up on its next poll. Exactly one endpoint uses this, and it makes exactly
        one narrow, guarded UPDATE — see ``_handle_task_start``.
        """
        conn = sqlite3.connect(os.path.abspath(self.path), timeout=5.0)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA busy_timeout=3000;")
        except sqlite3.Error:
            pass
        return conn


def _uri_path(abspath):
    """Percent-encode a filesystem path for use in a sqlite file: URI.

    SQLite file: URIs use URL encoding. Encode everything that isn't an
    unreserved character, keeping path separators intact — this covers spaces
    and other special characters (e.g. paths under
    ``~/Library/Application Support/...``), not just ``? # %``.
    """
    return quote(abspath, safe="/")


def _counts(jobs):
    counts = {s: 0 for s in JOB_STATUSES}
    for j in jobs:
        st = j["status"] if isinstance(j, sqlite3.Row) else j.get("status")
        if st in counts:
            counts[st] += 1
    counts["total"] = len(jobs)
    return counts


def fetch_runs(db):
    """Newest-first list of runs with aggregate job counts. Empty list on error."""
    try:
        conn = db.connect()
    except sqlite3.Error:
        return []
    try:
        runs = conn.execute(
            "SELECT id, tag, mode, status, stage, started_at, finished_at "
            "FROM runs ORDER BY id DESC"
        ).fetchall()
        # One grouped query for all job counts keeps this O(1) round-trips.
        rows = conn.execute(
            "SELECT run_id, status, COUNT(*) AS n FROM jobs GROUP BY run_id, status"
        ).fetchall()
        by_run = {}
        for r in rows:
            d = by_run.setdefault(r["run_id"], {s: 0 for s in JOB_STATUSES})
            if r["status"] in d:
                d[r["status"]] += r["n"]
        out = []
        for run in runs:
            c = by_run.get(run["id"], {s: 0 for s in JOB_STATUSES})
            c = dict(c)
            c["total"] = sum(c[s] for s in JOB_STATUSES)
            d = dict(run)
            d["counts"] = c
            out.append(d)
        return out
    except sqlite3.Error:
        return []
    finally:
        conn.close()


def _followup_counts(followups):
    counts = {s: 0 for s in FOLLOWUP_STATUSES}
    for f in followups:
        st = f.get("status")
        if st in counts:
            counts[st] += 1
    counts["total"] = len(followups)
    counts["closed"] = counts["done"] + counts["wontdo"]
    return counts


def fetch_followups(conn, run_id):
    """Followup tickets for a run, each with its comment timeline + last_comment.

    Tolerates a database created before the followups tables existed (older
    schema): returns an empty list rather than raising.
    """
    try:
        rows = conn.execute(
            "SELECT * FROM followups WHERE run_id = ? ORDER BY id", (run_id,)
        ).fetchall()
    except sqlite3.Error:
        return []
    fups = [dict(r) for r in rows]
    if not fups:
        return fups
    try:
        crows = conn.execute(
            "SELECT fc.followup_id AS fid, fc.ts, fc.action, fc.comment "
            "FROM followup_comments fc JOIN followups f ON f.id = fc.followup_id "
            "WHERE f.run_id = ? ORDER BY fc.id",
            (run_id,),
        ).fetchall()
    except sqlite3.Error:
        crows = []
    by_f = {}
    for c in crows:
        by_f.setdefault(c["fid"], []).append(
            {"ts": c["ts"], "action": c["action"], "comment": c["comment"]}
        )
    for f in fups:
        cs = by_f.get(f["id"], [])
        f["comments"] = cs
        f["last_comment"] = cs[-1] if cs else None
    return fups


def fetch_project_issues(conn, run_id):
    """GitHub issues/PRs a run surfaced or filed, most-deserving first.

    Issues the run *filed itself* (``origin='created'``) sort ahead of everything
    else: they are the run's own output, the operator has no other signal that
    they exist, and there are only ever a handful. Within each group the order is
    (rank ASC, age_days DESC, id ASC) — lower rank means more deserving of
    attention, ties go to the older item, and the row id keeps it stable.
    ``age_days`` may be NULL; SQLite sorts NULL lowest, so DESC already pushes
    unknown-age rows to the end of their rank band.
    ``maintenance-db.sh list-project-issues`` orders identically — keep the two
    in step.

    Tolerates a database created before the project_issues table existed, and one
    created before it grew the ``origin`` column: returns an empty list rather
    than raising on the former, and retries without the origin term on the
    latter, so an old DB opened by a new server still serves its runs.
    """
    ordered = ("SELECT * FROM project_issues WHERE run_id = ? "
               "ORDER BY (origin = 'created') DESC, rank ASC, age_days DESC, id ASC")
    legacy = ("SELECT * FROM project_issues WHERE run_id = ? "
              "ORDER BY rank ASC, age_days DESC, id ASC")
    for sql in (ordered, legacy):
        try:
            rows = conn.execute(sql, (run_id,)).fetchall()
        except sqlite3.Error:
            continue
        return [dict(r) for r in rows]
    return []


def fetch_interactive_tasks(conn, run_id):
    """A run's interactive tasks, in the order the app should list them.

    Ordered (priority ASC, id ASC) — the same priority a project declares in the
    sub-skill's front matter, so a project that wants its human step offered
    first can say so.

    Tolerates a database created before the table existed: returns an empty list
    rather than raising, so an old DB opened by a new server still serves its
    runs (and simply shows no interactive bar, which is accurate — those runs
    had no interactive queue).
    """
    try:
        rows = conn.execute(
            "SELECT * FROM interactive_tasks WHERE run_id = ? "
            "ORDER BY priority ASC, id ASC",
            (run_id,),
        ).fetchall()
    except sqlite3.Error:
        return []
    return [dict(r) for r in rows]


def _interactive_counts(tasks):
    counts = {s: 0 for s in INTERACTIVE_STATUSES}
    for t in tasks:
        st = t.get("status")
        if st in counts:
            counts[st] += 1
    counts["total"] = len(tasks)
    counts["open"] = sum(counts[s] for s in INTERACTIVE_OPEN)
    return counts


def fetch_run_detail(db, run_id):
    """Full run row + ordered jobs + counts + followups + GitHub triage.

    None if run missing.
    """
    try:
        conn = db.connect()
    except sqlite3.Error:
        return None
    try:
        run = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
        if run is None:
            return None
        jobs = conn.execute(
            "SELECT * FROM jobs WHERE run_id = ? ORDER BY id", (run_id,)
        ).fetchall()
        jobs = [dict(j) for j in jobs]
        followups = fetch_followups(conn, run_id)
        project_issues = fetch_project_issues(conn, run_id)
        interactive = fetch_interactive_tasks(conn, run_id)
        return {
            "run": dict(run),
            "jobs": jobs,
            "counts": _counts(jobs),
            "followups": followups,
            "followup_counts": _followup_counts(followups),
            "interactive_tasks": interactive,
            "interactive_counts": _interactive_counts(interactive),
            "project_issues": project_issues,
            # The top-10 board is just the head of the same global ordering, so
            # slice it here rather than paying for a second LIMITed query.
            "top_issues": project_issues[:10],
        }
    except sqlite3.Error:
        return None
    finally:
        conn.close()


def fetch_events(db, run_id, after, limit=500):
    """Events with id > after, ascending, capped. Returns (events, last_id)."""
    try:
        conn = db.connect()
    except sqlite3.Error:
        return [], after
    try:
        rows = conn.execute(
            "SELECT id, job_id, ts, level, message FROM events "
            "WHERE run_id = ? AND id > ? ORDER BY id ASC LIMIT ?",
            (run_id, after, limit),
        ).fetchall()
        events = [dict(r) for r in rows]
        last_id = events[-1]["id"] if events else after
        return events, last_id
    except sqlite3.Error:
        return [], after
    finally:
        conn.close()


# --------------------------------------------------------------------------- #
# HTTP handler
# --------------------------------------------------------------------------- #

class Handler(BaseHTTPRequestHandler):
    server_version = "MaintenanceObs/1.0"
    protocol_version = "HTTP/1.1"

    # Quieter logging: one line, no noisy SSE spam.
    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    @property
    def db(self):
        return self.server.db

    # -- helpers ------------------------------------------------------------ #

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_bytes(self, body, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # The static assets ship no version in their URLs, so with no cache
        # directive at all a browser applies heuristic caching and can keep
        # serving a stale app.js indefinitely — silently running old client code
        # against a new server. These are a handful of KB off localhost; there
        # is nothing to gain by caching them.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _not_found(self):
        self._send_json({"error": "not found"}, status=404)

    # -- dispatch ----------------------------------------------------------- #

    def do_HEAD(self):
        # The SSE route is an infinite stream; delegating a HEAD to do_GET would
        # block forever (hanging HEAD-based health checks/proxies). Reject it.
        if RE_STREAM.match(urlparse(self.path).path):
            self.send_response(405)
            self.send_header("Allow", "GET")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        try:
            if path.startswith("/api/"):
                self._handle_api(path, parse_qs(parsed.query))
            else:
                self._handle_static(path)
        except BrokenPipeError:
            pass
        except ConnectionResetError:
            pass
        except Exception as exc:  # never let one request kill the thread silently
            try:
                self._send_json({"error": "internal", "detail": str(exc)}, status=500)
            except Exception:
                pass

    def do_POST(self):
        """The app's only write surface: Start on an interactive task."""
        parsed = urlparse(self.path)
        try:
            m = RE_TASK_START.match(parsed.path)
            if m:
                self._handle_task_start(int(m.group(1)), int(m.group(2)))
            else:
                self._not_found()
        except BrokenPipeError:
            pass
        except ConnectionResetError:
            pass
        except Exception as exc:
            try:
                self._send_json({"error": "internal", "detail": str(exc)}, status=500)
            except Exception:
                pass

    # -- writes ------------------------------------------------------------- #

    def _same_origin(self):
        """Reject a POST that did not come from this app's own page.

        The server listens on 127.0.0.1, which is reachable by *any* page the
        user happens to have open, not just ours. Without this check an
        unrelated site could fire a request at localhost and start someone's
        interactive task. Two independent signals, either sufficient to refuse:
        a Fetch-Metadata site value other than same-origin, or an Origin header
        that is not our own bound address. A request with neither header (curl,
        a health probe) is allowed through — it is not a browser, so it is not
        the confused-deputy case this guards.
        """
        site = self.headers.get("Sec-Fetch-Site")
        if site is not None and site not in ("same-origin", "none"):
            return False
        origin = self.headers.get("Origin")
        if origin:
            host = self.headers.get("Host") or ""
            if origin not in ("http://%s" % host, "https://%s" % host):
                return False
        return True

    def _handle_task_start(self, run_id, task_id):
        """Record that the human clicked Start on an interactive task.

        This writes intent, nothing more. The app cannot dispatch a subagent —
        it has no channel to the Claude Code session — so the orchestrator polls
        for these rows and dispatches when it sees one. A click landing while
        the session is busy, or after it has parked the run entirely, is
        therefore queued rather than lost.

        Idempotent by design: the UPDATE is guarded on status='discovered', and a
        click on a task that has already been requested, started or finished is
        answered with that task's current state and a 200. A double-click, a
        page refresh, or a retry must never disturb work in flight.
        """
        if not self._same_origin():
            self._send_json({"error": "cross-origin request refused"}, status=403)
            return
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype != "application/json":
            self._send_json({"error": "expected Content-Type: application/json"},
                            status=415)
            return
        # Drain and discard any body. There are no parameters — the URL carries
        # everything — but an unread body wedges keep-alive on the connection.
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send_json({"error": "bad Content-Length"}, status=400)
            return
        if length > 1024:
            self._send_json({"error": "body too large"}, status=413)
            return
        if length > 0:
            self.rfile.read(length)

        try:
            conn = self.db.connect_rw()
        except sqlite3.Error as exc:
            self._send_json({"error": "database unavailable", "detail": str(exc)},
                            status=503)
            return
        try:
            row = conn.execute(
                "SELECT * FROM interactive_tasks WHERE id = ? AND run_id = ?",
                (task_id, run_id),
            ).fetchone()
            if row is None:
                self._not_found()
                return
            if row["status"] == "discovered":
                now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                with conn:
                    conn.execute(
                        "UPDATE interactive_tasks "
                        "SET status = 'requested', start_requested_at = ? "
                        "WHERE id = ? AND run_id = ? AND status = 'discovered'",
                        (now, task_id, run_id),
                    )
                    conn.execute(
                        "INSERT INTO events (run_id, job_id, ts, level, message) "
                        "VALUES (?, ?, ?, 'info', ?)",
                        (run_id, row["job_id"], now,
                         "Interactive task #%d start requested; queued for "
                         "dispatch." % task_id),
                    )
                row = conn.execute(
                    "SELECT * FROM interactive_tasks WHERE id = ?", (task_id,)
                ).fetchone()
            self._send_json({"task": dict(row)})
        except sqlite3.Error as exc:
            self._send_json({"error": "write failed", "detail": str(exc)}, status=500)
        finally:
            conn.close()

    # -- API ---------------------------------------------------------------- #

    def _handle_api(self, path, query):
        if path == "/api/health":
            self._send_json({"ok": True})
            return
        if path == "/api/runs":
            self._send_json({"runs": fetch_runs(self.db)})
            return

        m = RE_RUN.match(path)
        if m:
            detail = fetch_run_detail(self.db, int(m.group(1)))
            if detail is None:
                self._not_found()
            else:
                self._send_json(detail)
            return

        m = RE_RUN_EVENTS.match(path)
        if m:
            after = _int_arg(query, "after", 0)
            events, last_id = fetch_events(self.db, int(m.group(1)), after)
            self._send_json({"events": events, "last_id": last_id})
            return

        m = RE_STREAM.match(path)
        if m:
            self._handle_stream(int(m.group(1)), query)
            return

        self._not_found()

    # -- SSE ---------------------------------------------------------------- #

    def _handle_stream(self, run_id, query):
        """Server-sent events. Emits {run, jobs, counts, events} on change."""
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            return

        last_event_id = _int_arg(query, "after", 0)
        prev_snapshot = None  # (run+jobs+counts) signature for change detection
        last_heartbeat = time.time()
        idle_terminal_cycles = 0

        # Prime the stream with the current full state so the client renders
        # immediately even if nothing changes for a while.
        try:
            self._sse_retry()
        except (BrokenPipeError, ConnectionResetError):
            return

        while True:
            detail = fetch_run_detail(self.db, run_id)
            events, last_event_id = fetch_events(self.db, run_id, last_event_id)

            changed = False
            payload = {}

            if detail is not None:
                sig = _snapshot_sig(detail)
                if sig != prev_snapshot:
                    prev_snapshot = sig
                    changed = True
                    payload["run"] = detail["run"]
                    payload["jobs"] = detail["jobs"]
                    payload["counts"] = detail["counts"]
                    payload["followups"] = detail["followups"]
                    payload["followup_counts"] = detail["followup_counts"]
                    payload["interactive_tasks"] = detail["interactive_tasks"]
                    payload["interactive_counts"] = detail["interactive_counts"]
                    payload["project_issues"] = detail["project_issues"]
                    payload["top_issues"] = detail["top_issues"]

            if events:
                changed = True
                payload["events"] = events

            try:
                if changed:
                    self._sse_send(payload, event_id=last_event_id)
                    last_heartbeat = time.time()
                elif time.time() - last_heartbeat >= 15:
                    self._sse_comment("heartbeat")
                    last_heartbeat = time.time()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return  # client disconnected

            # Terminate gracefully once the run is finished and quiet.
            # 'awaiting_interactive' is deliberately absent: a parked run is not
            # over, and its page is exactly where the human clicks Start, so the
            # stream must stay open however long they take.
            status = detail["run"]["status"] if detail else None
            terminal = status in ("completed", "failed", "cancelled")
            if terminal and not events:
                idle_terminal_cycles += 1
                if idle_terminal_cycles >= 3:
                    try:
                        self._sse_comment("stream closing (run terminal)")
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        pass
                    return
            else:
                idle_terminal_cycles = 0

            time.sleep(1.0)

    def _sse_send(self, obj, event_id=None):
        chunk = ""
        if event_id is not None:
            chunk += "id: %d\n" % event_id
        chunk += "data: %s\n\n" % json.dumps(obj)
        self.wfile.write(chunk.encode("utf-8"))
        self.wfile.flush()

    def _sse_comment(self, text):
        self.wfile.write((": %s\n\n" % text).encode("utf-8"))
        self.wfile.flush()

    def _sse_retry(self):
        # Tell the browser to wait 2s before reconnecting if the stream drops.
        self.wfile.write(b"retry: 2000\n\n")
        self.wfile.flush()

    # -- static files ------------------------------------------------------- #

    def _handle_static(self, path):
        if path == "/":
            path = "/index.html"

        # Normalize and confine to STATIC_DIR (no path traversal).
        rel = path.lstrip("/")
        full = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not full.startswith(STATIC_DIR + os.sep) and full != STATIC_DIR:
            self._not_found()
            return
        if not os.path.isfile(full):
            self._not_found()
            return

        ext = os.path.splitext(full)[1].lower()
        ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
        try:
            with open(full, "rb") as fh:
                body = fh.read()
        except OSError:
            self._not_found()
            return
        self._send_bytes(body, ctype)


def _int_arg(query, name, default):
    try:
        vals = query.get(name)
        if not vals:
            return default
        return int(vals[0])
    except (ValueError, TypeError):
        return default


def _snapshot_sig(detail):
    """Cheap signature of run+jobs to detect changes without diffing fully."""
    run = detail["run"]
    parts = [run.get("status"), run.get("stage"), run.get("finished_at"),
             run.get("summary")]
    for j in detail["jobs"]:
        parts.append("%s:%s:%s:%s" % (
            j.get("id"), j.get("status"), j.get("finished_at"),
            (j.get("summary") or "")[:64]))
    # Include followup tickets so closing/commenting one streams to the client.
    for f in detail.get("followups", []):
        lc = f.get("last_comment") or {}
        parts.append("f%s:%s:%s:%s" % (
            f.get("id"), f.get("status"), f.get("updated_at"),
            (lc.get("comment") or "")[:48]))
    # Include the interactive tasks so the bar reflects a Start click (and the
    # dispatch that follows it) live, rather than only on the next page load.
    for t in detail.get("interactive_tasks", []):
        parts.append("x%s:%s:%s:%s" % (
            t.get("id"), t.get("status"), t.get("start_requested_at"),
            t.get("finished_at")))
    # Include the GitHub triage rows so the section appears live as each job's
    # subagent records them, instead of only on the next full page load.
    for i in detail.get("project_issues", []):
        parts.append("i%s:%s:%s" % (
            i.get("id"), i.get("rank"), (i.get("triage") or "")[:48]))
    return "|".join("" if p is None else str(p) for p in parts)


# --------------------------------------------------------------------------- #
# Server bootstrap
# --------------------------------------------------------------------------- #

class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, db):
        super().__init__(addr, Handler)
        self.db = db


def bind_with_probe(host, start_port, db, max_extra=50):
    """Try ports start_port .. start_port+max_extra; return (server, port)."""
    last_err = None
    for port in range(start_port, start_port + max_extra + 1):
        try:
            return Server((host, port), db), port
        except OSError as exc:
            last_err = exc
            continue
    raise SystemExit(
        "could not bind any port in range %d-%d: %s"
        % (start_port, start_port + max_extra, last_err)
    )


def write_file(path, text):
    if not path:
        return
    try:
        with open(path, "w") as fh:
            fh.write(text)
    except OSError as exc:
        sys.stderr.write("warning: could not write %s: %s\n" % (path, exc))


def main(argv=None):
    parser = argparse.ArgumentParser(description="maintenance observability server")
    parser.add_argument("--port", type=int, default=7373, help="starting port")
    parser.add_argument("--db", required=True, help="path to observability.db")
    parser.add_argument("--port-file", default=None, help="write bound port here")
    parser.add_argument("--pid-file", default=None, help="write pid here")
    parser.add_argument("--host", default="127.0.0.1", help="bind host")
    args = parser.parse_args(argv)

    db = DB(args.db)
    server, port = bind_with_probe(args.host, args.port, db)

    write_file(args.port_file, str(port))
    write_file(args.pid_file, str(os.getpid()))

    sys.stderr.write(
        "maintenance observability listening on http://%s:%d  (db=%s)\n"
        % (args.host, port, args.db)
    )

    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        # Best-effort cleanup of the pid file we own.
        if args.pid_file and os.path.exists(args.pid_file):
            try:
                os.remove(args.pid_file)
            except OSError:
                pass


if __name__ == "__main__":
    main()
