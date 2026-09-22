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
Store snapshot (Postgres)               INSERT into ep06_insights, the masked row only.
   |
Evaluate breaker                        Code (runOnceForEachItem): THE BRAIN. Reads every
                                         threshold from the Load caps row -- nothing is a
                                         magic number. Order: min-data guard -> lag guard ->
                                         R3 (CPL) -> R1 (spend cap) -> R2 (zero-lead). Emits
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
Write receipt (Postgres)                INSERT into ep06_receipts. Built with expressions
                                         reading WRITE WHITELIST GATE's item directly (no
                                         separate "Build receipt" Code node -- see GOTCHAS) plus
                                         Verify effective status's configured_status/
                                         effective_status (null on the dry-run branch, which
                                         skips the pause+verify pair entirely).
   |
Post receipt to Slack (DISABLED)        Swap point. Cred `LG Slack`, no channel id on screen
                                         (`REPLACE_ME`). Disabled nodes pass data through.
   |
Run summary                             Code (runOnceForAllItems): the number the video quotes.
```

## Credentials -- two required, all shipped as `REPLACE_ME`

| #   | Node(s)                                                      | Credential type    | How to create it                                                                                                                                                                                                                        |
| --- | ------------------------------------------------------------ | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Store snapshot`, `Write receipt`                            | **Postgres**       | Any Postgres. Run `schema.sql` first.                                                                                                                                                                                                   |
| 2   | `Post receipt to Slack` (disabled)                           | **Slack**          | Optional. Slack app OAuth token, then set a real `channelId` (ships as `REPLACE_ME`).                                                                                                                                                   |
| --  | `Fetch insights`, `Pause at Meta`, `Verify effective status` | none (uses `$env`) | Set `META_SYSUSER_TOKEN` (a Meta system-user token with `ads_management`) and `META_API_VER` (e.g. `v22.0`) as **environment variables** on the n8n container -- not an n8n credential. Same pattern as this estate's own live breaker. |

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
5. Optionally import `error-workflow.json` and point this workflow's
   `settings.errorWorkflow` at it (or at your own estate's watchdog workflow) --
   it logs every failure to `ep06_errors`.

## Caps (the Data Table row -- see `data-table-spec.md` for the full column list)

| Cap                        | Value (reference deployment)   |
| -------------------------- | ------------------------------ |
| `daily_spend_cap_usd`      | 60.00                          |
| `cpl_cap_usd`              | 25.00                          |
| `min_spend_before_cpl_usd` | 25.00                          |
| `zero_lead_spend_usd`      | 60.00                          |
| `max_actions_per_run`      | 1                              |
| `max_actions_per_day`      | 2 (documented; see GOTCHAS)    |
| `cooldown_minutes`         | 1440 (documented; see GOTCHAS) |
| `error_trip_threshold`     | 3                              |
| Execution timeout          | 300 s (workflow settings)      |

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
- **Cooldown / idempotency**: `Evaluate breaker` computes `idempotency_key =
ep06:<adset_id>:<rule>:<date>` and records it on every receipt. See GOTCHAS --
  actually _enforcing_ the cooldown (refusing a second pause inside
  `cooldown_minutes`) needs a lookup against `ep06_receipts` that this single
  manual-run demo does not perform; a real deployment adds that read before
  `WRITE WHITELIST GATE`.

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
- **`actions_today` / `consecutive_api_errors` are documented, not enforced, in this
  single manual-run demo.** A real always-on deployment needs a persisted per-day
  action counter (query `ep06_receipts` for today's count) before `Build insights
request`'s armed-guard, and must increment `consecutive_api_errors` in `Fetch
insights`'/`Pause at Meta`'s error branch feeding back into the Data Table --
  neither is wired here because a single sanctioned run cannot self-collide with
  its own history. Disclosed limitation, not a bug.
- **This is a portfolio/demo repo, not a production pager.** Wiring this at a real
  agency ad account needs the cooldown lookup above, a real `actions_today` counter,
  and a second human eyeball on the `ep06_caps` row before `dry_run` ever flips to
  `false`.

## Files

```
workflow.json                    the importable workflow, 20 nodes (18 + 2 sticky),
                                  credentials and Data Table id stripped to REPLACE_ME
error-workflow.json              Error Trigger -> Postgres ep06_errors
README.md                        this file
schema.sql                       5 tables (insights, actions, receipts, run_summary, errors)
data-table-spec.md               ep06_caps Data Table column spec + the reference row
samples/insights-sample.json     the real EP06 row (masked) + 7 synthetic rows covering
                                  every rule branch, incl. the MAX-not-SUM fixture
```

MIT -- see the repository root.
