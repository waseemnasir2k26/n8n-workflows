-- EP08 -- Silent-lane watchdog -- schema
-- 4 Postgres tables. Never touch WD-01's tables (the live estate watchdog,
-- id JklxGG8fI6OXMQgu) -- this is an entirely separate, ep08_-prefixed set.
-- Two Data Tables (ep08_lanes, ep08_caps) are NOT Postgres tables -- see
-- data-table-spec.md.

-- One row per lane per RUN -- the full journal, including lanes that were
-- correctly judged healthy/quiet/off/unmeasurable. This is the "0 errors is
-- not health" evidence table: read it to see what was actually checked, not
-- just what alarmed.
CREATE TABLE IF NOT EXISTS ep08_lane_checks (
  id                      SERIAL PRIMARY KEY,
  run_id                  TEXT,
  lane_ref                TEXT,          -- masked, e.g. lane_9f2a1c30
  kind                    TEXT,          -- scheduled | event-driven | upstream-count | manual-run
  expected_interval_min   INTEGER,
  last_success_at         TIMESTAMPTZ,
  minutes_since_success   NUMERIC,
  upstream_count_window   INTEGER,
  run_count_window        INTEGER,
  missed                  BOOLEAN,
  action                  TEXT,          -- open | recover | reminder_manual | none
  note                    TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Genuine incidents only. reminder_manual and none NEVER appear here --
-- only lanes that actually missed a real obligation, gated by the guard.
CREATE TABLE IF NOT EXISTS ep08_incidents (
  id               SERIAL PRIMARY KEY,
  lane_ref         TEXT,                 -- masked
  status           TEXT NOT NULL DEFAULT 'open',   -- open | closed
  reason           TEXT,
  idempotency_key  TEXT UNIQUE,          -- ep08:<lane_ref>:<date> -- also the
                                          -- daily dedupe/remind key: a same-day
                                          -- re-open upserts reminded_at instead
                                          -- of creating a second row.
  dry_run          BOOLEAN,
  opened_at        TIMESTAMPTZ,
  reminded_at      TIMESTAMPTZ,
  closed_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep08_run_summary (
  id                    SERIAL PRIMARY KEY,
  run_id                TEXT,
  dry_run               BOOLEAN,
  lanes_evaluated       INTEGER,
  missed_count          INTEGER,
  incidents_opened      INTEGER,
  incidents_reminded    INTEGER,
  incidents_recovered   INTEGER,
  reminders_sent        INTEGER,         -- manual-run reminders (never incidents)
  guard_blocked         BOOLEAN,         -- true if any missed lane was gated
                                          -- by kill_enabled/breaker/cap this run
  breaker_tripped       BOOLEAN,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep08_errors (
  id             SERIAL PRIMARY KEY,
  workflow_name  TEXT,
  node_name      TEXT,
  error_message  TEXT,
  execution_id   TEXT,
  occurred_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Required for the ON CONFLICT upsert in "Open or remind incident".
CREATE UNIQUE INDEX IF NOT EXISTS ep08_incidents_idempotency_key_idx
  ON ep08_incidents (idempotency_key);
