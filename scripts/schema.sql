PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS runs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  tag         TEXT    NOT NULL,
  mode        TEXT,                                  -- serial | fast | now
  status      TEXT    NOT NULL DEFAULT 'running',    -- running | completed | failed | cancelled
  stage       TEXT    NOT NULL DEFAULT 'starting',   -- starting | reading-config | discovering | executing | summarizing | done
  started_at  TEXT    NOT NULL,                       -- ISO-8601 UTC
  finished_at TEXT,
  summary     TEXT,                                   -- Markdown run summary
  options     TEXT                                    -- JSON blob of CLI flags
);

CREATE TABLE IF NOT EXISTS jobs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id       INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  project_path TEXT    NOT NULL,
  project_name TEXT    NOT NULL,
  skill_name   TEXT,
  status       TEXT    NOT NULL DEFAULT 'pending',   -- pending | running | success | failure | skipped
  started_at   TEXT,
  finished_at  TEXT,
  summary      TEXT,                                  -- Markdown per-project summary
  error        TEXT,
  UNIQUE(run_id, project_path)
);

CREATE TABLE IF NOT EXISTS events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id  INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  job_id  INTEGER REFERENCES jobs(id) ON DELETE CASCADE,
  ts      TEXT    NOT NULL,                            -- ISO-8601 UTC
  level   TEXT    NOT NULL DEFAULT 'info',             -- info | warn | error | success
  message TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_jobs_run   ON jobs(run_id);
CREATE INDEX IF NOT EXISTS idx_events_run ON events(run_id, id);
