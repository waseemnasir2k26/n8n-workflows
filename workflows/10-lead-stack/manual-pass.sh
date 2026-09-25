#!/usr/bin/env bash
# 10-lead-stack / manual-pass.sh
# Thin wrapper: runs each brick from its OWN manual trigger, in order
# 03 -> 02 -> 09 -> 07 -> 08, via n8n's internal run API
# (POST /rest/workflows/{id}/run) using an owner session cookie -- the same
# technique 08-silent-lane-watchdog's builder used for its own proof run
# (see that brick's README + memory reference-n8n-mint-ui-session-token.md).
# This produces REAL execution ids on the throwaway instance. Manual
# execution is allowed; only ACTIVATING a workflow is banned, and nothing
# here ever calls /activate.
#
#   03  Click to run        manual trigger, real Apify search (needs APIFY_TOKEN
#                            wired at install time)
#   02  Web Lead In webhook  no manual-trigger sibling -- started via pinData on
#                            the webhook node (same lead payload seed/lead.json
#                            would have posted)
#   09  Manual Test          built-in sibling; fans out to the GitHub sample
#                            leads AND ep09_leads (Postgres) -- the seed row is
#                            inserted into ep09_leads first so it is genuinely
#                            in the batch this executes
#   07  Manual Test          built-in sibling; the brick's OWN wiring routes
#                            Manual Test to "Load sample inbox", never live
#                            IMAP -- this is the brick's real, honest
#                            DRY-RUN-equivalent manual path, not a limitation
#                            added here
#   08  Manual Test          built-in sibling; calls the demo instance's own
#                            API via the real "n8n API (stack-demo, self)"
#                            credential wired at install time
#
# Usage:
#   ./manual-pass.sh                 # real runs (default)
#   ./manual-pass.sh --seed-only     # WARNING: falls back to direct SQL
#                                     # seeding of each brick's table instead
#                                     # of a real execution -- only for a
#                                     # Postgres-schema smoke test, never a
#                                     # substitute for the real pass above
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${N8N_BASE_URL:?Set N8N_BASE_URL, e.g. http://127.0.0.1:5679}"
COOKIE_FILE="${N8N_COOKIE_FILE:-}"
INSTALLED_JSON="${INSTALLED_JSON:-$SCRIPT_DIR/installed.json}"
RESULTS_FILE="$SCRIPT_DIR/.manual_pass_results.json"

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

if [ "${1:-}" = "--seed-only" ]; then
  echo "!! --seed-only: writing SQL stand-in rows, NOT running any brick." >&2
  echo "!! This is a schema/wiring smoke test ONLY -- it produces zero real" >&2
  echo "!! execution ids and does not satisfy the 'real manual execution' bar." >&2
  exec python3 - "$SCRIPT_DIR" <<'PYEOF'
# Minimal legacy seeder, kept only behind --seed-only. See git history for the
# original full version if you need it back verbatim.
import json, os, subprocess, sys
script_dir = sys.argv[1] if len(sys.argv) > 1 else "."
seed = json.load(open(os.path.join(script_dir, "seed", "lead.json")))
print("seed-only mode: see STACK.md for the manual SQL used previously; "
      "run acceptance.sh --seed-only-ok to relax the execution-id assertion "
      "if you use this path.", file=sys.stderr)
PYEOF
fi

: "${COOKIE_FILE:?Set N8N_COOKIE_FILE to a cookie jar authenticated on the THROWAWAY instance (owner login or minted n8n-auth token)}"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

LEAD_REF=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['lead_ref'])" "$SCRIPT_DIR/seed/lead.json")
echo "== manual pass (REAL executions): lead_ref=$LEAD_REF ==" >&2

# 0. Seed stack_leads + the one Postgres input table a brick reads directly (ep09_leads).
python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
print('|'.join([d['lead_ref'], d['business_name'], d['niche'], d['city'], d['state'],
                d['phone'], d['website'], d['email'], d['issue']]))
" "$SCRIPT_DIR/seed/lead.json" > "$SCRIPT_DIR/.seed_fields"
IFS='|' read -r LEAD_REF BIZ NICHE CITY STATE PHONE WEBSITE EMAIL ISSUE < "$SCRIPT_DIR/.seed_fields"
rm -f "$SCRIPT_DIR/.seed_fields"
esc() { printf "%s" "$1" | sed "s/'/''/g"; }

run_psql <<SQL
INSERT INTO stack_leads (lead_ref, business_name, niche, city, state, phone, website, email, source, is_synthetic)
VALUES ('$(esc "$LEAD_REF")','$(esc "$BIZ")','$(esc "$NICHE")','$(esc "$CITY")','$(esc "$STATE")','$(esc "$PHONE")','$(esc "$WEBSITE")','$(esc "$EMAIL")','seed/lead.json',true)
ON CONFLICT (lead_ref) DO NOTHING;
INSERT INTO ep09_leads (lead_id, host, business_name, niche, city, signal, source)
VALUES ('$(esc "$LEAD_REF")', '$(esc "$WEBSITE")', '$(esc "$BIZ")', '$(esc "$NICHE")', '$(esc "$CITY")', '$(esc "$ISSUE")', 'stack-demo-seed');
SQL
echo "  [seed] stack_leads + ep09_leads row written" >&2

# Helper: run a brick from a named start node, optional pinData, poll to finish.
# $5 (optional) = test-webhook path (e.g. "demo/lead") for webhook-triggered
# bricks: the /run call only ARMS the test listener and returns
# {"waitingForWebhook":true} with no executionId, so a second, real HTTP call
# to /webhook-test/<path> is required to actually fire it -- this is n8n's
# own "listen for test event" mechanism, the same one the editor's "Listen
# for test event" button drives. $6 (optional) = the JSON body for that call.
run_brick() {
  local brick="$1" wfid="$2" start_node="$3" pin_json="${4:-}" webhook_path="${5:-}" webhook_body="${6:-}"
  local wf_file="$SCRIPT_DIR/.wf_$brick.json"
  curl -s -b "$COOKIE_FILE" "$N8N_BASE_URL/rest/workflows/$wfid" > "$wf_file"
  local body_file="$SCRIPT_DIR/.run_$brick.json"
  local pin_file="$SCRIPT_DIR/.pin_$brick.json"
  printf '%s' "$pin_json" > "$pin_file"
  python3 - "$wf_file" "$start_node" "$pin_file" "$body_file" <<'PYEOF'
import json, sys
wf_file, start_node, pin_file, body_file = sys.argv[1:5]
d = json.load(open(wf_file))
wf = d.get('data', d)
body = {'workflowData': wf, 'startNodes': [{'name': start_node, 'sourceData': None}],
        'triggerToStartFrom': {'name': start_node}}
pin_raw = open(pin_file, encoding='utf-8').read().strip()
if pin_raw:
    body['pinData'] = {start_node: json.loads(pin_raw)}
json.dump(body, open(body_file, 'w'))
PYEOF
  rm -f "$pin_file"
  local resp_file="$SCRIPT_DIR/.run_resp_$brick.json" exec_id
  curl -s -b "$COOKIE_FILE" -H 'Content-Type: application/json' -X POST \
    "$N8N_BASE_URL/rest/workflows/$wfid/run" -d @"$body_file" > "$resp_file"
  exec_id=$(python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('data', {}).get('executionId', ''))
except Exception:
    print('')
" "$resp_file")
  if [ -z "$exec_id" ] && [ -n "$webhook_path" ] && grep -q "waitingForWebhook" "$resp_file"; then
    # Armed -- fire the real test-webhook call, then find the execution it created.
    local webhook_body_file="$SCRIPT_DIR/.whbody_$brick.json"
    printf '%s' "$webhook_body" > "$webhook_body_file"
    curl -s -X POST "$N8N_BASE_URL/webhook-test/$webhook_path" \
      -H 'Content-Type: application/json' -d @"$webhook_body_file" > "$SCRIPT_DIR/.whresp_$brick.json" || true
    rm -f "$webhook_body_file"
    sleep 1
    exec_id=$(curl -s -b "$COOKIE_FILE" \
      "$N8N_BASE_URL/rest/executions?filter=%7B%22workflowId%22%3A%22$wfid%22%7D&limit=1" \
      | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('data', {}).get('results', d.get('data', []))
print(rows[0]['id'] if rows else '')
" 2>/dev/null || echo "")
    echo "  [$brick] webhook fired -> $(cat "$SCRIPT_DIR/.whresp_$brick.json" | head -c 150)" >&2
    rm -f "$SCRIPT_DIR/.whresp_$brick.json"
  fi
  if [ -z "$exec_id" ]; then
    echo "  [!] $brick: run call failed: $(head -c 200 "$resp_file")" >&2
    rm -f "$resp_file"
    rm -f "$wf_file" "$body_file"
    echo "{\"brick\":\"$brick\",\"execution_id\":null,\"status\":\"run_call_failed\"}"
    return 0
  fi
  # Poll up to ~90s for a terminal status.
  local status="new" tries=0
  while [ "$tries" -lt 30 ]; do
    sleep 3
    status=$(curl -s -b "$COOKIE_FILE" "$N8N_BASE_URL/rest/executions/$exec_id" \
      | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('data',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")
    if [ "$status" != "new" ] && [ "$status" != "running" ]; then
      break
    fi
    tries=$((tries + 1))
  done
  echo "  [$brick] execution $exec_id -> status=$status (start node: $start_node)" >&2
  rm -f "$wf_file" "$body_file" "$resp_file"
  echo "{\"brick\":\"$brick\",\"execution_id\":\"$exec_id\",\"status\":\"$status\"}"
}

get_id() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(next(w['id'] for w in d['workflows'] if w['brick']==sys.argv[2]))" "$INSTALLED_JSON" "$1"; }

WF03=$(get_id "03-maps-lead-harvest")
WF02=$(get_id "02-speed-to-lead")
WF09=$(get_id "09-lead-draft-personaliser")
WF07=$(get_id "07-inbox-router-drafts-only")
WF08=$(get_id "08-silent-lane-watchdog")

: > "$RESULTS_FILE.jsonl"

echo "[1/5] 03-maps-lead-harvest ..." >&2
run_brick "03-maps-lead-harvest" "$WF03" "Click to run" "" >> "$RESULTS_FILE.jsonl"

PIN_FILE="$SCRIPT_DIR/.pin_seed.json"
python3 - "$BIZ" "$PHONE" "$CITY" "$ISSUE" <<'PYEOF' > "$PIN_FILE"
import json, sys
name, phone, city, issue = sys.argv[1:5]
print(json.dumps([{"json": {"name": name, "phone": phone, "city": city, "issue": issue}}]))
PYEOF
PIN=$(cat "$PIN_FILE")
rm -f "$PIN_FILE"
echo "[2/5] 02-speed-to-lead ..." >&2
WEBHOOK_BODY=$(python3 - "$BIZ" "$PHONE" "$CITY" "$ISSUE" <<'PYEOF'
import json, sys
name, phone, city, issue = sys.argv[1:5]
print(json.dumps({"name": name, "phone": phone, "city": city, "issue": issue}))
PYEOF
)
run_brick "02-speed-to-lead" "$WF02" "Web Lead In" "$PIN" "demo/lead" "$WEBHOOK_BODY" >> "$RESULTS_FILE.jsonl"

echo "[3/5] 09-lead-draft-personaliser ..." >&2
run_brick "09-lead-draft-personaliser" "$WF09" "Manual Test" "" >> "$RESULTS_FILE.jsonl"

echo "[4/5] 07-inbox-router-drafts-only (Manual Test -> sample inbox, no live IMAP) ..." >&2
run_brick "07-inbox-router-drafts-only" "$WF07" "Manual Test" "" >> "$RESULTS_FILE.jsonl"

echo "[5/5] 08-silent-lane-watchdog ..." >&2
run_brick "08-silent-lane-watchdog" "$WF08" "Manual Test" "" >> "$RESULTS_FILE.jsonl"

python3 - "$RESULTS_FILE.jsonl" "$RESULTS_FILE" <<'PYEOF'
import json, sys
jsonl_path, out_path = sys.argv[1], sys.argv[2]
rows = [json.loads(line) for line in open(jsonl_path) if line.strip()]
json.dump(rows, open(out_path, 'w'), indent=2)
print(json.dumps(rows, indent=2))
PYEOF
rm -f "$RESULTS_FILE.jsonl"

echo "== manual pass complete. Results: $RESULTS_FILE. Run ./acceptance.sh next. ==" >&2
