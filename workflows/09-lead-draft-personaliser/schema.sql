-- EP09 -- Lead-draft personaliser -- schema
-- 4 Postgres tables + one n8n Data Table (ep09_caps, see data-table-spec.md).
-- Never touch ops_lead_draft / lg_% / ma_% / dm_% (the live estate's own lead
-- tables) -- these are entirely separate, ep09_-prefixed, and this workflow has
-- no send node so nothing here ever reaches an outbound lane.

CREATE TABLE IF NOT EXISTS ep09_leads (
  id            SERIAL PRIMARY KEY,
  lead_id       TEXT,
  host          TEXT,               -- raw host; only read by the Postgres swap-point node
  business_name TEXT,
  niche         TEXT,
  city          TEXT,
  signal        TEXT,               -- the one real fact we have about the lead, if any
  source        TEXT,               -- e.g. maps-harvest, linkedin-outreach, manual-paste
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per drafted lead. host_ref only -- never the raw host or any raw URL.
-- idempotency_key = ep09:<host_ref>:<date>, so a re-run on the same day does not
-- duplicate a draft for the same host (ON CONFLICT DO NOTHING in Write draft).
CREATE TABLE IF NOT EXISTS ep09_drafts (
  id               SERIAL PRIMARY KEY,
  host_ref         TEXT NOT NULL,          -- masked, e.g. h_3fae9c1b
  stage            TEXT NOT NULL,          -- draft-ready | needs-review
  draft            TEXT NOT NULL,
  confidence       NUMERIC(4,3),
  reason           TEXT,
  idempotency_key  TEXT UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep09_run_summary (
  id                   SERIAL PRIMARY KEY,
  run_id               TEXT,
  leads_in             INTEGER,
  after_dedupe         INTEGER,
  dedupe_dropped       INTEGER,
  drafts_attempted     INTEGER,
  drafts_written       INTEGER,
  stage_draft_ready    INTEGER,
  stage_needs_review   INTEGER,
  llm_calls_this_run   INTEGER,
  seconds_elapsed      NUMERIC(8,2),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep09_errors (
  id             SERIAL PRIMARY KEY,
  workflow_name  TEXT,
  node_name      TEXT,
  error_message  TEXT,
  execution_id   TEXT,
  occurred_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
