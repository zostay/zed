PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS runs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  tag         TEXT    NOT NULL,
  mode        TEXT,                                  -- serial | fast | now
  status      TEXT    NOT NULL DEFAULT 'running',    -- running | completed | needs_followup | failed | cancelled
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
  status       TEXT    NOT NULL DEFAULT 'pending',   -- pending | running | success | followup | failure | skipped
  started_at   TEXT,
  finished_at  TEXT,
  summary      TEXT,                                  -- Markdown per-project summary
  error        TEXT,
  UNIQUE(run_id, project_path)
);

-- Followup "tickets": items a run surfaced that need human attention. Each row's
-- id is the sequential ticket number the observability app shows and the
-- maint-followup skill takes as its argument. A run with any open ticket sits at
-- status 'needs_followup'; when the last ticket is resolved (done | wontdo) the
-- run flips to 'completed'.
CREATE TABLE IF NOT EXISTS followups (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,    -- the ticket number (sequential, global)
  run_id       INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  job_id       INTEGER REFERENCES jobs(id) ON DELETE CASCADE,
  project_name TEXT,
  title        TEXT    NOT NULL,                      -- short description of what needs followup
  detail       TEXT,                                  -- optional longer description
  status       TEXT    NOT NULL DEFAULT 'open',       -- open | done | wontdo
  created_at   TEXT    NOT NULL,                       -- ISO-8601 UTC
  updated_at   TEXT,
  closed_at    TEXT
);

-- Progress log on a ticket: one row per maint-followup invocation (and the
-- opening note). action is the verb the skill was given.
CREATE TABLE IF NOT EXISTS followup_comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  followup_id INTEGER NOT NULL REFERENCES followups(id) ON DELETE CASCADE,
  ts          TEXT    NOT NULL,                        -- ISO-8601 UTC
  action      TEXT,                                    -- opened | update | done | nope
  comment     TEXT    NOT NULL
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
CREATE INDEX IF NOT EXISTS idx_followups_run        ON followups(run_id, id);
CREATE INDEX IF NOT EXISTS idx_followup_comments_fk ON followup_comments(followup_id, id);
