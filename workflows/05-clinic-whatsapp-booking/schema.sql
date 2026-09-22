-- 05 Clinic WhatsApp booking agent: 7 tables, no PHI columns.
-- SCHEDULING AND FAQ ONLY. NO SYMPTOMS, NO DIAGNOSIS. NO HEALTH DATA STORED. n8n offers no BAA.
-- Apply once before the first run:  psql -U <user> -d <db> -f schema.sql

CREATE TABLE IF NOT EXISTS ep05_messages (
  message_id   text PRIMARY KEY,        -- Meta wa message id (or a hash fallback) -- dedupe key
  wa_id        text NOT NULL,           -- WhatsApp id of the sender (fictional in the demo)
  name         text,                    -- display name only, no other patient data stored
  lang_hint    text,                    -- 'es' | 'en', guessed in code
  body         text NOT NULL,           -- the raw message text (simulation only; not a clinical record)
  received_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ep05_messages_wa_id_idx ON ep05_messages (wa_id);

CREATE TABLE IF NOT EXISTS ep05_sessions (
  session_key  text PRIMARY KEY,        -- wa_id -- one row per patient conversation
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep05_slots (
  id          serial PRIMARY KEY,
  slot_start  timestamptz NOT NULL,
  slot_end    timestamptz NOT NULL,
  status      text NOT NULL DEFAULT 'free',  -- free | booked
  wa_id       text,                          -- set on booking, null while free
  booked_at   timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS ep05_slots_start_idx ON ep05_slots (slot_start);
CREATE INDEX IF NOT EXISTS ep05_slots_status_idx ON ep05_slots (status);

CREATE TABLE IF NOT EXISTS ep05_bookings (
  id           serial PRIMARY KEY,
  wa_id        text NOT NULL,
  slot_id      integer NOT NULL REFERENCES ep05_slots (id),
  message_id   text REFERENCES ep05_messages (message_id),
  confirmed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ep05_bookings_slot_idx ON ep05_bookings (slot_id);

CREATE TABLE IF NOT EXISTS ep05_outbox (
  id          serial PRIMARY KEY,
  wa_id       text NOT NULL,
  message_id  text REFERENCES ep05_messages (message_id),
  body        text NOT NULL,           -- never actually sent -- WhatsApp Send node is a disabled swap point
  kind        text NOT NULL DEFAULT 'agent_reply',  -- agent_reply | handoff_notice
  written_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ep05_outbox_wa_id_idx ON ep05_outbox (wa_id);

CREATE TABLE IF NOT EXISTS ep05_handoffs (
  id          serial PRIMARY KEY,
  wa_id       text NOT NULL,
  message_id  text REFERENCES ep05_messages (message_id),
  reason      text NOT NULL,           -- symptoms | medication | diagnosis | price | emergency
  fired_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ep05_run_summary (
  id                            serial PRIMARY KEY,
  run_id                        text NOT NULL,
  patients_simulated            integer,
  bookings_confirmed            integer,
  median_seconds_to_first_reply numeric(8,1),
  handoffs_fired                integer,
  double_bookings               integer,
  duplicate_webhooks_ignored    integer,
  languages                     text,          -- comma-separated, e.g. "es,en"
  created_at                    timestamptz NOT NULL DEFAULT now()
);

-- Seed ep05_slots: 7-day grid starting tomorrow, Mon-Sat, 09:00-17:00 every 30 minutes.
-- (idempotent: ON CONFLICT on the unique slot_start index)
INSERT INTO ep05_slots (slot_start, slot_end, status)
SELECT s, s + interval '30 minutes', 'free'
FROM generate_series(
  date_trunc('day', now()) + interval '1 day' + interval '9 hours',
  date_trunc('day', now()) + interval '7 days' + interval '16 hours 30 minutes',
  interval '30 minutes'
) AS s
WHERE extract(isodow FROM s) BETWEEN 1 AND 6      -- Mon(1)..Sat(6)
  AND s::time >= '09:00' AND s::time < '17:00'
ON CONFLICT (slot_start) DO NOTHING;

-- The numbers the video quotes, per run:
-- SELECT count(*) FROM ep05_bookings;
-- SELECT count(*) FROM ep05_handoffs;
-- SELECT slot_id FROM ep05_bookings GROUP BY slot_id HAVING count(*) > 1;   -- must be 0 rows
