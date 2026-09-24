# 10 — The Lead Stack

One install script that imports FIVE published `n8n-workflows` bricks — inactive,
onto a fresh throwaway n8n instance — wires one shared `stack_*` schema plus
one shared cap sheet plus one shared error handler, and runs ONE seeded,
clearly-labelled synthetic lead through all five, in order, via REAL manual
executions:

```
03-maps-lead-harvest  ->  02-speed-to-lead  ->  09-lead-draft-personaliser
   ->  07-inbox-router-drafts-only  ->  08-silent-lane-watchdog
```

Every workflow lands `active:false`. Nothing here ever touches the
production n8n instance or its data — `install.sh` refuses outright if it is
ever pointed at the production hostname or the well-known production port
(5678), even if `N8N_BASE_URL`/`N8N_HOST` is mis-set.

## Map

```
10-lead-stack/
  install.sh              bash, POSIX -- the whole install
  _install_import.py      helper: rewrites credential/dataTable placeholders,
                           POSTs each brick + the error handler, forces
                           active:false, wires settings.errorWorkflow
  error-workflow.json      "EP10 · Stack error handler" -- Error Trigger ->
                           stack_events row + bump stack_caps.consecutive_errors
  manual-pass.sh           thin wrapper: runs each brick from its OWN manual
                           trigger via n8n's internal run API (real
                           execution ids) -- SQL seeding only behind
                           --seed-only, with a printed warning
  acceptance.sh            read-back asserts incl. >=1 real execution id per
                           brick (public API) -- exit 0 = PASS
  schema.sql               shared stack_leads / stack_events
  seed/lead.json           the one synthetic lead
  installed.json.example   shape of the rollback manifest install.sh writes
  ids.txt                  real ids from the 2026-09-24 demo run (below)
  README.md                "install it for your business" + pitch
```

## Credential checklist (throwaway instance only)

| Credential (created name)                    | Type           | Secret env var                                 | If absent                                                                                                                |
| -------------------------------------------- | -------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `Postgres (stack-demo)`                      | postgres       | `PG_PASSWORD` (+host/port/db/user)             | never absent — same db install writes the schema into                                                                    |
| `Apify Token (stack-demo)`                   | httpQueryAuth  | `APIFY_TOKEN`                                  | node keeps `REPLACE_ME`; 03 not runnable live                                                                            |
| `OpenRouter (stack-demo, header auth)`       | httpHeaderAuth | `OPENROUTER_API_KEY`                           | node keeps `REPLACE_ME`; 07's LLM classify step not runnable live                                                        |
| `OpenRouter (stack-demo, openAI-compatible)` | openAiApi      | `OPENROUTER_API_KEY`                           | node keeps `REPLACE_ME`; 09's LLM draft step not runnable live                                                           |
| `n8n API (stack-demo, self)`                 | httpHeaderAuth | `N8N_SELF_API_KEY` (defaults to `N8N_API_KEY`) | never absent                                                                                                             |
| `IMAP (stack-demo, own mailbox)`             | imap           | `IMAP_HOST`/`IMAP_USER`/`IMAP_PASSWORD`        | node keeps `REPLACE_ME`; 07's manual pass runs **DRY RUN, mail read skipped** (this is explicit and expected, not a bug) |

`Gmail (REPLACE_ME — swap point only)` on brick 07 is never touched — the node
ships `disabled: true` and the mailbox is IMAP, not Gmail.

Data Tables created with `dry_run:true` (except `ep09_caps`, which ships
`dry_run:false` to match the upstream brick's own default — it has no
external side effect to gate, see its README): `ep07_caps`, `ep08_lanes`,
`ep08_caps`, `ep09_caps`, **`stack_caps`** (one shared cap sheet: `cap_id`,
`dry_run`, `kill_enabled`, `breaker_tripped`, `consecutive_errors`,
`error_trip_threshold`, `max_actions_per_run`, `execution_timeout_note`).
One stack cap sheet + the bricks' own cap tables — never two Postgres tables
both named `stack_caps`; the shared one lives only as an n8n Data Table.

## Shared error handling

`error-workflow.json` ("EP10 · Stack error handler") is imported inactive
alongside the five bricks, then wired onto all five via `PUT
/api/v1/workflows/{id}` (4-key body: `name`, `nodes`, `connections`,
`settings.errorWorkflow`), with a GET-back `active:false` assert after every
PUT (a PUT can silently re-activate a workflow on this n8n version — see
`reference-n8n-api-patch-gotchas.md` item 12 — so this is asserted, not
assumed). Flow: `Error Trigger -> Log error (stack_events row) -> Read
stack_caps -> Bump stack_caps (consecutive_errors++, breaker_tripped once

> = error_trip_threshold)`.

**Honest limitation, proven, not glossed over:** n8n only fires
`settings.errorWorkflow` for **production**-mode executions (webhook/
schedule/trigger-fired), never for **manual** ones — and every execution
this install ever produces is manual, because activating a trigger is
permanently banned here. So the automatic wiring cannot be observed firing
from a real brick failure without breaking that rule. What IS proven, on
this run: the wiring itself (`settings.errorWorkflow` set + GET-back
`active:false` on all five), AND the handler's own logic, exercised directly
via the same internal run API used for the bricks (Error Trigger started
manually with a synthetic error payload) — execution succeeded, wrote a
`stack_events` row, and bumped `stack_caps.consecutive_errors` from 0 to 1,
confirmed via the public Data Table API. That is as far as "real, not
activated" can honestly go.

## Real manual executions (not SQL seeding)

`manual-pass.sh` runs each brick from its own manual-trigger path using the
same technique `08-silent-lane-watchdog`'s builder used for its own proof
run (owner session cookie + n8n's internal `POST /rest/workflows/{id}/run`
— see `reference-n8n-mint-ui-session-token.md`). Manual execution is
allowed; only activation is banned, and nothing here ever calls `/activate`.

| Brick                       | Start node                       | What actually happens                                                                                                                                                                                                                             |
| --------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 03-maps-lead-harvest        | `Click to run` (manual trigger)  | Real Apify Maps search, real poll loop, real Postgres upsert                                                                                                                                                                                      |
| 02-speed-to-lead            | `Web Lead In` (webhook)          | No manual-trigger sibling — armed via the internal run API (`waitingForWebhook:true`), then fired for real with an actual HTTP POST to the test-webhook URL carrying the seeded lead's fields                                                     |
| 09-lead-draft-personaliser  | `Manual Test` (built-in sibling) | Fans out to the GitHub sample leads AND `ep09_leads` (Postgres) — the seed row is inserted into `ep09_leads` first, so it is genuinely in the batch this run drafts against, real OpenRouter call                                                 |
| 07-inbox-router-drafts-only | `Manual Test` (built-in sibling) | The brick's OWN wiring routes `Manual Test` to `Load sample inbox`, never live IMAP — this is the brick's real, honest manual path, not a limitation added here; DRY RUN / mail-read-skipped is what "Manual Test" has always meant on this brick |
| 08-silent-lane-watchdog     | `Manual Test` (built-in sibling) | Calls the demo instance's own API via the real `n8n API (stack-demo, self)` credential, target base URL read from `ep08_caps.n8n_base_url` (fixed 2026-09-24, execution 24 success — see "Build notes" #5)                                        |

## Environment variables `install.sh` reads

```
N8N_BASE_URL      required, e.g. http://127.0.0.1:5679 -- the THROWAWAY instance
N8N_API_KEY       required, minted on that instance
PG_HOST / PG_PORT / PG_USER / PG_DATABASE / PG_PASSWORD
PSQL_DOCKER_CONTAINER   optional -- if set, schema.sql runs via
                        `docker exec -i <container> psql` instead of a local
                        psql client (used for the 2026-09-24 demo run: no
                        psql client on the host, only inside the postgres
                        container)
APIFY_TOKEN / OPENROUTER_API_KEY / N8N_SELF_API_KEY   optional
IMAP_HOST / IMAP_PORT / IMAP_USER / IMAP_PASSWORD     optional
WALL_CLOCK_CAP_SEC   default 600 (10 min) -- abort + rollback past this
ALLOW_PORT_5678       must be "yes" to target port 5678 at all (see refusal)
```

`manual-pass.sh` additionally reads `N8N_COOKIE_FILE` (a cookie jar
authenticated on the throwaway instance — the owner login used at build
time, never a production session).

## Acceptance checks

```
./install.sh                    # imports the five bricks + error handler, active:false x6
./manual-pass.sh                 # real manual executions, in order, all five
./acceptance.sh                   # PASS/FAIL read-back incl. execution ids, exit 0 = ship
./install.sh --rollback           # deletes exactly installed.json's ids + drops stack_* tables
```

## Measured — 2026-09-24 demo run

- Throwaway instance: n8n **2.33.7** container, bound to `127.0.0.1:5679`
  only (never exposed publicly — see "Infra" below).
- Install elapsed: **~5–6 seconds** across four separate clean runs this
  session (well inside the 600 s / 10 min cap).
- Collision refusal proven: a second `install.sh` run against an
  already-populated instance exits **2**, zero changes (workflow/data-table
  counts identical before and after).
- `active:false` GET-back asserted on all **6** imported workflows (five
  bricks + the error handler) — both at import time and again after the
  `PUT` that wires `settings.errorWorkflow` onto each brick.
- Rollback proven complete: `install.sh --rollback` on a populated instance
  took it from **6 workflows / 5 data tables** to **0 / 0**, dropped the
  `stack_leads` / `stack_events` Postgres tables, and removed
  `installed.json`.
- Real manual executions, one per brick, in order, this session's final run:
  03 → success, 02 → error (armed + fired via a real test-webhook POST; no
  Anthropic credential supplied to this demo, so it errors after writing a
  real row — see per-brick table above), 09 → success (real OpenRouter
  call), 07 → success (sample-inbox path, no live IMAP — the brick's own
  manual-trigger design), 08 → **error at execution 23** (its `List
workflows` node hardcoded `https://` and this demo container serves plain
  HTTP only — an environment TLS mismatch, not a stub), **fixed and re-run
  at execution 24 → success** (see "08 base-URL fix" below). All five have
  **real execution ids** confirmed via `GET /api/v1/executions?workflowId=`.
- The shared error handler's own logic verified separately (see "Shared
  error handling" above): real execution, `stack_events` row written,
  `stack_caps.consecutive_errors` 0 -> 1.
- `acceptance.sh`: **PASS**, all 12 checks (5 execution-id checks + 6
  table-row checks + installed.json sanity).
- Secrets sweep over this folder for common live-key prefixes and an n8n
  encryption-key assignment, case-insensitive: the only hit is the
  **variable name** `N8N_API_KEY` inside `install.sh` itself — no key
  material, no token values, anywhere in this folder.
- The "always-on scheduler" phrase this estate bans from public copy does
  not appear anywhere in this folder's docs.
- Production workflow count: **83 before, 83 after** this entire build
  (read-only `GET /api/v1/workflows` against the production API, never a
  write).

## Build notes (deviations from the literal card, and why)

1. **`ep09_caps.dry_run` ships `false`**, matching the upstream brick's own
   documented default (it has no external write to gate) — every other cap
   sheet here, including the new shared `stack_caps`, ships `dry_run:true`.
2. **`PSQL_DOCKER_CONTAINER`** is a deliberate escape hatch: the demo host
   has no `psql` client installed at the OS level, only inside the Postgres
   container. A business running this on a bare-metal Postgres install just
   sets `PG_HOST`/`PG_PASSWORD` etc. and leaves this unset.
3. **The error handler's automatic firing can't be observed live** without
   activating a trigger, which is permanently banned — see "Shared error
   handling" above for exactly what was and wasn't proven, and how.
4. **02's real run ends in `error`, not `success`**, because no Anthropic
   credential was supplied to this demo instance (none was available to this
   build). This is still a real execution with a real id, and the row it
   wrote before failing (`demo_sessions`) is real — matching this build's
   "real manual executions, not SQL seeding" bar even though the outcome is
   a failure.
5. **08's real run originally ended in `error`** (execution 23) for an
   environment reason: its self-referential `List workflows` node hardcoded
   `https://`, and this throwaway instance is deliberately plain HTTP (never
   exposed publicly, no TLS termination in front of it). **Fixed 2026-09-24
   in the brick itself** (this is a genuine upstream fix to
   `08-silent-lane-watchdog/workflow.json`, not a stack-only workaround):
   `List workflows` now reads its target scheme+host from a new
   `ep08_caps.n8n_base_url` column via `Load caps`, moved ahead of `List
workflows` in the node order, falling back to `http://localhost:5678` in
   the expression itself if the column is empty. This demo's `ep08_caps` row
   was set to `http://127.0.0.1:5678` (the container's own address) and the
   brick was re-run from `Manual Test` via the internal run API — execution
   **24, status success**, `List workflows` returned a real 200 workflow
   list, 0 node errors. See `08-silent-lane-watchdog/README.md` GOTCHAS and
   `data-table-spec.md`.
6. **Rollback deletes n8n objects via the public API AND drops the
   `stack_leads` / `stack_events` Postgres tables** it created — it does not
   touch each brick's OWN tables (`demo_sessions`, `ep03_leads`,
   `ep07_inbox`, `ep08_lane_checks`, `ep09_leads`/`ep09_drafts`), since those
   existed before this install and other tooling may depend on them
   surviving a rollback. For a fully fresh Postgres app-schema, drop and
   recreate the whole `stack_demo` database (see Teardown).

## Infra — the throwaway instance

- Container: `n8n-stack-demo`, image `n8nio/n8n:2.33.7`, on the same docker
  network as the demo Postgres container — never the production n8n
  container.
- Postgres: a **separate database**, `stack_demo`, on the SAME Postgres
  container the production `n8n` database also lives on — never the
  production `n8n` database itself.
- Port: bound `127.0.0.1:5679:5678` — **not** exposed on the host's public
  interface. Reach it with an SSH tunnel to the host that runs it:
  ```
  ssh -L 5679:127.0.0.1:5679 <the ops VPS>
  # then http://127.0.0.1:5679 on your own machine
  ```
- Owner account: created via `/rest/owner/setup` on the throwaway instance
  only, under the operator's own email.
- API key location: a local secrets file outside this repo (never
  committed, never printed to any transcript). The VPS's own copy lives in a
  root-only file (`chmod 600`), alongside a root-only file each for the
  Postgres password, the n8n encryption key, and the owner password used to
  build the container.

**Left running on purpose** — A2/A3 for this episode record video on this
instance. **Do not tear down yet.**

### Teardown (when A2/A3 are done recording)

On the VPS that hosts the throwaway container:

```bash
docker rm -f n8n-stack-demo
docker exec -i <postgres container> psql -U n8n -d n8n -c "DROP DATABASE stack_demo;"
# then remove the root-only secret files this build created for the
# throwaway instance (API key, cookie jar, Postgres password, encryption
# key, owner password) -- see the operator's own notes for exact paths.
```

Then delete the local copy of the demo API key.

## Rollback (routine, keeps the instance)

```bash
cd workflows/10-lead-stack
N8N_BASE_URL=http://127.0.0.1:5679 N8N_API_KEY="<the demo instance's own key>" \
  ./install.sh --rollback
```

Deletes exactly the ids `installed.json` recorded — the five bricks + the
error handler (six workflows), the five data tables (four per-brick + the
shared `stack_caps`), the credentials this install created — and drops the
`stack_leads` / `stack_events` Postgres tables. Nothing else on the instance
is touched.
