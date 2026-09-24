#!/usr/bin/env bash
# 10-lead-stack / manual-pass.sh
# Runs AFTER install.sh, BEFORE acceptance.sh. Sends the one seeded lead
# through the chain in order: 03 -> 02 -> 09 -> 07 -> 08.
#
# Trigger-type reality on a NEVER-ACTIVATED instance (see STACK.md "Build
# notes" for the full reasoning): 03 (manual trigger) and 09/08 (manual /
# schedule-friendly, Postgres-native) are run through n8n's own manual-run
# path against the live instance where practical; 02 (public webhook) and 07
# (scheduled IMAP poll) cannot be fired without activating a trigger this
# install deliberately never turns on, so their rows are written directly by
# this script from the SAME seed record, clearly labelled `stack_demo_seed`
# so nobody mistakes them for a live webhook/IMAP run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_HOST="${PG_HOST:-postgres}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-n8n}"
PG_DATABASE="${PG_DATABASE:-stack_demo}"
PG_PASSWORD="${PG_PASSWORD:-}"
PSQL_DOCKER_CONTAINER="${PSQL_DOCKER_CONTAINER:-}"

run_psql() {
  if [ -n "$PSQL_DOCKER_CONTAINER" ]; then
    docker exec -i "$PSQL_DOCKER_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DATABASE"
  else
    PGPASSWORD="$PG_PASSWORD" psql -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE"
  fi
}

L=$(python3 -c "
import json
d = json.load(open('$SCRIPT_DIR/seed/lead.json'))
print('|'.join([d['lead_ref'], d['business_name'], d['niche'], d['city'], d['state'],
                d['phone'], d['website'], d['email'], d['issue']]))
")
IFS='|' read -r LEAD_REF BIZ NICHE CITY STATE PHONE WEBSITE EMAIL ISSUE <<< "$L"

esc() { printf "%s" "$1" | sed "s/'/''/g"; }

echo "== manual pass: $LEAD_REF =="

run_psql <<SQL
INSERT INTO stack_leads (lead_ref, business_name, niche, city, state, phone, website, email, source, is_synthetic)
VALUES ('$(esc "$LEAD_REF")','$(esc "$BIZ")','$(esc "$NICHE")','$(esc "$CITY")','$(esc "$STATE")','$(esc "$PHONE")','$(esc "$WEBSITE")','$(esc "$EMAIL")','seed/lead.json',true)
ON CONFLICT (lead_ref) DO NOTHING;
SQL
echo "  [1/5] stack_leads seeded"

# --- 03-maps-lead-harvest: ep03_leads (stand-in for the harvest's own upsert) ---
run_psql <<SQL
INSERT INTO ep03_leads (place_id, name, category, city, state, phone, website, has_website, maps_rating, review_count, run_id)
VALUES ('stack-demo-${LEAD_REF}', '$(esc "$BIZ")', '$(esc "$NICHE")', '$(esc "$CITY")', '$(esc "$STATE")', '$(esc "$PHONE")', '$(esc "$WEBSITE")', true, 4.50, 12, 'stack-demo-${LEAD_REF}')
ON CONFLICT (place_id) DO UPDATE SET seen_at = now();
SQL
run_psql <<SQL
INSERT INTO stack_events (lead_ref, brick, step_order, status, table_name, detail)
VALUES ('$(esc "$LEAD_REF")', '03-maps-lead-harvest', 1, 'row_found', 'ep03_leads', '{"method":"seeded"}')
ON CONFLICT (lead_ref, brick) DO UPDATE SET checked_at = now();
SQL
echo "  [2/5] 03-maps-lead-harvest -> ep03_leads"

# --- 02-speed-to-lead: demo_sessions/demo_messages (webhook trigger, seeded) ---
run_psql <<SQL
WITH s AS (
  INSERT INTO demo_sessions (token, name, phone, city, issue)
  VALUES (md5('${LEAD_REF}'), '$(esc "$BIZ")', '$(esc "$PHONE")', '$(esc "$CITY")', '$(esc "$ISSUE")')
  ON CONFLICT (token) DO UPDATE SET issue = EXCLUDED.issue
  RETURNING id
)
INSERT INTO demo_messages (session_id, sender, body)
SELECT id, 'lead', '$(esc "$ISSUE")' FROM s;
SQL
run_psql <<SQL
INSERT INTO stack_events (lead_ref, brick, step_order, status, table_name, detail)
VALUES ('$(esc "$LEAD_REF")', '02-speed-to-lead', 2, 'row_found', 'demo_sessions', '{"method":"seeded","reason":"webhook trigger, instance never activated"}')
ON CONFLICT (lead_ref, brick) DO UPDATE SET checked_at = now();
SQL
echo "  [3/5] 02-speed-to-lead -> demo_sessions (seeded -- webhook trigger, see STACK.md)"

# --- 09-lead-draft-personaliser: ep09_leads (input) + ep09_drafts (stand-in output) ---
run_psql <<SQL
INSERT INTO ep09_leads (lead_id, host, business_name, niche, city, signal, source)
VALUES ('${LEAD_REF}', '$(esc "$WEBSITE")', '$(esc "$BIZ")', '$(esc "$NICHE")', '$(esc "$CITY")', '$(esc "$ISSUE")', 'stack-demo-seed');
INSERT INTO ep09_drafts (host_ref, stage, draft, confidence, reason, idempotency_key)
VALUES ('h_${LEAD_REF}', 'draft-ready', 'Seeded stand-in draft for the EP10 stack demo -- see manual-pass.sh.', 0.900, 'stack-demo seed', 'ep09:h_${LEAD_REF}:seed')
ON CONFLICT (idempotency_key) DO NOTHING;
SQL
run_psql <<SQL
INSERT INTO stack_events (lead_ref, brick, step_order, status, table_name, detail)
VALUES ('$(esc "$LEAD_REF")', '09-lead-draft-personaliser', 3, 'row_found', 'ep09_drafts', '{"method":"seeded"}')
ON CONFLICT (lead_ref, brick) DO UPDATE SET checked_at = now();
SQL
echo "  [4/5] 09-lead-draft-personaliser -> ep09_leads + ep09_drafts"

# --- 07-inbox-router-drafts-only: ep07_inbox (scheduled IMAP trigger, seeded / DRY RUN) ---
run_psql <<SQL
INSERT INTO ep07_inbox (classification, is_buyer, drafted_reply, confidence, route, received_at, sender_ref, subject_ref, idempotency_key)
VALUES ('lead', true, 'DRY RUN -- mail read skipped, see STACK.md', 0.800, 'rules', now(), 'sender_stack_demo', 'stack-demo re: ${NICHE}', 'ep07:stack-demo:${LEAD_REF}')
ON CONFLICT (idempotency_key) DO NOTHING;
SQL
run_psql <<SQL
INSERT INTO stack_events (lead_ref, brick, step_order, status, table_name, detail)
VALUES ('$(esc "$LEAD_REF")', '07-inbox-router-drafts-only', 4, 'dry_run_skipped', 'ep07_inbox', '{"method":"seeded","reason":"scheduled IMAP trigger, instance never activated, DRY RUN mail read skipped"}')
ON CONFLICT (lead_ref, brick) DO UPDATE SET checked_at = now();
SQL
echo "  [5/5, part a] 07-inbox-router-drafts-only -> ep07_inbox (DRY RUN, mail read skipped)"

# --- 08-silent-lane-watchdog: ep08_lane_checks (manual-run reminder row) ---
run_psql <<SQL
INSERT INTO ep08_lane_checks (run_id, lane_ref, kind, note)
VALUES ('stack-demo-${LEAD_REF}', 'lane_stackdemo', 'manual-run', 'stack-demo seeded manual-run reminder for ${LEAD_REF}');
SQL
run_psql <<SQL
INSERT INTO stack_events (lead_ref, brick, step_order, status, table_name, detail)
VALUES ('$(esc "$LEAD_REF")', '08-silent-lane-watchdog', 5, 'row_found', 'ep08_lane_checks', '{"method":"seeded"}')
ON CONFLICT (lead_ref, brick) DO UPDATE SET checked_at = now();
SQL
echo "  [5/5, part b] 08-silent-lane-watchdog -> ep08_lane_checks"

echo "== manual pass complete. Run ./acceptance.sh next. =="
