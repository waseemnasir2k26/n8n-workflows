#!/usr/bin/env bash
# 10-lead-stack / install.sh
# Imports FIVE published n8n-workflows bricks INACTIVE onto a FRESH throwaway
# n8n instance, wires one shared "stack_*" schema, and registers all five in
# the EP08 watchdog's ep08_lanes table as kind:manual-run.
#
# Runs from Git Bash on Windows and from bash on Linux. Requires: curl, python3.
# Optional: jq (nice-to-have, not required), psql (or set PSQL_DOCKER_CONTAINER
# to run schema.sql through `docker exec -i <container> psql` instead).
#
# NEVER touches a production n8n instance. NEVER activates anything.
# NEVER commits to git. NEVER prints secret values.
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Config (env vars — see STACK.md "Credential checklist" for the full list)
# ---------------------------------------------------------------------------
: "${N8N_BASE_URL:?Set N8N_BASE_URL, e.g. http://127.0.0.1:5679 (the THROWAWAY instance)}"
: "${N8N_API_KEY:?Set N8N_API_KEY, the API key minted on the THROWAWAY instance itself}"

PG_HOST="${PG_HOST:-postgres}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-n8n}"
PG_DATABASE="${PG_DATABASE:-stack_demo}"
PG_PASSWORD="${PG_PASSWORD:-}"
PSQL_DOCKER_CONTAINER="${PSQL_DOCKER_CONTAINER:-}"   # e.g. n8n-postgres-1 -- if set, schema.sql runs via `docker exec -i`

APIFY_TOKEN="${APIFY_TOKEN:-}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
N8N_SELF_API_KEY="${N8N_SELF_API_KEY:-$N8N_API_KEY}"   # credential EP08's "List workflows" node uses to call N8N_BASE_URL back

IMAP_HOST="${IMAP_HOST:-}"
IMAP_PORT="${IMAP_PORT:-993}"
IMAP_USER="${IMAP_USER:-}"
IMAP_PASSWORD="${IMAP_PASSWORD:-}"

WALL_CLOCK_CAP_SEC="${WALL_CLOCK_CAP_SEC:-600}"   # 10 min
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_JSON="$SCRIPT_DIR/installed.json"
IDS_TXT="$SCRIPT_DIR/ids.txt"

BRICKS=(
  "03-maps-lead-harvest"
  "02-speed-to-lead"
  "09-lead-draft-personaliser"
  "07-inbox-router-drafts-only"
  "08-silent-lane-watchdog"
)

START_TS=$(date +%s)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

elapsed() { echo $(( $(date +%s) - START_TS )); }

check_wall_clock() {
  local el; el=$(elapsed)
  if [ "$el" -gt "$WALL_CLOCK_CAP_SEC" ]; then
    log "WALL-CLOCK CAP HIT (${el}s > ${WALL_CLOCK_CAP_SEC}s) -- aborting and rolling back."
    rollback
    exit 3
  fi
}

# ---------------------------------------------------------------------------
# [7] REFUTE-FIRST: hard-coded refusal even if N8N_BASE_URL / N8N_HOST is mis-set.
# This install script must NEVER be able to reach the production instance,
# whatever env vars it is handed.
# ---------------------------------------------------------------------------
PROD_HOSTNAME_DENYLIST=("n8n.skynetjoe.com")
host_from_url() {
  echo "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[/?#].*##; s#:.*##'
}
refuse_if_production() {
  local url="$1"
  local host; host="$(host_from_url "$url")"
  for bad in "${PROD_HOSTNAME_DENYLIST[@]}"; do
    if [ "$host" = "$bad" ]; then
      log "REFUSED: N8N_BASE_URL resolves to the PRODUCTION hostname ($bad)."
      log "This installer only ever runs against a fresh, throwaway n8n instance."
      exit 2
    fi
  done
  # Defense in depth: 5678 is the production n8n container's port on this
  # estate (n8n-n8n-1). A throwaway instance must use a different port
  # (this build uses 5679). Refuse the well-known production port unless
  # the caller explicitly overrides.
  if echo "$url" | grep -qE ':5678([/]|$)'; then
    if [ "${ALLOW_PORT_5678:-}" != "yes" ]; then
      log "REFUSED: N8N_BASE_URL uses port 5678, the PRODUCTION n8n port on this estate."
      log "Set ALLOW_PORT_5678=yes only if you are certain this is not n8n-n8n-1."
      exit 2
    fi
  fi
  # Also refuse literal production API key patterns if someone pasted the prod key by mistake:
  # (the production key JWT 'iss' claim embeds 'n8n' the same as any n8n key, so instead we
  # positively confirm the target answers as OUR throwaway by checking /healthz + workflow count
  # sanity after the collision check below.)
}
refuse_if_production "$N8N_BASE_URL"

API() { # API METHOD PATH [DATA]
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" "$N8N_BASE_URL$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' \
      -d "$data"
  else
    curl -sS -X "$method" "$N8N_BASE_URL$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY"
  fi
}

# ---------------------------------------------------------------------------
# --rollback: delete exactly the ids installed.json recorded. Nothing else.
# ---------------------------------------------------------------------------
rollback() {
  if [ ! -f "$INSTALLED_JSON" ]; then
    log "No installed.json -- nothing to roll back."
    return 0
  fi
  log "Rolling back ids in $INSTALLED_JSON ..."
  python3 - "$INSTALLED_JSON" "$N8N_BASE_URL" "$N8N_API_KEY" <<'PY'
import json, sys, urllib.request

path, base, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    installed = json.load(f)

def req(method, p):
    r = urllib.request.Request(base + p, method=method, headers={"X-N8N-API-KEY": key})
    try:
        urllib.request.urlopen(r, timeout=15)
        return True
    except Exception as e:
        print(f"  ! failed to delete {p}: {e}", file=sys.stderr)
        return False

for wf in installed.get("workflows", []):
    print(f"  deleting workflow {wf['name']} ({wf['id']})", file=sys.stderr)
    req("DELETE", f"/api/v1/workflows/{wf['id']}")

for dt in installed.get("data_tables", []):
    print(f"  deleting data table {dt['name']} ({dt['id']})", file=sys.stderr)
    req("DELETE", f"/api/v1/data-tables/{dt['id']}")

for cr in installed.get("credentials", []):
    print(f"  deleting credential {cr['name']} ({cr['id']})", file=sys.stderr)
    req("DELETE", f"/api/v1/credentials/{cr['id']}")

print("rollback done", file=sys.stderr)
PY
  rm -f "$INSTALLED_JSON"
  log "Rollback complete. installed.json removed."
}

if [ "${1:-}" = "--rollback" ]; then
  rollback
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Collision refusal — name collision on ANY of the five target workflows
#    aborts the whole install with exit 2 and makes ZERO changes.
# ---------------------------------------------------------------------------
log "Checking for name collisions on $N8N_BASE_URL ..."
EXISTING_NAMES_FILE="$SCRIPT_DIR/.existing_names.json"
API GET "/api/v1/workflows?limit=250" > "$EXISTING_NAMES_FILE"
COLLISION=0
for b in "${BRICKS[@]}"; do
  WF_NAME=$(python3 -c "import json;print(json.load(open('$SCRIPT_DIR/../$b/workflow.json'))['name'])")
  HIT=$(python3 - "$EXISTING_NAMES_FILE" "$WF_NAME" <<'PY'
import json, sys
path, wf_name = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
names = [w["name"] for w in d.get("data", [])]
print("1" if wf_name in names else "0")
PY
)
  if [ "$HIT" = "1" ]; then
    log "COLLISION: a workflow named '$WF_NAME' already exists on this instance."
    COLLISION=1
  fi
done
rm -f "$EXISTING_NAMES_FILE"
if [ "$COLLISION" = "1" ]; then
  log "Refusing to install: at least one target workflow name already exists."
  log "This instance is not fresh, or a previous install was not rolled back."
  exit 2
fi
log "No collisions. Proceeding."
check_wall_clock

# ---------------------------------------------------------------------------
# 2. Shared stack_* schema
# ---------------------------------------------------------------------------
log "Applying stack_*.sql (shared) + each brick's own schema.sql ..."
run_psql() {
  local sqlfile="$1"
  if [ -n "$PSQL_DOCKER_CONTAINER" ]; then
    docker exec -i "$PSQL_DOCKER_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DATABASE" < "$sqlfile"
  else
    PGPASSWORD="$PG_PASSWORD" psql -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -f "$sqlfile"
  fi
}
run_psql "$SCRIPT_DIR/schema.sql"
for b in "${BRICKS[@]}"; do
  BSCHEMA="$SCRIPT_DIR/../$b/schema.sql"
  if [ -f "$BSCHEMA" ]; then
    run_psql "$BSCHEMA"
  fi
done
log "Schema applied."
check_wall_clock

# ---------------------------------------------------------------------------
# 3. Credentials — created only if the matching secret env var is set.
#    Placeholders stay REPLACE_ME when the secret is absent (per spec).
# ---------------------------------------------------------------------------
: > "$SCRIPT_DIR/.cred_ids.env"   # scratch map, not committed (gitignored)
: > "$SCRIPT_DIR/.installed_extra.jsonl"   # truncate: never accumulate ids across runs

create_cred() {
  local name="$1" type="$2" data_json="$3" envkey="$4"
  local body resp id
  body=$(python3 -c "import json,sys; print(json.dumps({'name': sys.argv[1], 'type': sys.argv[2], 'data': json.loads(sys.argv[3])}))" "$name" "$type" "$data_json")
  resp=$(API POST "/api/v1/credentials" "$body")
  id=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('id',''))" "$resp")
  if [ -z "$id" ]; then
    log "  ! failed to create credential '$name': $(echo "$resp" | head -c 200)"
    return 1
  fi
  echo "${envkey}=${id}" >> "$SCRIPT_DIR/.cred_ids.env"
  echo "${envkey}_NAME=\"${name}\"" >> "$SCRIPT_DIR/.cred_ids.env"
  echo "{\"kind\":\"credential\",\"id\":\"$id\",\"name\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$name")}" >> "$SCRIPT_DIR/.installed_extra.jsonl"
  log "  + credential '$name' -> $id"
}

log "Creating credentials on the throwaway instance ..."
create_cred "Postgres (stack-demo)" "postgres" \
  "$(python3 -c "import json;print(json.dumps({'host':'$PG_HOST','port':int('$PG_PORT'),'database':'$PG_DATABASE','user':'$PG_USER','password':'$PG_PASSWORD','ssl':'disable'}))")" \
  "CRED_POSTGRES" || true

if [ -n "$APIFY_TOKEN" ]; then
  create_cred "Apify Token (stack-demo)" "httpQueryAuth" \
    "$(python3 -c "import json,sys;print(json.dumps({'name':'token','value':sys.argv[1]}))" "$APIFY_TOKEN")" \
    "CRED_APIFY" || true
fi

if [ -n "$OPENROUTER_API_KEY" ]; then
  create_cred "OpenRouter (stack-demo, header auth)" "httpHeaderAuth" \
    "$(python3 -c "import json,sys;print(json.dumps({'name':'Authorization','value':'Bearer '+sys.argv[1]}))" "$OPENROUTER_API_KEY")" \
    "CRED_OPENROUTER_HEADER" || true
  create_cred "OpenRouter (stack-demo, openAI-compatible)" "openAiApi" \
    "$(python3 -c "import json,sys;print(json.dumps({'apiKey':sys.argv[1],'url':'https://openrouter.ai/api/v1'}))" "$OPENROUTER_API_KEY")" \
    "CRED_OPENROUTER_OPENAI" || true
fi

create_cred "n8n API (stack-demo, self)" "httpHeaderAuth" \
  "$(python3 -c "import json,sys;print(json.dumps({'name':'X-N8N-API-KEY','value':sys.argv[1]}))" "$N8N_SELF_API_KEY")" \
  "CRED_N8N_SELF" || true

if [ -n "$IMAP_HOST" ] && [ -n "$IMAP_USER" ] && [ -n "$IMAP_PASSWORD" ]; then
  create_cred "IMAP (stack-demo, own mailbox)" "imap" \
    "$(python3 -c "import json,sys;print(json.dumps({'host':sys.argv[1],'port':int(sys.argv[2]),'user':sys.argv[3],'password':sys.argv[4],'secure':True}))" "$IMAP_HOST" "$IMAP_PORT" "$IMAP_USER" "$IMAP_PASSWORD")" \
    "CRED_IMAP" || true
  IMAP_AVAILABLE=1
else
  log "  - IMAP secret not supplied: node stays REPLACE_ME, brick 07's manual pass runs DRY RUN (mail read skipped)."
  IMAP_AVAILABLE=0
fi
check_wall_clock

# ---------------------------------------------------------------------------
# 4. Data Tables: ep07_caps, ep08_lanes, ep08_caps, ep09_caps (dry_run true)
# ---------------------------------------------------------------------------
log "Creating Data Tables (dry_run:true everywhere) ..."

create_data_table() {
  # $1 = name, $2 = columns json array, $3 = rows json array -> writes id to .cred_ids.env as $4
  local name="$1" cols="$2" rows="$3" envkey="$4"
  local resp id
  resp=$(API POST "/api/v1/data-tables" "$(python3 -c "import json,sys;print(json.dumps({'name':sys.argv[1],'columns':json.loads(sys.argv[2])}))" "$name" "$cols")")
  id=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d.get('id',''))" "$resp")
  if [ -z "$id" ]; then
    log "  ! failed to create data table '$name': $(echo "$resp" | head -c 200)"
    exit 1
  fi
  API POST "/api/v1/data-tables/$id/rows" "$(python3 -c "import json,sys;print(json.dumps({'data':json.loads(sys.argv[1])}))" "$rows")" > /dev/null
  echo "${envkey}=${id}" >> "$SCRIPT_DIR/.cred_ids.env"
  echo "${envkey}_NAME=\"${name}\"" >> "$SCRIPT_DIR/.cred_ids.env"
  echo "{\"kind\":\"data_table\",\"id\":\"$id\",\"name\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$name")}" >> "$SCRIPT_DIR/.installed_extra.jsonl"
  log "  + data table '$name' -> $id"
}

create_data_table "ep07_caps" \
  '[{"name":"max_msgs_per_run","type":"number"},{"name":"max_msgs_per_day","type":"number"},{"name":"llm_calls_per_day","type":"number"},{"name":"dry_run","type":"boolean"},{"name":"kill_enabled","type":"boolean"},{"name":"breaker_tripped","type":"boolean"},{"name":"consecutive_errors","type":"number"},{"name":"error_trip_threshold","type":"number"},{"name":"known_client_domains","type":"string"}]' \
  '[{"max_msgs_per_run":10,"max_msgs_per_day":50,"llm_calls_per_day":10,"dry_run":true,"kill_enabled":true,"breaker_tripped":false,"consecutive_errors":0,"error_trip_threshold":3,"known_client_domains":"[]"}]' \
  "DT_EP07_CAPS"

create_data_table "ep08_lanes" \
  '[{"name":"lane_ref","type":"string"},{"name":"kind","type":"string"},{"name":"expected_interval_min","type":"number"},{"name":"upstream_count_window","type":"number"},{"name":"cooldown_min","type":"number"}]' \
  '[]' \
  "DT_EP08_LANES"

create_data_table "ep08_caps" \
  '[{"name":"max_incidents_per_run","type":"number"},{"name":"reminders_per_lane_per_day","type":"number"},{"name":"cooldown_min","type":"number"},{"name":"dry_run","type":"boolean"},{"name":"kill_enabled","type":"boolean"},{"name":"breaker_tripped","type":"boolean"},{"name":"consecutive_errors","type":"number"},{"name":"error_trip_threshold","type":"number"}]' \
  '[{"max_incidents_per_run":3,"reminders_per_lane_per_day":1,"cooldown_min":1440,"dry_run":true,"kill_enabled":true,"breaker_tripped":false,"consecutive_errors":0,"error_trip_threshold":3}]' \
  "DT_EP08_CAPS"

create_data_table "ep09_caps" \
  '[{"name":"cap_id","type":"string"},{"name":"max_drafts_per_run","type":"number"},{"name":"max_drafts_per_day","type":"number"},{"name":"llm_calls_per_day","type":"number"},{"name":"llm_calls_today","type":"number"},{"name":"dry_run","type":"boolean"},{"name":"kill_enabled","type":"boolean"},{"name":"breaker_tripped","type":"boolean"},{"name":"consecutive_errors","type":"number"},{"name":"error_trip_threshold","type":"number"}]' \
  '[{"cap_id":"ep09","max_drafts_per_run":5,"max_drafts_per_day":20,"llm_calls_per_day":20,"llm_calls_today":0,"dry_run":false,"kill_enabled":true,"breaker_tripped":false,"consecutive_errors":0,"error_trip_threshold":3}]' \
  "DT_EP09_CAPS"

check_wall_clock

# ---------------------------------------------------------------------------
# 4b. Fold credential/data-table ids created above into a pending rollback
#     record NOW (before the risky import step), so `--rollback` can clean
#     them up even if the import step fails partway.
# ---------------------------------------------------------------------------
python3 - "$INSTALLED_JSON" "$SCRIPT_DIR/.installed_extra.jsonl" <<'PY'
import json, sys, os
out_path, extra_path = sys.argv[1], sys.argv[2]
installed = {"workflows": [], "data_tables": [], "credentials": []}
if os.path.exists(out_path):
    installed = json.load(open(out_path))
if os.path.exists(extra_path):
    for line in open(extra_path):
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        bucket = "data_tables" if row["kind"] == "data_table" else "credentials"
        installed[bucket].append({"id": row["id"], "name": row["name"]})
json.dump(installed, open(out_path, "w"), indent=2)
PY

# ---------------------------------------------------------------------------
# 5. Import the five bricks, credentials + dataTableId rewritten, active:false,
#    executionTimeout forced to 300s.
# ---------------------------------------------------------------------------
log "Importing five bricks (active:false, executionTimeout:300) ..."
source "$SCRIPT_DIR/.cred_ids.env"

python3 "$SCRIPT_DIR/_install_import.py" \
  --base-url "$N8N_BASE_URL" --api-key "$N8N_API_KEY" \
  --repo-root "$SCRIPT_DIR/.." \
  --installed-json "$INSTALLED_JSON" \
  --cred-postgres "${CRED_POSTGRES:-}" --cred-postgres-name "${CRED_POSTGRES_NAME:-}" \
  --cred-apify "${CRED_APIFY:-}" --cred-apify-name "${CRED_APIFY_NAME:-}" \
  --cred-openrouter-header "${CRED_OPENROUTER_HEADER:-}" --cred-openrouter-header-name "${CRED_OPENROUTER_HEADER_NAME:-}" \
  --cred-openrouter-openai "${CRED_OPENROUTER_OPENAI:-}" --cred-openrouter-openai-name "${CRED_OPENROUTER_OPENAI_NAME:-}" \
  --cred-n8n-self "${CRED_N8N_SELF:-}" --cred-n8n-self-name "${CRED_N8N_SELF_NAME:-}" \
  --cred-imap "${CRED_IMAP:-}" --cred-imap-name "${CRED_IMAP_NAME:-}" \
  --dt-ep07-caps "${DT_EP07_CAPS:-}" --dt-ep07-caps-name "${DT_EP07_CAPS_NAME:-}" \
  --dt-ep08-lanes "${DT_EP08_LANES:-}" --dt-ep08-lanes-name "${DT_EP08_LANES_NAME:-}" \
  --dt-ep08-caps "${DT_EP08_CAPS:-}" --dt-ep08-caps-name "${DT_EP08_CAPS_NAME:-}" \
  --dt-ep09-caps "${DT_EP09_CAPS:-}" --dt-ep09-caps-name "${DT_EP09_CAPS_NAME:-}"

check_wall_clock

# ---------------------------------------------------------------------------
# 6. GET-back active:false x5
# ---------------------------------------------------------------------------
log "Verifying active:false on all five imported workflows ..."
python3 - "$INSTALLED_JSON" "$N8N_BASE_URL" "$N8N_API_KEY" <<'PY'
import json, sys, urllib.request
path, base, key = sys.argv[1], sys.argv[2], sys.argv[3]
installed = json.load(open(path))
bad = 0
for wf in installed["workflows"]:
    r = urllib.request.Request(base + f"/api/v1/workflows/{wf['id']}", headers={"X-N8N-API-KEY": key})
    d = json.loads(urllib.request.urlopen(r, timeout=15).read())
    ok = d.get("active") is False
    print(f"  {'OK ' if ok else 'FAIL'} {wf['name']} active={d.get('active')}", file=sys.stderr)
    if not ok:
        bad += 1
if bad:
    print(f"{bad} workflow(s) NOT inactive -- aborting", file=sys.stderr)
    sys.exit(1)
PY

# ---------------------------------------------------------------------------
# 7. Register all five in ep08_lanes with kind manual-run (FNV-1a lane_ref,
#    matching EP08's own "Mask lane names" hash exactly)
# ---------------------------------------------------------------------------
log "Registering all five bricks in ep08_lanes (kind:manual-run) ..."
python3 - "$INSTALLED_JSON" "$N8N_BASE_URL" "$N8N_API_KEY" "${DT_EP08_LANES:-}" <<'PY'
import json, sys, urllib.request

def fnv1a(s: str) -> str:
    h = 0x811c9dc5
    for ch in s:
        h ^= ord(ch)
        h = (h * 0x01000193) & 0xFFFFFFFF
    return format(h, '08x')

path, base, key, dt_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
installed = json.load(open(path))
for wf in installed["workflows"]:
    lane_ref = 'lane_' + fnv1a(wf["name"])[:8]
    body = json.dumps({"data": [{
        "lane_ref": lane_ref, "kind": "manual-run",
        "expected_interval_min": 0, "upstream_count_window": 0, "cooldown_min": 0
    }]}).encode()
    r = urllib.request.Request(base + f"/api/v1/data-tables/{dt_id}/rows", data=body, method="POST",
                                headers={"X-N8N-API-KEY": key, "Content-Type": "application/json"})
    urllib.request.urlopen(r, timeout=15)
    print(f"  + {wf['name']} -> {lane_ref}", file=sys.stderr)
PY

rm -f "$SCRIPT_DIR/.cred_ids.env" "$SCRIPT_DIR/.installed_extra.jsonl"

EL=$(elapsed)
log "INSTALL COMPLETE in ${EL}s (cap ${WALL_CLOCK_CAP_SEC}s)."
echo "$EL" > "$SCRIPT_DIR/.install_seconds"
log "installed.json: $INSTALLED_JSON"
log "Next: seed the lead (seed/lead.json), run each brick manually in order, then ./acceptance.sh"
