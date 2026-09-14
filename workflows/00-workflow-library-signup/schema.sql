CREATE TABLE IF NOT EXISTS workflow_subscribers (
  id              bigserial PRIMARY KEY,
  email           text NOT NULL UNIQUE CHECK (email = lower(email)),
  source          text,
  workflow_slug   text,
  ip              text,
  user_agent      text,
  consent         boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  unsubscribed_at timestamptz NULL
);
CREATE INDEX IF NOT EXISTS workflow_subscribers_created_at_idx ON workflow_subscribers (created_at DESC);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='hq_app') THEN
    GRANT SELECT ON workflow_subscribers TO hq_app;
  END IF;
END $$;
