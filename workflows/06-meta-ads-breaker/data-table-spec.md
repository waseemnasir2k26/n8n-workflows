# `ep06_caps` -- Data Table spec

Created as an n8n **Data Table** (native to n8n 2.30+, not a Postgres table) via the
public REST API: `POST /api/v1/data-tables` with a `columns` array, then
`POST /api/v1/data-tables/{id}/rows` with `{"data":[{...}]}`. One row, one ad set.
Read at runtime by the `Load caps` node (`n8n-nodes-base.dataTable`, `resource: row`,
`operation: get`); written by `Trip breaker` (`operation: update`) when the breaker
self-demotes.

On the VPS this table's id is `REPLACE_ME` in this repo copy -- swap it for your own
Data Table id (or name, via the resourceLocator's "By Name" mode) after import. It
does **not** exist as a Postgres table; `\dt` on the n8n database will not show it.

## Columns

| Column                     | Type    | Meaning                                                                                                                                                                                                                                                                                                             |
| -------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `adset_id`                 | string  | The one ad set this breaker is allowed to touch. Also the write allowlist.                                                                                                                                                                                                                                          |
| `daily_spend_cap_usd`      | number  | R1 -- flat spend ceiling.                                                                                                                                                                                                                                                                                           |
| `cpl_cap_usd`              | number  | R3 -- cost-per-lead ceiling (only checked when leads >= 1).                                                                                                                                                                                                                                                         |
| `min_spend_before_cpl_usd` | number  | Min-data guard -- below this, every rule returns unknown.                                                                                                                                                                                                                                                           |
| `zero_lead_spend_usd`      | number  | R2 -- spend past this with 0 leads is a breach (after the lag guard).                                                                                                                                                                                                                                               |
| `cooldown_minutes`         | number  | Documented cooldown window for the idempotency key (see GOTCHAS -- not enforced by a lookup in this single-run demo).                                                                                                                                                                                               |
| `max_actions_per_run`      | number  | Step cap -- documented; this demo evaluates one ad set per run.                                                                                                                                                                                                                                                     |
| `max_actions_per_day`      | number  | Daily step cap -- enforced. `Store snapshot`'s CTE reads the real count from `ep06_actions` (one row per pause-lane decision, written by `Write receipt`) and `Evaluate breaker` downgrades a would-be pause to `kind:'none', rule:'daily-cap'` once the count meets this value.                                    |
| `dry_run`                  | boolean | `true` = no Meta write, receipt says "WOULD PAUSE -- DRY RUN".                                                                                                                                                                                                                                                      |
| `kill_enabled`             | boolean | `false` = human-disarmed; `Build insights request` returns zero items.                                                                                                                                                                                                                                              |
| `breaker_tripped`          | boolean | `true` = self-demoted after repeated API errors; never un-trips itself.                                                                                                                                                                                                                                             |
| `consecutive_api_errors`   | number  | Counter toward `error_trip_threshold` -- enforced. Incremented by `error-workflow.json`'s `Bump error counter` node (Data Table `update`) every time this workflow's `settings.errorWorkflow` fires; read back by `Evaluate breaker`, which short-circuits to `kind:'trip'` once this meets `error_trip_threshold`. |
| `error_trip_threshold`     | number  | Trip threshold for `consecutive_api_errors`.                                                                                                                                                                                                                                                                        |
| `time_range_override`      | string  | JSON `{"since":"...","until":"..."}`. Production swaps this for `date_preset=today` + `time_increment=1` (see README GOTCHAS -- a paused campaign returns zero rows for `today`).                                                                                                                                   |

## The one row (VPS copy only)

The VPS copy of this Data Table carries exactly one row: `adset_id`
`••••0014` (masked; our own HVAC AU ad set), `dry_run: true`,
`time_range_override: {"since":"2026-08-30","until":"2026-09-22"}`, and the caps
listed in the README's "Caps" table. This repo's copy of `workflow.json` references
`dataTableId: REPLACE_ME` -- create your own Data Table with these columns and one
row for your own ad set before importing.
