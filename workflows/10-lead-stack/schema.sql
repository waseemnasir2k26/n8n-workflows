-- 10-lead-stack -- shared "stack_*" schema
-- Applied by install.sh BEFORE each brick's own schema.sql. Purpose: give the
-- ONE seeded lead a single canonical row (stack_leads) and a place for
-- acceptance.sh to log, in order, that the lead reached each brick's own
-- table (stack_events). stack_caps mirrors each brick's cap sheet for a
-- one-screen view -- it does NOT replace the real Data Tables (ep07_caps,
-- ep08_caps, ep09_caps), which stay the source of truth for the workflows.
--
-- Each brick keeps writing to ITS OWN table (demo_sessions/ep03_leads/
-- ep07_inbox/ep08_lane_checks/ep09_drafts) exactly as published -- this repo
-- does not modify any brick's workflow.json logic. stack_events is populated
-- by acceptance.sh as it verifies, in order, that the seeded lead produced a
-- row in each brick's own table.

CREATE TABLE IF NOT EXISTS stack_leads (
  id            SERIAL PRIMARY KEY,
  lead_ref      TEXT UNIQUE NOT NULL,   -- e.g. 'stack-demo-0001'
  business_name TEXT,
  niche         TEXT,
  city          TEXT,
  state         TEXT,
  phone         TEXT,
  website       TEXT,
  email         TEXT,
  source        TEXT,                   -- 'seed/lead.json'
  is_synthetic  BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS stack_events (
  id           SERIAL PRIMARY KEY,
  lead_ref     TEXT NOT NULL REFERENCES stack_leads (lead_ref),
  brick        TEXT NOT NULL,           -- '03-maps-lead-harvest' etc
  step_order   INTEGER NOT NULL,        -- 1..5, the chain order
  status       TEXT NOT NULL,           -- row_found | row_missing | dry_run_skipped
  table_name   TEXT,                    -- the brick's own table checked
  detail       JSONB,
  checked_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS stack_events_lead_brick_idx
  ON stack_events (lead_ref, brick);

CREATE TABLE IF NOT EXISTS stack_caps (
  brick             TEXT PRIMARY KEY,   -- '07-inbox-router-drafts-only' etc
  cap_table_kind    TEXT NOT NULL,      -- 'data_table' | 'none'
  dry_run           BOOLEAN,
  kill_enabled      BOOLEAN,
  breaker_tripped   BOOLEAN,
  note              TEXT,
  mirrored_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
