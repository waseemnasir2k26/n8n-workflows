# `ep09_caps` -- Data Table spec

Created as an n8n **Data Table** (native to n8n 2.30+, not a Postgres table) via the
public REST API: `POST /api/v1/data-tables` with a `columns` array, then
`POST /api/v1/data-tables/{id}/rows` with `{"data":[{...}]}`. One row (`cap_id`
`ep09`). Read at runtime by `Load caps` (`n8n-nodes-base.dataTable`, `resource:
row`, `operation: get`); written by `Bump caps` (increments `llm_calls_today`)
and by `error-workflow.json`'s `Bump error counter` / `Trip breaker`.

On the VPS this table's id is recorded in `ids.txt` in this folder -- swap it
for your own Data Table id after import. It does **not** exist as a Postgres
table; `\dt` on the n8n database will not show it.

## Columns

| Column                 | Type    | Meaning                                                                                                                                                                                   |
| ---------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cap_id`               | string  | Always `ep09` -- the row key every node filters on.                                                                                                                                       |
| `max_drafts_per_run`   | number  | Step cap. `Guard: cap` slices the item list to this length.                                                                                                                               |
| `max_drafts_per_day`   | number  | Documented daily draft ceiling (this single-manual-run demo does not query a day-total lookup; see README GOTCHAS).                                                                       |
| `llm_calls_per_day`    | number  | Model-call budget for the day.                                                                                                                                                            |
| `llm_calls_today`      | number  | Counter toward `llm_calls_per_day`. `Guard: cap` reads it BEFORE the model runs and refuses to call the model once the budget is spent; `Bump caps` increments it by 1 per draft written. |
| `dry_run`              | boolean | Documented -- this workflow has no external write to gate (Postgres write only); kept for parity with the other EP0N cap sheets.                                                          |
| `kill_enabled`         | boolean | `false` = human-disarmed; `Guard: cap` throws immediately.                                                                                                                                |
| `breaker_tripped`      | boolean | `true` = self-demoted after repeated errors; never un-trips itself.                                                                                                                       |
| `consecutive_errors`   | number  | Counter toward `error_trip_threshold`, maintained by `error-workflow.json`.                                                                                                               |
| `error_trip_threshold` | number  | Trip threshold for `consecutive_errors`. Default 3.                                                                                                                                       |

## The one row (VPS copy)

`cap_id=ep09, max_drafts_per_run=5, max_drafts_per_day=50, llm_calls_per_day=50,
llm_calls_today=0, dry_run=false, kill_enabled=true, breaker_tripped=false,
consecutive_errors=0, error_trip_threshold=3`.
