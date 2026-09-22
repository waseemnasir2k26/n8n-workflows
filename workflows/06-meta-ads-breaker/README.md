# 06 -- Meta Ads Circuit Breaker (pause-only write, Data Table caps)

`EP06 Meta Ads Circuit Breaker (pause-only, Data Table caps)` -- 20 nodes (18 working
nodes + 2 sticky notes).

A Meta ad set can keep spending under a paused parent campaign long after its own
flight window ends -- the campaign-pause does not touch the ad set's own
`configured_status`. This workflow reads that one ad set's insights on a schedule
(disabled here -- manual test only), evaluates three deterministic caps stored in an
n8n **Data Table** (`ep06_caps`, not a Postgres table), and if a cap is breached,
sends the **one and only write this workflow can make**: `POST /{adset_id}
status=PAUSED` at the Meta Graph API, behind a whitelist gate that builds the request
body itself. Every action gets a Postgres receipt.

**Zero LLM nodes.** **Zero client data** -- this workflow only ever points at our own
ad set; account and ad-set ids are masked before anything is stored, logged or
rendered. `ACCOUNT AND CAMPAIGN IDS MASKED · OUR OWN AD SET · NO CLIENT DATA`.

The last node emits one summary item read straight off the execution panel:
`rows_evaluated`, `none_count`, `trip_count`, `pause_count`, `actions_gated`,
`receipts_written`, `breaker_trips_written`, `dry_run`, and the observed spend/leads/
clicks/impressions for the row that was evaluated.

## Compliance -- the only write is a pause

`WRITE WHITELIST GATE` builds `{status:'PAUSED'}` from constants -- callers never
supply a body -- so the only body that can physically reach Meta is `PAUSED`. There
is no code path that can emit `ACTIVE`, a budget, a bid, targeting or creative. It
also refuses any object id that is not the one allowlisted ad set in the `ep06_caps`
Data Table row, so a corrupted or synthetic item (the disabled sample lane's rows
carry no raw id at all) can never reach a real Meta write. **PAUSE IS THE ONLY WRITE
IT CAN MAKE.**

`dry_run` in the caps row defaults `true` in this repo's reference deployment: no
Meta write is sent, and the receipt records `WOULD PAUSE -- DRY RUN` verbatim. Flip
it to `false` only after you understand exactly which ad set `adset_id` points at --
it is your one write allowlist entry.

This workflow is never left `active` on the instance. `Every 15 minutes` (Schedule
Trigger) ships disabled; the sanctioned way to run it is `Manual Test` from the
editor.

## Flow, node by node

```
Every 15 minutes (Schedule, DISABLED)   Swap point for a real poller.
Manual Test (Manual Trigger)            The sanctioned way to run this workflow.
   |
Load caps                               Data Table `get`: the one row from ep06_caps
                                         (thresholds, allowlisted adset_id, dry_run,
                                         kill_enabled, breaker_tripped, time_range_override).
   |
Build insights request                  Code (runOnceForAllItems): folds the armed-guard
                                         (kill_enabled && !breaker_tripped) into this node --
                                         a disarmed or already-tripped breaker returns ZERO
                                         items, and every node downstream naturally does
                                         nothing with no input. Builds the fetch URL and
                                         parses time_range_override into a real object.
   |                              \
Fetch insights (HTTP GET)          Load sample insights (HTTP GET, DISABLED)
  graph.facebook.com/{api_ver}/      Raw GitHub copy of samples/insights-sample.json,
  {adset_id}/insights, fields=       responseFormat=json (raw GitHub serves JSON as
  spend,impressions,clicks,ctr,      text/plain otherwise). Demo swap point -- rows here
  actions,date_start,date_stop,      are already masked at rest, so this lane can never
  time_range=<override>,             produce a raw id the WRITE WHITELIST GATE would accept.
  Authorization: Bearer
  {{ $env.META_SYSUSER_TOKEN }}
   |                              /
Mask + normalize                        Code (runOnceForAllItems): masks BEFORE anything is
                                         stored -- account_ref "act_••••3502",
                                         adset_ref "••••0014", drops every
                                         name except our own ad set's. leads = MAX over action
                                         types matching /lead/i, NEVER the sum (a lead event can
                                         appear as both 'lead' and
                                         'onsite_conversion.lead_grouped'). cpl = leads>0 ?
                                         spend/leads : null. Throws if it normalizes to ZERO
                                         rows (folds the "Any rows?" gate -- no
                                         alwaysOutputData anywhere in this workflow).
   |
Store snapshot (Postgres)               A data-modifying CTE: INSERT into ep06_insights
                                         (the masked row only), then SELECTs the real
                                         `actions_today` = count(*) FROM ep06_actions WHERE
                                         created_at::date = current_date, carried into
                                         Evaluate breaker as $json.actions_today.
   |
Evaluate breaker                        Code (runOnceForEachItem): THE BRAIN. Reads every
                                         threshold from the Load caps row -- nothing is a
                                         magic number. Order: api-error trip -> min-data
                                         guard -> lag guard -> R3 (CPL) -> R1 (spend cap) ->
                                         R2 (zero-lead) -> daily action cap. A would-be pause
                                         is downgraded to kind:'none', rule:'daily-cap' when
                                         actions_today >= max_actions_per_day (a trip verdict
                                         is never downgraded this way). consecutive_api_errors
                                         >= error_trip_threshold short-circuits to kind:'trip'
                                         before any other rule runs -- same node, same order,
                                         as the live estate's MA-02 "Evaluate Rules". Emits
                                         kind: none | trip | pause, the rule, the reason
                                         string with the arithmetic spelled out, observed vs
                                         threshold, and an idempotency_key
                                         `ep06:<adset_id>:<rule>:<date>`.
   |
Route verdict (Switch on kind)   ---+-- pause --> WRITE WHITELIST GATE --> Dry run? (If)
                                     |                                       |        \
                                     |                              true (dry_run)  false
                                     |                                       |          \
                                     |                                Write receipt   Pause at Meta (POST)
                                     |                                     ^                |
                                     |                                     |         Verify effective status (GET)
                                     |                                     +----------------+
                                     |
                                     +-- trip --> Trip breaker (Data Table update:
                                     |            breaker_tripped=true) --------------+
                                     |                                                 |
                                     +-- none -----------------------------------------+--> Run summary
                                                                                        (also reached via
                                                                                         Write receipt ->
                                                                                         Post receipt to Slack)
   |
Write receipt (Postgres)                A data-modifying CTE: INSERT into ep06_actions
                                         (adset_ref, rule, dry_run -- the real actions_today
                                         source Store snapshot reads) THEN INSERT into
                                         ep06_receipts in the SAME statement. Built with
                                         expressions reading WRITE WHITELIST GATE's item
                                         directly (no separate "Build receipt" Code node --
                                         see GOTCHAS) plus Verify effective status's
                                         configured_status/effective_status (null on the
                                         dry-run branch, which skips the pause+verify pair
                                         entirely). Fires for every pause-lane decision, dry
                                         or real -- a dry run still counts against the daily
                                         action cap, since it is still a breaker decision.
   |
Post receipt to Slack (DISABLED)        Swap point. Cred `LG Slack`, no channel id on screen
                                         (`REPLACE_ME`). Disabled nodes pass data through.
   |
Run summary                             Code (runOnceForAllItems): the number the video quotes.
```

## Credentials -- two required, all shipped as `REPLACE_ME`

| #   | Node(s)                                                         | Credential type    | How to create it                                                                                                                                                                                                                        |
| --- | --------------------------------------------------------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Store snapshot`, `Write receipt`, `Log error` (error workflow) | **Postgres**       | Any Postgres. Run `schema.sql` first.                                                                                                                                                                                                   |
| 2   | `Post receipt to Slack` (disabled)                              | **Slack**          | Optional. Slack app OAuth token, then set a real `channelId` (ships as `REPLACE_ME`).                                                                                                                                                   |
| --  | `Fetch insights`, `Pause at Meta`, `Verify effective status`    | none (uses `$env`) | Set `META_SYSUSER_TOKEN` (a Meta system-user token with `ads_management`) and `META_API_VER` (e.g. `v22.0`) as **environment variables** on the n8n container -- not an n8n credential. Same pattern as this estate's own live breaker. |

The Data Table `ep06_caps` is not a credential -- see `data-table-spec.md`.

## Run it

1. Create the Data Table `ep06_caps` (native n8n Data Table, 2.30+) with the columns
   in `data-table-spec.md` and insert one row for your own ad set. Point
   `Load caps` / `Trip breaker`'s `dataTableId` at it (repo ships `REPLACE_ME`).
2. `schema.sql` against your Postgres (5 tables: `ep06_insights`, `ep06_actions`,
   `ep06_receipts`, `ep06_run_summary`, `ep06_errors`).
3. Import `workflow.json`, set the Postgres credential (and Slack if you want the
   receipt posted), set `META_SYSUSER_TOKEN` + `META_API_VER` on the n8n host.
4. Press **Manual Test**. Read the numbers off `Run summary`, or:
   ```sql
   SELECT * FROM ep06_receipts ORDER BY id DESC LIMIT 1;
   SELECT count(*) FROM ep06_run_summary;
   ```
5. Import `error-workflow.json` and point this workflow's `settings.errorWorkflow`
   at it. It is load-bearing, not optional: it is what actually increments
   `consecutive_api_errors` (see "The error-trip loop" below). Deactivate it after
   import like any other workflow here -- n8n calls a workflow's `errorWorkflow`
   regardless of whether that target workflow is itself active.

## Caps (the Data Table row -- see `data-table-spec.md` for the full column list)

| Cap                        | Value (reference deployment)                     |
| -------------------------- | ------------------------------------------------ |
| `daily_spend_cap_usd`      | 60.00                                            |
| `cpl_cap_usd`              | 25.00                                            |
| `min_spend_before_cpl_usd` | 25.00                                            |
| `zero_lead_spend_usd`      | 60.00                                            |
| `max_actions_per_run`      | 1                                                |
| `max_actions_per_day`      | 2 (enforced -- see "The daily action cap" below) |
| `cooldown_minutes`         | 1440 (documented; see GOTCHAS)                   |
| `error_trip_threshold`     | 3 (enforced -- see "The error-trip loop" below)  |
| Execution timeout          | 300 s (workflow settings)                        |

## The daily action cap (enforced)

`Store snapshot`'s CTE selects `actions_today = count(*) FROM ep06_actions WHERE
created_at::date = current_date` alongside its `ep06_insights` INSERT, in the SAME
round trip (`WITH ins AS (INSERT ... RETURNING id) SELECT ins.id, (SELECT count(*)
...) AS actions_today FROM ins;`). `Evaluate breaker` reads `$json.actions_today`
(its own input, since it sits directly downstream of Store snapshot) and, whenever
a rule would otherwise emit `kind:'pause'`, downgrades it to `kind:'none',
rule:'daily-cap'` if `actions_today >= max_actions_per_day`. A `kind:'trip'`
verdict is never downgraded by this check -- the daily cap limits pauses, not the
breaker escalating on its own repeated failures.
`Write receipt`'s CTE is what makes the counter real: it INSERTs one row into
`ep06_actions` (adset_ref, rule, dry_run) for every pause-lane decision -- including
a dry run, which is still a breaker decision even though nothing reached Meta --
in the SAME statement as the `ep06_receipts` INSERT.

## The error-trip loop (enforced)

`Fetch insights`, `Pause at Meta` and `Verify effective status` all keep n8n's
default `onError` (stop the workflow) -- **never** `continueErrorOutput`, which
would let a failed fetch "verify" itself with the caller's own input and read as a
silent green (the exact class of bug in `feedback-n8n-silent-failure-classes`,
item 3). A stopped execution instead fires this workflow's `settings.errorWorkflow`,
which on the reference deployment points at `error-workflow.json`'s own id (a
deliberate deviation from the original plan's estate-wide LG-00 watchdog pointer --
see GOTCHAS). `error-workflow.json` is 4 nodes: `Error Trigger` -> `Log error`
(unchanged, INSERT into `ep06_errors`) -> `Read caps` (Data Table `get`, the same
`ep06_caps` row) -> `Bump error counter` (Data Table `update`,
`consecutive_api_errors = {{ Number($json.consecutive_api_errors || 0) + 1 }}`,
matched on `adset_id`). `Evaluate breaker` reads the bumped value back through
`Load caps` on the next run and short-circuits to `kind:'trip'` -- checked FIRST,
before any pause rule -- once `consecutive_api_errors >= error_trip_threshold`,
exactly mirroring where the live estate's MA-02 "Evaluate Rules" node does its own
identical check (in the same node that evaluates the pause rules, not in an
upstream fetch-builder). `Trip breaker` then sets `breaker_tripped=true`, which
`Build insights request`'s armed-guard reads on every subsequent run -- a tripped
breaker never un-trips itself; a human resets `consecutive_api_errors` and
`breaker_tripped` in the Data Table by hand.

## Rules (from the `ads-kill-rules` skill's rule engine -- `references/rule-engine.md`)

Adapted from the same core min-data-guard / breach / unknown shape:

- **Min-data guard** (runs first): `spend < min_spend_before_cpl_usd` -> every
  value-dependent rule returns `unknown`, never a breach.
- **Lag guard**: `leads == 0` inside the conversion-lag settle window (some Meta
  action types settle up to ~28h) -> `unknown`, not R2. Must clear before R2 can fire
  (mirrors the rule engine's R3 "outside its attribution/conversion-lag window").
- **R3 -- CPL over cap**: `leads >= 1 AND cpl (spend/leads) > cpl_cap_usd`. Checked
  ahead of R1 so a leads>=1, over-cap-spend row reports the CPL breach it actually is.
- **R1 -- spend cap**: `spend >= daily_spend_cap_usd`.
- **R2 -- zero-lead spend**: `spend >= zero_lead_spend_usd AND leads == 0`, lag
  cleared. This is the rule the real ($70.15 / 0 leads) ad set trips.
- **Daily action cap**: a would-be `pause` is downgraded to `kind:'none',
rule:'daily-cap'` when `actions_today >= max_actions_per_day` -- enforced, see
  "The daily action cap" above.
- **API-error trip**: `consecutive_api_errors >= error_trip_threshold` short-circuits
  to `kind:'trip'` ahead of every other rule -- enforced, see "The error-trip loop"
  above.
- **Cooldown / idempotency**: `Evaluate breaker` computes `idempotency_key =
ep06:<adset_id>:<rule>:<date>` and records it on every receipt. Still
  documented-not-enforced -- see GOTCHAS.

## GOTCHAS

- **A paused campaign returns zero insight rows for `date_preset=today`.** This
  repo's reference run uses an explicit `time_range` (`{"since":"2026-08-30",
"until":"2026-09-22"}`) from the caps row's `time_range_override`. **Production**
  should use `date_preset=today` + `time_increment=1` on an ad set whose campaign is
  actually active -- swap the `Build insights request` Code node's time-range
  construction back to that once the flight is live.
- **MAX-not-SUM on lead-ish action types.** A single lead event can appear as BOTH
  `lead` and `onsite_conversion.lead_grouped` in the same `actions[]` array --
  summing them halves the true CPL. `Mask + normalize`'s `leadsFromActions()` takes
  the MAX across every action type matching `/lead/i`. `samples/insights-sample.json`
  ships a fixture row (`syn-max-not-sum-proof`) with both types at value 3 to prove
  the branch: correct leads = 3, a SUM bug would read 6.
- **Campaign-pause is not ad-set-pause.** A campaign's `status: PAUSED` does not
  touch a child ad set's own `configured_status` -- exactly the leak this episode's
  real ad set sat in (`configured_status: ACTIVE`, `effective_status:
CAMPAIGN_PAUSED`). This workflow's one write closes that gap at the ad-set level.
- **`PUT`/`POST` can activate a workflow that was inactive.** This workflow was
  GET-verified `active: false` immediately after creation via the API and is never
  activated outside a sanctioned manual run.
- **Raw GitHub serves JSON as `text/plain`.** `Load sample insights` sets
  `options.response.response.responseFormat = "json"` or every downstream node sees
  a string, not an object.
- **Node budget forced four small control-flow steps into their neighbors** rather
  than shipping them as standalone nodes (this episode's node cap is 20 including 2
  sticky notes): the armed-guard check lives inside `Build insights request` (an
  unarmed run returns zero items, and zero items downstream is a no-op by
  construction -- same "no IF node needed" pattern EP05 used for its conditional
  insert); the "Any rows?" zero-row throw lives inside `Mask + normalize`; the
  Switch's `none` output goes straight to `Run summary` instead of through a `NoOp`
  placeholder; and `Write receipt`'s INSERT reads `WRITE WHITELIST GATE` and
  `Verify effective status`'s fields directly by expression instead of a separate
  "Build receipt" Code node. Every behavior these would-be nodes describe is still
  present, just inlined.
- **`jsCode` must be pure ASCII.** The bullet character used in every masked id
  (`•`) is written as a 6-character source-level escape in every Code node,
  never a literal byte, so nothing corrupts across a storage round-trip
  (`node --check` was run against every extracted Code node's jsCode before it was
  posted to the VPS).
- **Every Code node declares an explicit `mode`.** `Build insights request`, `Mask +
normalize`, `WRITE WHITELIST GATE` and `Run summary` are `runOnceForAllItems`
  (they aggregate or filter across the whole input); `Evaluate breaker` is
  `runOnceForEachItem` (one verdict per insight row).
- **Disabled nodes pass data through.** That is what makes `Every 15 minutes`,
  `Load sample insights` and `Post receipt to Slack` safe to ship on the canvas as
  swap points -- the chain still runs end to end without them enabled.
- **`settings.errorWorkflow` deviates from the original build note.** The plan this
  episode started from pointed the VPS copy's `errorWorkflow` at the estate-wide
  LG-00 watchdog (a shared workflow this repo does not ship) so a human sees every
  EP06 failure alongside the rest of the estate's alerts. Enforcing the error-trip
  loop for real needs `errorWorkflow` to point at THIS episode's own
  `error-workflow.json` instead (only it knows to bump `consecutive_api_errors` in
  `ep06_caps`) -- n8n allows exactly one `errorWorkflow` per workflow, not both. The
  reference deployment picked correctness of the trip mechanism over estate-wide
  alerting; a production fork can chain the two by adding an `Execute Workflow` node
  at the end of `error-workflow.json` that also calls the estate watchdog.
- **`actions_today` and `consecutive_api_errors` are now enforced**, not just
  documented (see "The daily action cap" and "The error-trip loop" above) --
  `cooldown_minutes` is the one remaining documented-but-unenforced cap: refusing a
  SECOND pause inside the cooldown window needs a lookup against `ep06_receipts`'
  `idempotency_key` before `WRITE WHITELIST GATE` that this build did not add
  (the node budget was frozen before recording the canvas tours). A production fork
  adds that lookup the same way `Store snapshot` added `actions_today`.
- **This is a portfolio/demo repo, not a production pager.** Wiring this at a real
  agency ad account still needs the cooldown lookup above and a second human eyeball
  on the `ep06_caps` row before `dry_run` ever flips to `false`.

## Files

```
workflow.json                    the importable workflow, 20 nodes (18 + 2 sticky),
                                  credentials and Data Table id stripped to REPLACE_ME
error-workflow.json              Error Trigger -> Postgres ep06_errors -> Data Table
                                  get + update (bumps consecutive_api_errors)
README.md                        this file
schema.sql                       5 tables (insights, actions, receipts, run_summary, errors)
data-table-spec.md               ep06_caps Data Table column spec + the reference row
samples/insights-sample.json     the real EP06 row (masked) + 7 synthetic rows covering
                                  every rule branch, incl. the MAX-not-SUM fixture
```

MIT -- see the repository root.
