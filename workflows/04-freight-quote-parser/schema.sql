-- 04 Freight quote parser: one row per inbound email (keyed on message_id) + the draft reply.
-- Apply once before the first run:  psql -U <user> -d <db> -f schema.sql

CREATE TABLE IF NOT EXISTS ep04_quotes (
  message_id        text PRIMARY KEY,          -- email Message-ID (or a hash of from+subject+body when the feed has none)
  from_email        text,
  from_name         text,
  subject           text,
  email_date        text,                      -- as carried by the feed, not parsed
  -- the 8 schema fields (fields_filled counts the non-null ones)
  origin_port       text,
  destination_port  text,
  mode              text,                      -- FCL | LCL | AIR | ROAD | RAIL
  weight_kg         numeric(12,2),
  dimensions        text,                      -- "L x W x H cm x N pallets", inches already converted
  cargo_type        text,
  incoterm          text,                      -- EXW FCA FAS FOB CFR CIF CPT CIP DAP DPU DDP
  deadline          text,                      -- YYYY-MM-DD when resolvable, else the sender's phrase ("before Eid")
  deadline_is_date  boolean NOT NULL DEFAULT false,
  -- extras, not counted
  pieces            integer,
  notes             text,
  confidence        numeric(3,2),              -- 0.00 - 1.00, model confidence re-checked in code (0 on parse failure)
  fields_filled     integer NOT NULL DEFAULT 0, -- of 8
  parse_error       text,
  tokens_in         integer,
  tokens_out        integer,
  model             text,
  run_id            text NOT NULL,
  raw_extraction    jsonb,                     -- exactly what the model returned, before validation
  arrived_at        timestamptz,               -- when the email entered the workflow
  seconds_to_row    numeric(8,1),              -- arrived_at -> this row written, stamped in SQL
  seen_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ep04_quotes_run_id_idx ON ep04_quotes (run_id);

CREATE TABLE IF NOT EXISTS ep04_drafts (
  message_id     text PRIMARY KEY REFERENCES ep04_quotes (message_id) ON DELETE CASCADE,
  to_email       text,
  subject        text,
  body           text NOT NULL,
  fields_filled  integer,
  confidence     numeric(3,2),
  run_id         text,
  status         text NOT NULL DEFAULT 'draft',  -- never 'sent' by this workflow
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

-- The number the video quotes, per run:
-- SELECT run_id, count(*) AS rows, round(avg(fields_filled),2) AS fields_filled_avg, round(avg(seconds_to_row),1) AS seconds_avg
-- FROM ep04_quotes GROUP BY 1 ORDER BY 1 DESC;
