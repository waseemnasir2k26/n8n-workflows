CREATE TABLE IF NOT EXISTS ep03_leads (
  place_id      text PRIMARY KEY,
  name          text NOT NULL,
  category      text,
  city          text,
  state         text,
  phone         text,
  website       text,
  has_website   boolean NOT NULL DEFAULT false,
  maps_rating   numeric(3,2),
  review_count  integer,
  run_id        text NOT NULL,
  seen_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ep03_leads_run_id_idx ON ep03_leads (run_id);
