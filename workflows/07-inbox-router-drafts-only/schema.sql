-- EP07 -- Inbox Router (drafts only) -- schema
-- 3 tables. Never touch inbound_messages / replies (the live estate's own tables) --
-- these are entirely separate, ep07_-prefixed, and only ever hold OUR OWN mailbox
-- (skynetlabsai.com IMAP), never a client's.

CREATE TABLE IF NOT EXISTS ep07_inbox (
  id                SERIAL PRIMARY KEY,
  classification    TEXT,               -- lead | technical | spam | existing_client | needs_review
  is_buyer          BOOLEAN,
  drafted_reply     TEXT,               -- draft only -- never sent, no send node exists
  confidence        NUMERIC(4,3),
  route             TEXT,               -- rules | model
  received_at       TIMESTAMPTZ,
  sender_ref        TEXT,               -- masked, e.g. sender_04821
  subject_ref       TEXT,               -- truncated 60 chars, any embedded email stripped
  idempotency_key   TEXT UNIQUE,        -- ep07:<djb2 hash of masked sender + received_at>
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep07_run_summary (
  id               SERIAL PRIMARY KEY,
  run_id           TEXT,
  msgs_in          INTEGER,
  rules_handled    INTEGER,
  model_handled    INTEGER,
  leads            INTEGER,
  needs_review     INTEGER,
  spam             INTEGER,
  technical        INTEGER,
  existing_client  INTEGER,
  sent             INTEGER,          -- always 0 -- structurally, no send node exists
  labels_gated     INTEGER,
  rows_written     INTEGER,
  dry_run          BOOLEAN,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep07_errors (
  id             SERIAL PRIMARY KEY,
  workflow_name  TEXT,
  node_name      TEXT,
  error_message  TEXT,
  execution_id   TEXT,
  occurred_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
