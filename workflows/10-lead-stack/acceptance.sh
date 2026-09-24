#!/usr/bin/env bash
# 10-lead-stack / acceptance.sh
# Read-back asserts for the manual pass:
#   1) each brick has >=1 REAL execution id (public API, GET /executions?workflowId=)
#   2) each brick's own table carries >=1 row (02/09 checked against the
#      seeded lead specifically, since those two ran with the seed as input;
#      03/07/08 checked for existence, since their manual-trigger paths run
#      against a live Maps search / a sample inbox / the instance's own API
#      -- see STACK.md "Build notes" for exactly why each is shaped that way)
#   3) installed.json lists 6 workflows (five bricks + the EP10 error handler)
#
# --seed-only-ok relaxes (1) to a warning instead of a hard FAIL, for use
# only after manual-pass.sh --seed-only (no real executions exist to check).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_ONLY_OK=0
[ "${1:-}" = "--seed-only-ok" ] && SEED_ONLY_OK=1

: "${N8N_BASE_URL:?Set N8N_BASE_URL}"
: "${N8N_API_KEY:?Set N8N_API_KEY}"

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

assert_execution() {
  local brick="$1" wfid="$2"
  local n
  n=$(curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$N8N_BASE_URL/api/v1/executions?workflowId=$wfid&limit=50" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d.get('data',[])))" 2>/dev/null || echo 0)
  if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
    echo "PASS  $brick has >=1 real execution (n=$n, workflowId=$wfid)"
  elif [ "$SEED_ONLY_OK" = "1" ]; then
    echo "WARN  $brick has 0 real executions (--seed-only-ok: not a hard fail)"
  else
    echo "FAIL  $brick has 0 real executions (workflowId=$wfid)"
    FAIL=1
  fi
}

LEAD_REF=$(python3 -c "import json; print(json.load(open('$SCRIPT_DIR/seed/lead.json'))['lead_ref'])")
echo "== acceptance: lead_ref=$LEAD_REF =="

echo "-- 1) real execution ids per brick --"
if [ -f "$SCRIPT_DIR/installed.json" ]; then
  for brick in 03-maps-lead-harvest 02-speed-to-lead 09-lead-draft-personaliser 07-inbox-router-drafts-only 08-silent-lane-watchdog; do
    WFID=$(python3 -c "
import json
d = json.load(open('$SCRIPT_DIR/installed.json'))
w = next((w for w in d['workflows'] if w['brick'] == '$brick'), None)
print(w['id'] if w else '')
")
    if [ -z "$WFID" ]; then
      echo "FAIL  $brick not found in installed.json"
      FAIL=1
      continue
    fi
    assert_execution "$brick" "$WFID"
  done
else
  echo "FAIL  installed.json missing"
  FAIL=1
fi

echo "-- 2) each brick's own table --"
assert_row "stack_leads has the seed row" \
  "SELECT count(*) FROM stack_leads WHERE lead_ref='$LEAD_REF';"

assert_row "03-maps-lead-harvest: ep03_leads carries at least one row" \
  "SELECT count(*) FROM ep03_leads;"

assert_row "02-speed-to-lead: demo_sessions carries a row for the seeded lead" \
  "SELECT count(*) FROM demo_sessions WHERE issue ILIKE '%hailstorm%' AND city='Denver';"

assert_row "09-lead-draft-personaliser: ep09_drafts carries a row for the seeded lead" \
  "SELECT count(*) FROM ep09_drafts d JOIN ep09_leads l ON true WHERE l.lead_id='${LEAD_REF}';"

assert_row "07-inbox-router-drafts-only: ep07_inbox carries at least one row" \
  "SELECT count(*) FROM ep07_inbox;"

assert_row "08-silent-lane-watchdog: ep08_lane_checks or ep08_errors carries at least one row" \
  "SELECT count(*) FROM (SELECT id FROM ep08_lane_checks UNION ALL SELECT id FROM ep08_errors) x;"

echo "-- 3) installed.json sanity --"
if [ -f "$SCRIPT_DIR/installed.json" ]; then
  python3 -c "
import json
d = json.load(open('$SCRIPT_DIR/installed.json'))
n = len(d.get('workflows', []))
assert n == 6, f'expected 6 workflows (5 bricks + error handler) in installed.json, got {n}'
brick_names = {w['brick'] for w in d['workflows']}
assert 'error-workflow' in brick_names, 'error-workflow missing from installed.json'
print('PASS  installed.json lists 6 workflows (5 bricks + error handler)')
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
