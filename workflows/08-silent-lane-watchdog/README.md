# 08 -- Silent-lane watchdog (obligation, not elapsed time)

`EP08 · Silent-lane watchdog` -- 18 nodes (16 working nodes + 2 sticky notes).

<!-- QC R1 fix M14 (2026-09-25): the old title/name claimed a specific dead-lane
gap-length figure the DB does not support (see "Real-incident lookup" below --
the oldest retained execution row is 8 days newer than the date the gap would
need). -->

An n8n lane can stop doing its job while the execution log stays green -- a
schedule that never fires again, a webhook lane whose upstream table quietly
stopped filling, a mail poller stuck on an old cursor. **0 errors is not the
same as healthy.** This workflow reads the estate's own workflow list, works
out per-lane whether an OBLIGATION was actually missed (not just "has it run
recently"), and opens a Postgres incident only for a genuine miss -- never for
a lane that is quiet because it has no demand, is switched off, or simply has
no saved success to measure yet.

**Zero LLM nodes.** **Client names never stored or rendered** -- the very
first Code node after the API pull hashes every real workflow name into a
pseudonymous `lane_ref` and drops the name; everything downstream, on screen
or in Postgres, only ever sees `lane_9f2a1c30`.

## The doctrine this episode teaches

Three ways a lane can be quiet and perfectly healthy (`feedback-silence-is-not-failure`):

1. **No saved successes on record** -- the probe itself is unmeasurable. Never
   claim silence off an absent number; say "could not measure".
2. **Demand-driven, no demand** -- an event-driven lane (a webhook) with zero
   upstream arrivals in the window has nothing to have run. Zero runs is
   correct, not silent.
3. **Switched off** -- `active:false` is a decision, not a failure.

This workflow encodes all three as explicit branches in `Evaluate obligation`,
never as an afterthought bolted onto an elapsed-time check.

## Flow, node by node

```
Every 6 hours (Schedule, DISABLED)      Swap point for a real poller.
Manual Test (Manual Trigger)            The sanctioned way to run this workflow.
   |
List workflows (HTTP GET)               {N8N_HOST}/api/v1/workflows?active=true,
                                         httpHeaderAuth credential. Returns full
                                         workflow objects (nodes included) -- this
                                         is why masking happens in the VERY NEXT node.
   |
Mask lane names (Code)                  FIRST thing that touches the pull. FNV-1a
                                         hash of the real name -> lane_ref, e.g.
                                         "lane_08fdd007". The real name is never
                                         assigned to any field kept past this node.
                                         Sample-mode items (samples/lanes-sample.json)
                                         pass through as already-synthetic lane_refs.
   |
Load expectations (Data Table get)      ep08_lanes: one row per monitored lane_ref
                                         -- kind, expected_interval_min,
                                         upstream_count_window, cooldown_min. A
                                         lane with no row here is never evaluated
                                         (action: none, "no expectation configured").
   |
Last success per lane (Postgres)        Read-only aggregate over execution_entity:
                                         max(startedAt) filter success, and a 7-day
                                         success count, grouped by workflowId.
   |
Load caps (Data Table get)              ep08_caps: the one-row cap sheet.
   |
Evaluate obligation (Code)              Per lane: off -> none. manual-run -> never
                                         an incident, reminder_manual if overdue.
                                         scheduled -> missed if minutes since last
                                         success > expected_interval_min (never
                                         missed if unmeasurable). event-driven ->
                                         missed only if upstream_count_window > 0
                                         AND runs = 0. upstream-count -> missed if
                                         runs < upstream_count_window. A missed
                                         lane becomes 'open' only if kill_enabled,
                                         the breaker isn't tripped (self-computed:
                                         consecutive_errors >= error_trip_threshold
                                         OR the stored flag), and
                                         incidents_this_run < max_incidents_per_run
                                         -- otherwise it's guard-blocked, action none.
                                         A non-missed monitored lane is 'recover'
                                         (idempotent close attempt, harmless if
                                         nothing was open).
   |
Write whitelist gate (Code)             Only {open, recover, reminder_manual, none}
                                         may pass. Anything else -- including a
                                         fabricated {action:'delete'} -- throws and
                                         refuses to write. See REFUTE-FIRST below.
   |
Route (Switch on action)          \
   open -> Open or remind incident       INSERT ... ON CONFLICT (idempotency_key)
                                          DO UPDATE SET reminded_at = now(). The key
                                          is ep08:<lane_ref>:<date> -- a same-day
                                          re-open becomes a reminder automatically,
                                          a new day opens a fresh row. This is also
                                          how reminders_per_lane_per_day is enforced
                                          structurally, not by a lookup.
   recover -> Recover                    UPDATE ... SET status='closed' WHERE
                                          lane_ref=$1 AND status='open'. No-op if
                                          nothing was open.
   (open) -> Post to Slack (DISABLED)    Swap point. Never enabled on this instance.
   |
Evaluate obligation -> Run summary (Code, parallel branch)
                                         Journals EVERY lane's verdict (including
                                         healthy/off/unmeasurable/reminder) plus a
                                         run-level rollup.
   |
Insert lane checks (Postgres)           jsonb_to_recordset insert -> ep08_lane_checks,
                                         one row per lane per run. This is the
                                         "0 errors is not health" evidence table.
   |
Insert run summary (Postgres)           One row -> ep08_run_summary.
```

## Cap sheet (`ep08_caps`, one row, VPS copy)

`max_incidents_per_run 3 · reminders_per_lane_per_day 1 (structural, via the
daily idempotency key) · cooldown_min 1440 · dry_run true · kill_enabled true ·
breaker_tripped false · consecutive_errors 0 · error_trip_threshold 3`.
`executionTimeout` on the workflow is 120s. See `data-table-spec.md` for both
Data Table schemas.

## Live proof run (this instance, 2026-09-24, DRY RUN)

Deployed inactive, then run manually once via n8n's internal run API (public
API has no execute endpoint; a UI session cookie was minted on-box for the
owner account per `reference-n8n-mint-ui-session-token`, this instance only).
`ep08_lanes` carried three rows for this run: the real (masked) lane_ref for
`LG-DEMO Speed-to-Lead` configured `event-driven, upstream_count_window: 0`
(the genuinely quiet webhook lane), the real (masked) lane_ref for `LG-04 Maps
Harvest` configured `scheduled, expected_interval_min: 60` (a deliberately
tight DEMO threshold -- LG-04 is not actually on a 60-minute SLA; this proves
the missed-obligation path against a real, undoctored execution history
without fabricating a fake workflow), and one placeholder row from an earlier
hashing bug in this session's own tooling (harmless dead entry, never matched
by any real workflow -- see Build notes).

Result, execution 34597, `status: success`:

| lane (masked)   | real lane             | kind         | missed | action                                                                     |
| --------------- | --------------------- | ------------ | ------ | -------------------------------------------------------------------------- |
| `lane_08fdd007` | LG-DEMO Speed-to-Lead | event-driven | false  | recover -- **0 incidents**, upstream=0 runs=0, "quiet is not failure here" |
| `lane_da8c5758` | LG-04 Maps Harvest    | scheduled    | true   | open -- **1 incident row**, `minutes_since_success=1240 expected=60`       |

`ep08_run_summary` for this run: `lanes_evaluated 63 · missed_count 1 ·
incidents_opened 1 · incidents_recovered 1 · reminders_sent 0`. Confirmed 0
real workflow names anywhere in `ep08_*` tables after the run
(`select count(*) from ep08_lane_checks where note ~* 'lg-demo|lg-08|hm-03|...'`
-> 0). This satisfies the done-bar: a manual DRY RUN producing >=1 incident row
for a lane whose obligation was missed, and 0 incidents for a quiet
event-driven lane.

An **offline harness** (`samples/lanes-sample.json` + the exact shipped
`jsCode`, `node --check`-verified) additionally exercises all 4 `kind`s and
the unmeasurable/off/guard edge cases end to end without touching the VPS --
see GOTCHAS.

## REFUTE-FIRST (proven, not asserted)

1. **Event-driven, 0 upstream, 0 runs -> no incident.** `lane_03` in the
   sample fixture and `lane_08fdd007` (LG-DEMO) live both resolve to
   `action: recover`, never `open`.
2. **A fabricated `{action:'delete'}` fed into `Write whitelist gate` throws**
   and refuses to write:
   `Write whitelist gate: action "delete" is not on the allowlist
(open|recover|reminder_manual|none). Refusing to write for lane lane_99.`

## Real-incident lookup (read-only, for the card)

- **LG-08 (IMAP inbox lane) retention:** `execution_entity` on this instance
  currently retains `min(startedAt) = 2026-09-16`, `max = 2026-09-24`,
  `10079` rows for an 8-day window -- **not** the ~10k-rows/2.4-weeks figure
  memory carried. A six-day gap around 2026-09-04 is **not visible** -- the
  oldest row on record is 8 days newer than that date. Answer: **no, the gap
  is not visible; retention starts 2026-09-16, the incident (if real) is
  pruned.**
- **LG-DEMO Speed-to-Lead classification:** confirmed `active:true`,
  `webhook`-triggered only (`Web Lead In`, `Homeowner Reply In`, `State In` --
  no schedule trigger anywhere in its nodes), last execution `2026-09-17
08:15:38 UTC`, 0 runs in the 7 days before this check. This workflow's own
  evaluator classifies it `event-driven`, `upstream=0 runs=0` -> **action:
  recover, 0 incidents** -- confirmed both in the live run (real masked
  lane_ref `lane_08fdd007`) and the offline fixture (`lane_03`). This is
  exactly the on-screen false-alarm story: a naive elapsed-time watchdog would
  flag this lane; this one correctly doesn't.

## Build notes (deviations from the brief, autonomous decisions)

- **Two Data Tables**, `ep08_lanes` (expectations) + `ep08_caps` (cap sheet),
  per the brief's "your call" option -- kept them separate so the expectation
  table can grow without touching the cap sheet's single row.
- **`remind` collapsed into `open` via `ON CONFLICT ... DO UPDATE`.** The
  brief describes `open -> remind at cooldown -> recover`. Because the
  idempotency key is date-scoped (`ep08:<lane_ref>:<date>`) and
  `cooldown_min` is 1440 (one day), a same-day re-open and a reminder are the
  same database operation -- an upsert. This removed one node (no separate
  "open incidents lookup" read before deciding) without changing the observed
  behavior: first miss in a day opens, a second evaluation the same day
  updates `reminded_at`, a new day opens fresh.
- **`breaker_tripped` is computed, not just read.** `Evaluate obligation`
  treats the breaker as tripped when `consecutive_errors >=
error_trip_threshold`, in addition to the stored boolean -- this is what
  makes the breaker rehearsal (below) work without a human flipping a flag.
- **The `List workflows` HTTP node's `active=true` pull returns FULL workflow
  objects, including every node's `parameters` (jsCode, SQL, everything).**
  This is an n8n 2.33.7 public-API behavior, not a request option here. It is
  exactly why masking is the very next node and nothing upstream of it is
  ever written to Postgres or rendered -- the raw pull briefly exists only in
  that one node's in-memory output for the duration of the execution.
- **One dead Data Table row.** An early debugging step in this session
  inserted `ep08_lanes` row `lane_ref: lane_e0459cc6` based on a buggy
  offline (Python) reimplementation of the hash function that did not match
  the real (JavaScript) `stableHash` in the shipped Code node -- discovered by
  comparing live execution output against the offline computation. The
  correct hash for that same workflow is `lane_08fdd007` (added as a second
  row). The `lane_e0459cc6` row is harmless -- no real workflow name will
  ever hash to it -- and is left in place rather than risk an undocumented
  write path (the public Data Table API here has no row-level PATCH/PUT/DELETE
  by id; only whole-table row inserts and a filter-based bulk delete, which
  this session declined to use mid-investigation to avoid touching the wrong
  row under time pressure).
- **Manual proof-run used the internal `/rest/workflows/{id}/run` API**, not
  the UI, per `reference-n8n-mint-ui-session-token` (owner-account cookie,
  minted on-box, this instance only -- never used against Takycorp or any
  client n8n).

## GOTCHAS

- **The watchdog calls its own instance; set `n8n_base_url`.** `List workflows`
  reads its target scheme+host from `ep08_caps.n8n_base_url` (via `Load caps`,
  now the first node after the triggers) instead of a hardcoded scheme --
  every deployed copy of this workflow points at a DIFFERENT n8n instance, so
  every deployed copy needs its OWN `n8n_base_url` row value (its own
  scheme+host, no trailing slash). Falls back to `http://localhost:5678` in
  the expression itself if the column is empty or missing. See
  `data-table-spec.md`.
- **0 errors is not health.** `ep08_lane_checks` is the evidence table --
  read it to see what was actually checked (including every lane correctly
  judged healthy/off/unmeasurable), not just `ep08_incidents`, which only
  ever holds genuine misses.
- **Event-driven lanes need an `upstream_count_window`, not just a last-run
  timestamp.** A webhook lane with zero arrivals has nothing to run; treating
  "0 runs" alone as silence is the exact false-alarm this workflow exists to
  avoid (see our own earlier watchdog's day-one 3-false-alert incident, which
  motivated this rebuild).
- **`execution_entity` retention is short on this instance (~8 days as of
  this build)**, not the ~2.4 weeks memory assumed -- a real silent-lane
  incident older than that is invisible to any watchdog reading this table.
  Retention, not the watchdog logic, is the limiting factor for how far back
  a genuine incident can be proven.
- **`manual-run` lanes never open an incident**, by construction -- there is
  no code path from `kind: 'manual-run'` to `action: 'open'`. Overdue
  manual-run lanes only ever produce `reminder_manual`, journalled to
  `ep08_lane_checks`.
- **The public Data Table row API has no per-row update/delete by id** on
  this n8n version (`PATCH`/`PUT`/`DELETE /data-tables/{id}/rows/{rowId}` all
  404/405) -- only bulk insert and a filter-based delete on the collection
  endpoint. Plan expectation-table edits as insert-a-new-row-and-ignore-the-old
  during a build session, and do the real cleanup by hand in the n8n UI.
- **n8n's public API `GET /workflows?active=true` returns full node bodies**,
  not a summary -- treat every such pull as sensitive until masked, the same
  session it's fetched in.
- box is n8n **2.33.7** -- the node on the canvas is the plain "Schedule Trigger" (the 2.36+ scheduler feature is not used or claimed).

## Install it for your business

This workflow is free and MIT-licensed: `github.com/waseemnasir2k26/n8n-workflows`.
We install and tune the lane list, thresholds and the Slack hookup on your own
n8n for your own estate.

WhatsApp +92 300 1001957 -- Waseem Nasir, SkynetLabs.
Hire SkynetLabs, our Top Rated agency on Fiverr:
https://www.fiverr.com/agencies/skynetjoellc

Send us your workflow list and get a free silence report.
