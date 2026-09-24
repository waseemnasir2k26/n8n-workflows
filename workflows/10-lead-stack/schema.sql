-- 10-lead-stack -- shared "stack_*" schema
-- Applied by install.sh BEFORE each brick's own schema.sql. Purpose: give the
-- ONE seeded lead a single canonical row (stack_leads) and one shared ledger
-- (stack_events) recording, per brick per lead, that the chain connected --
-- plus the error handler's own sentinel row for events with no lead
-- attached (a failed execution before any lead-specific work happened).
--
-- The shared CAP SHEET is an n8n Data Table, not a Postgres table -- see
-- install.sh section 4 ("stack_caps", one row) and STACK.md. This file only
-- owns stack_leads / stack_events. One stack cap sheet (Data Table) + the
-- bricks' own cap tables/Data Tables (ep07_caps/ep08_caps/ep09_caps) --
-- never two Postgres tables both claiming the name stack_caps.
--
-- Each brick keeps writing to ITS OWN table (demo_sessions/ep03_leads/
-- ep07_inbox/ep08_lane_checks/ep09_drafts) exactly as published -- this repo
-- does not modify any brick's workflow.json logic.

CREATE TABLE IF NOT EXISTS stack_leads (
  id            SERIAL PRIMARY KEY,
  lead_ref      TEXT UNIQUE NOT NULL,   -- e.g. 'stack-demo-0001', or the
                                         -- sentinel '__system__' for error rows
                                         -- logged with no lead in context
  business_name TEXT,
  niche         TEXT,
  city          TEXT,
  state         TEXT,
  phone         TEXT,
  website       TEXT,
  email         TEXT,
  source        TEXT,                   -- 'seed/lead.json' | 'error-sentinel'
  is_synthetic  BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The error handler (error-workflow.json) upserts this sentinel row itself
-- on its first fire too -- this INSERT just means the row exists even
-- before any error has ever happened, so a fresh acceptance run can query
-- stack_events with a working FK from minute one.
INSERT INTO stack_leads (lead_ref, business_name, source, is_synthetic)
VALUES ('__system__', 'system', 'error-sentinel', true)
ON CONFLICT (lead_ref) DO NOTHING;

CREATE TABLE IF NOT EXISTS stack_events (
  id           SERIAL PRIMARY KEY,
  lead_ref     TEXT NOT NULL REFERENCES stack_leads (lead_ref),
  brick        TEXT NOT NULL,           -- '03-maps-lead-harvest' etc, or
                                         -- 'error:<workflow name>:<execution id>'
                                         -- for a row the error handler wrote
  step_order   INTEGER NOT NULL,        -- 1..5 the chain order, 0 for error rows
  status       TEXT NOT NULL,           -- row_found | row_missing | dry_run_skipped | error_logged
  table_name   TEXT,                    -- the brick's own table checked, NULL for error rows
  detail       JSONB,
  checked_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Load-bearing for the real per-brick-per-lead chain rows (manual-pass.sh /
-- acceptance.sh ON CONFLICT upserts). Error rows use a unique brick value
-- per execution (see error-workflow.json's "Log error" node) so they never
-- collide with this index or with each other.
CREATE UNIQUE INDEX IF NOT EXISTS stack_events_lead_brick_idx
  ON stack_events (lead_ref, brick);
