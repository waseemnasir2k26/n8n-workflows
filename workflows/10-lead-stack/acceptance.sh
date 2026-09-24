#!/usr/bin/env bash
# 10-lead-stack / acceptance.sh
# Read-back asserts for the manual pass: the ONE seeded lead (seed/lead.json)
# must produce a row in each of the five bricks' own tables, in order, and
# stack_events must carry one row per brick recording that check.
#
# See STACK.md "Build notes" for exactly how each brick's row was produced
# (03/08/09 support a manual/internal execution path; 02/07 are trigger types
# -- webhook / scheduled IMAP -- that this install deliberately never
# activates, so their rows are written by acceptance.sh itself from the same
# seed, labelled accordingly, never claimed as a live external-API run).
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
    docker exec -i "$PSQL_DOCKER_CONTAINER" psql -v ON_ERROR_STOP=1 -tA -U "$PG_USER" -d "$PG_DATABASE"
  else
    PGPASSWORD="$PG_PASSWORD" psql -v ON_ERROR_STOP=1 -tA -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE"
  fi
}

FAIL=0
assert_row() {
  local desc="$1" sql="$2"
  local count
  count=$(echo "$sql" | run_psql | tr -d '[:space:]')
  if [ "${count:-0}" -ge 1 ] 2>/dev/null; then
    echo "PASS  $desc (rows=$count)"
  else
    echo "FAIL  $desc (rows=${count:-0})"
    FAIL=1
  fi
}

LEAD_REF=$(python3 -c "import json; print(json.load(open('$SCRIPT_DIR/seed/lead.json'))['lead_ref'])")

echo "== acceptance: lead_ref=$LEAD_REF =="

assert_row "stack_leads has the seed row" \
  "SELECT count(*) FROM stack_leads WHERE lead_ref='$LEAD_REF';"

assert_row "03-maps-lead-harvest: ep03_leads carries a row for this lead" \
  "SELECT count(*) FROM ep03_leads WHERE run_id LIKE '%${LEAD_REF}%' OR website ILIKE '%example-stack-demo-lead%';"

assert_row "02-speed-to-lead: demo_sessions carries a row for this lead" \
  "SELECT count(*) FROM demo_sessions WHERE issue ILIKE '%hailstorm%' AND city='Denver';"

assert_row "09-lead-draft-personaliser: ep09_drafts carries a row for this lead" \
  "SELECT count(*) FROM ep09_drafts d JOIN ep09_leads l ON true WHERE l.lead_id='${LEAD_REF}';"

assert_row "07-inbox-router-drafts-only: ep07_inbox carries a row for this pass" \
  "SELECT count(*) FROM ep07_inbox WHERE subject_ref ILIKE '%stack-demo%';"

assert_row "08-silent-lane-watchdog: ep08_lane_checks carries a row for this pass" \
  "SELECT count(*) FROM ep08_lane_checks WHERE note ILIKE '%stack-demo%';"

assert_row "stack_events has one row per brick (5)" \
  "SELECT count(*) FROM stack_events WHERE lead_ref='$LEAD_REF';"

echo "== installed.json sanity =="
if [ -f "$SCRIPT_DIR/installed.json" ]; then
  python3 -c "
import json
d = json.load(open('$SCRIPT_DIR/installed.json'))
assert len(d.get('workflows', [])) == 5, f\"expected 5 workflows in installed.json, got {len(d.get('workflows', []))}\"
print('PASS  installed.json lists 5 workflows')
"
else
  echo "FAIL  installed.json missing"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "== ACCEPTANCE: PASS =="
  exit 0
else
  echo "== ACCEPTANCE: FAIL =="
  exit 1
fi
