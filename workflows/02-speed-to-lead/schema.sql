-- Speed-to-Lead (simulated demo) — schema
-- Three tables. Derived directly from the queries inside workflow.json
-- ("Create Session", "Log Lead Text", "Save AI Reply", "Read State").
-- Not confirmed against a live information_schema dump — see README GOTCHAS.

CREATE TABLE IF NOT EXISTS demo_sessions (
  id         BIGSERIAL PRIMARY KEY,
  token      TEXT NOT NULL,
  name       TEXT NOT NULL,
  phone      TEXT,
  city       TEXT,
  issue      TEXT NOT NULL,
  booked_at  TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The webhook lanes look sessions up by token on every request; this index is load-bearing.
CREATE UNIQUE INDEX IF NOT EXISTS demo_sessions_token_idx ON demo_sessions (token);

CREATE TABLE IF NOT EXISTS demo_messages (
  id          BIGSERIAL PRIMARY KEY,
  session_id  BIGINT NOT NULL REFERENCES demo_sessions (id) ON DELETE CASCADE,
  sender      TEXT NOT NULL CHECK (sender IN ('lead', 'ai')),
  body        TEXT NOT NULL,
  latency_ms  INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS demo_messages_session_id_idx ON demo_messages (session_id);

CREATE TABLE IF NOT EXISTS demo_bookings (
  id          BIGSERIAL PRIMARY KEY,
  session_id  BIGINT NOT NULL REFERENCES demo_sessions (id) ON DELETE CASCADE,
  job_type    TEXT NOT NULL,
  tech        TEXT NOT NULL,
  slot_at     TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- "Save AI Reply" upserts on ON CONFLICT (session_id) DO NOTHING, i.e. at most
-- one booking per session — enforce it here too, it is not implied by the FK above.
CREATE UNIQUE INDEX IF NOT EXISTS demo_bookings_session_id_idx ON demo_bookings (session_id);
