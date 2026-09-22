-- EP06 -- Meta Ads Circuit Breaker -- schema
-- 5 tables. Never touch ma_config / ma_latest / ma_actions_today / ma_actions (the
-- live estate breaker MA-02's tables) -- these are entirely separate, ep06_-prefixed.

CREATE TABLE IF NOT EXISTS ep06_insights (
  id           SERIAL PRIMARY KEY,
  account_ref  TEXT,               -- masked, e.g. act_••••3502
  adset_ref    TEXT,               -- masked, e.g. ••••0014
  adset_name   TEXT,               -- our own ad set name only, never a client's
  spend        NUMERIC(12,2),
  impressions  INTEGER,
  clicks       INTEGER,
  ctr          NUMERIC(8,4),
  leads        INTEGER,            -- MAX over action_types matching /lead/i, never SUM
  cpl          NUMERIC(12,2),      -- null when leads = 0
  date_start   DATE,
  date_stop    DATE,
  source       TEXT,               -- 'live' or 'sample'
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep06_actions (
  id            SERIAL PRIMARY KEY,
  insight_id    INTEGER REFERENCES ep06_insights(id),
  action_type   TEXT,
  action_value  NUMERIC(12,2),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep06_receipts (
  id                 SERIAL PRIMARY KEY,
  run_ts             TEXT,
  adset_ref          TEXT,         -- masked
  rule               TEXT,         -- R1 | R2 | R3 | min-data | lag | clean
  reason             TEXT,
  dry_run            BOOLEAN,
  configured_status  TEXT,
  effective_status   TEXT,
  idempotency_key    TEXT,         -- ep06:<adset_id>:<rule>:<date>
  observed           JSONB,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep06_run_summary (
  id                     SERIAL PRIMARY KEY,
  run_id                 TEXT,
  rows_evaluated         INTEGER,
  none_count             INTEGER,
  trip_count             INTEGER,
  pause_count            INTEGER,
  actions_gated          INTEGER,
  receipts_written       INTEGER,
  breaker_trips_written  INTEGER,
  dry_run                BOOLEAN,
  spend_observed         NUMERIC(12,2),
  leads_observed         INTEGER,
  clicks_observed        INTEGER,
  impressions_observed   INTEGER,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep06_errors (
  id             SERIAL PRIMARY KEY,
  workflow_name  TEXT,
  node_name      TEXT,
  error_message  TEXT,
  execution_id   TEXT,
  occurred_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
