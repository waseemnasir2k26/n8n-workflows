# 10 — The Lead Stack

One install script. Five published, free, MIT workflows from this repo —
`03-maps-lead-harvest`, `02-speed-to-lead`, `09-lead-draft-personaliser`,
`07-inbox-router-drafts-only`, `08-silent-lane-watchdog` — imported **inactive**
onto a fresh n8n instance, wired to one shared schema, with one seeded,
labelled synthetic lead run through all five in order to prove the chain
actually connects.

Most "workflow pack" listings on the big marketplaces are a folder of JSON
files with no published run behind any of them. This one ships five, each
with its own published episode and a receipt, chained on one table, with a
timed install and a read-back proof that every workflow lands `active:false`.

## What it does

```
03-maps-lead-harvest  ->  02-speed-to-lead  ->  09-lead-draft-personaliser
   ->  07-inbox-router-drafts-only  ->  08-silent-lane-watchdog
```

`install.sh` refuses on any workflow name collision (exit 2, zero changes),
creates the shared `stack_*` schema plus each brick's own tables, creates the
Data Tables the bricks need plus one shared `stack_caps` cap sheet, imports
all five with `executionTimeout:300` and forces `active:false`, imports one
shared `EP10 · Stack error handler` and wires it onto all five, GET-backs to
prove `active:false` throughout, and registers all five in `ep08_lanes` as
`kind:manual-run`. `manual-pass.sh` then runs each brick from its own manual
trigger for a real execution id. `install.sh --rollback` deletes exactly the
ids it created, including the shared Postgres tables.

Full map, credential checklist, and the measured 2026-09-24 demo run
(~5-6 second installs, collision refusal proven, rollback proven, real
execution ids on all five bricks, `acceptance.sh` PASS) are in
[`STACK.md`](./STACK.md).

## Quick start

```bash
cd workflows/10-lead-stack
export N8N_BASE_URL=http://127.0.0.1:5679   # a FRESH, THROWAWAY n8n only
export N8N_API_KEY=...                       # minted on that instance
export PG_HOST=... PG_PASSWORD=...           # or PSQL_DOCKER_CONTAINER=<container>
./install.sh
./manual-pass.sh
./acceptance.sh
```

## Install it for your business

WhatsApp +92 300 1001957 · Waseem Nasir, SkynetLabs
Hire SkynetLabs, our Top Rated agency on Fiverr: https://www.fiverr.com/agencies/skynetjoellc
github.com/waseemnasir2k26/n8n-workflows

Which of the five do you need running by Friday?
