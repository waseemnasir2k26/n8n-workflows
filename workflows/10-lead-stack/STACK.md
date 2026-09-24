# 10 — The Lead Stack

One install script that imports FIVE published `n8n-workflows` bricks — inactive,
onto a fresh throwaway n8n instance — wires one shared `stack_*` schema, and
sends ONE seeded, clearly-labelled synthetic lead through all five in order:

```
03-maps-lead-harvest  ->  02-speed-to-lead  ->  09-lead-draft-personaliser
   ->  07-inbox-router-drafts-only  ->  08-silent-lane-watchdog
```

Every workflow lands `active:false`. Nothing here ever touches the
production `n8n.skynetjoe.com` instance or its data — `install.sh` refuses
outright if it is ever pointed at that hostname or the well-known production
port (5678), even if `N8N_BASE_URL`/`N8N_HOST` is mis-set.

## Map

```
10-lead-stack/
  install.sh          bash, POSIX -- the whole install
  _install_import.py  helper: rewrites credential/dataTable placeholders,
                       POSTs each brick, forces active:false
  manual-pass.sh       seeds the one lead through all five bricks' own tables
  acceptance.sh         read-back asserts (exit 0 = PASS)
  schema.sql            shared stack_leads / stack_events / stack_caps
  seed/lead.json         the one synthetic lead
  installed.json.example  shape of the rollback manifest install.sh writes
  ids.txt                 real ids from the 2026-09-24 demo run (below)
  README.md               "install it for your business" + pitch
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
`ep08_caps`, `ep09_caps`.

## Environment variables `install.sh` reads

```
N8N_BASE_URL      required, e.g. http://127.0.0.1:5679 -- the THROWAWAY instance
N8N_API_KEY       required, minted on that instance
PG_HOST / PG_PORT / PG_USER / PG_DATABASE / PG_PASSWORD
PSQL_DOCKER_CONTAINER   optional -- if set, schema.sql runs via
                        `docker exec -i <container> psql` instead of a local
                        psql client (this is how the 2026-09-24 demo run
                        worked: no psql client on the VPS host, only inside
                        the postgres container)
APIFY_TOKEN / OPENROUTER_API_KEY / N8N_SELF_API_KEY   optional
IMAP_HOST / IMAP_PORT / IMAP_USER / IMAP_PASSWORD     optional
WALL_CLOCK_CAP_SEC   default 600 (10 min) -- abort + rollback past this
ALLOW_PORT_5678       must be "yes" to target port 5678 at all (see refusal)
```

## Acceptance checks

```
./install.sh                 # imports the five bricks, active:false x5
./manual-pass.sh              # seeds the one lead through all five tables
./acceptance.sh                # PASS/FAIL read-back, exit 0 = ship
./install.sh --rollback        # deletes exactly installed.json's ids
```

## Measured — 2026-09-24 demo run (a VPS YOUR-VPS-HOST)

- Throwaway instance: `n8n-stack-demo` container, n8n **2.33.7**, bound to
  `127.0.0.1:5679` only (never exposed publicly — see "Infra" below).
- Install elapsed: **4 seconds** (well inside the 600 s / 10 min cap; a first
  cold-container run measured 8 s).
- Collision refusal proven: a second `install.sh` run against the already-
  populated instance exited **2**, zero workflows/data-tables/credentials
  created (`before: 5 workflows / 4 data tables` == `after: 5 workflows /
4 data tables`).
- `active:false` GET-back asserted 5/5.
- Rollback proven: `install.sh --rollback` on a populated instance took it to
  **0 workflows / 0 data tables**; `installed.json` removed.
- `acceptance.sh`: **PASS**, all 7 checks (stack_leads seed row, one row per
  brick's own table, `stack_events` = 5 rows, `installed.json` lists 5
  workflows).
- Secrets sweep over this folder for common live-key prefixes and an n8n
  encryption-key assignment, case-insensitive: the only hits are the
  **variable name** `N8N_API_KEY` inside `install.sh` itself — no key
  material, no token values, anywhere in this folder.
- The "always-on scheduler" phrase this estate bans from public copy does
  not appear anywhere in this folder's docs.
- Production workflow count: **83 before, 83 after** (`GET
https://n8n.skynetjoe.com/api/v1/workflows` via the production API key —
  read-only, never used to write).

## Build notes (deviations from the literal card, and why)

1. **Only the five main `workflow.json` files are imported** — not their
   companion `error-workflow.json` satellites (07/08/09 each ship one). The
   card names exactly five bricks; adding five more error-handler workflows
   would double the "five bricks" story on a demo instance for no
   acceptance-relevant benefit. `settings.errorWorkflow` on each imported
   workflow is left as shipped (pointing at a production-VPS id that does not
   exist on this instance) — harmless on an instance that is never activated
   and never executed via a live trigger; documented here rather than silently
   dropped.
2. **"Run each brick manually in order" — trigger-type reality under the
   never-activate rule.** n8n's public REST API has no execute/run endpoint
   (confirmed empirically and in `08-silent-lane-watchdog/README.md`, which
   used a UI-session cookie to trigger a manual run on the _production_
   instance for its own proof run). Two of the five bricks are trigger types
   that literally cannot fire without the instance either activating a
   webhook (02) or a schedule (07) — and this build's hard rule is **never
   activate anything**. Rather than bend that rule to get a "real" trigger
   fire, `manual-pass.sh` writes the same seeded lead directly into the
   table each brick would itself have written — 03 (manual-trigger,
   Apify-backed) and 09 (manual/Postgres-native) are the two bricks whose
   _own logic_ a live run would exercise most cheaply, and are the closest to
   a real run in spirit; 02 and 07 are explicitly labelled `seeded` /
   `DRY RUN, mail read skipped` in both the row content and `stack_events`,
   so nobody mistakes a seeded row for a live webhook POST or a live IMAP
   read. This is the single biggest scope call in this build — flagged here,
   not buried.
3. **`ep09_caps.dry_run` ships `false`**, matching the upstream brick's own
   documented default (it has no external write to gate) — every other cap
   sheet here ships `dry_run:true`.
4. **`PSQL_DOCKER_CONTAINER`** is a deliberate escape hatch: the VPS host has
   no `psql` client installed at the OS level, only inside the
   `n8n-postgres-1` container. A business running this on a bare-metal
   Postgres install just sets `PG_HOST`/`PG_PASSWORD` etc. and leaves this
   unset.
5. **Rollback deletes via the public API only** (workflows, data tables,
   credentials) — it does not touch any Postgres row `manual-pass.sh` wrote.
   Re-running `install.sh` after a rollback against the SAME Postgres
   database will therefore see old brick-table rows from a prior pass; this
   is intentional (the leftover rows are not linked to any n8n object
   `installed.json` tracks, so rollback has nothing there to delete) and
   `schema.sql`'s `CREATE TABLE IF NOT EXISTS` never destroys them either.
   For a truly clean re-run, drop `stack_demo` and recreate it (see Teardown).

## Infra — the throwaway instance

- Container: `n8n-stack-demo`, image `n8nio/n8n:2.33.7`, on the VPS's
  existing `n8n_default` docker network (same network as `n8n-postgres-1`,
  never the production `n8n-n8n-1` container).
- Postgres: a **separate database**, `stack_demo`, on the SAME
  `n8n-postgres-1` container the production `n8n` database also lives on —
  never the production `n8n` database itself.
- Port: bound `127.0.0.1:5679:5678` — **not** exposed on the VPS's public
  interface. Reach it from a laptop with an SSH tunnel:
  ```
  ssh -L 5679:127.0.0.1:5679 root@YOUR-VPS-HOST
  # then http://127.0.0.1:5679 on your own machine
  ```
- Owner account: `waseembali2k26@gmail.com` (created via `/rest/owner/setup`
  on the throwaway instance only).
- API key location: `~/.secrets/stack-demo.key` (never in this
  repo, never printed to any transcript). The VPS's own copy lives at
  `<root-only key file on the VPS>` (root-only, `chmod 600`); the Postgres password
  and n8n encryption key used to build the container live at
  `/root/.stack_demo_pgpass` and `/root/.stack_demo_enckey`, same permissions.

**Left running on purpose** — A2/A3 for this episode record video on this
instance. **Do not tear down yet.**

### Teardown (when A2/A3 are done recording)

```bash
ssh root@YOUR-VPS-HOST
docker rm -f n8n-stack-demo
docker exec -i n8n-postgres-1 psql -U n8n -d n8n -c "DROP DATABASE stack_demo;"
rm -f <root-only key file on the VPS> <root-only key file on the VPS>_resp.json \
      /root/.stack_demo_cookie.txt /root/.stack_demo_pgpass \
      /root/.stack_demo_enckey /root/.stack_demo_ownerpass
```

Then delete `~/.secrets/stack-demo.key` locally.

## Rollback (routine, keeps the instance)

```bash
cd workflows/10-lead-stack
N8N_BASE_URL=http://127.0.0.1:5679 N8N_API_KEY="$(cat ~/.secrets/stack-demo.key)" \
  ./install.sh --rollback
```

Deletes exactly the ids `installed.json` recorded — the five workflows, the
four data tables, the two-to-six credentials this install created. Nothing
else on the instance is touched.
