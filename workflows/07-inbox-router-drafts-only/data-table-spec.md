# `ep07_caps` -- Data Table spec

Created as an n8n **Data Table** (native to n8n 2.30+, not a Postgres table) via the
public REST API: `POST /api/v1/data-tables` with a `columns` array, then
`POST /api/v1/data-tables/{id}/rows` with `{"data":[{...}]}`. One row. Read at
runtime by `Load caps` (`n8n-nodes-base.dataTable`, `resource: row`,
`operation: get`); the error workflow's `Bump error counter` (`operation: update`)
is the only writer.

On the VPS this table's id is `REPLACE_ME` in this repo copy -- swap it for your own
Data Table id (or name, via the resourceLocator's "By Name" mode) after import. It
does **not** exist as a Postgres table; `\dt` on the n8n database will not show it.

## Columns

| Column                 | Type    | Meaning                                                                                                                                                                                                                                                                                                                                          |
| ---------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `max_msgs_per_run`     | number  | Hard slice applied inside `Mask + normalize` before anything else runs.                                                                                                                                                                                                                                                                          |
| `max_msgs_per_day`     | number  | Documented daily ceiling for the mailbox poll cadence (see README GOTCHAS -- not enforced by a lookup in this single-run demo).                                                                                                                                                                                                                  |
| `llm_calls_per_day`    | number  | Enforced. `Guard: cap` reads the real count already spent today from `ep07_inbox` (via `Count LLM calls today`, a Postgres query) and throws before any item reaches the LLM node once this is met.                                                                                                                                              |
| `dry_run`              | boolean | `true` = no mailbox write, run summary just counts what WOULD be labelled.                                                                                                                                                                                                                                                                       |
| `kill_enabled`         | boolean | `false` = human-disarmed; `Mask + normalize` returns zero items.                                                                                                                                                                                                                                                                                 |
| `breaker_tripped`      | boolean | `true` = self-demoted after repeated errors; never un-trips itself. Reset by hand in the Data Table.                                                                                                                                                                                                                                             |
| `consecutive_errors`   | number  | Enforced. Incremented by `error-workflow.json`'s `Bump error counter` node every time this workflow's `settings.errorWorkflow` fires. |
| `error_trip_threshold` | number  | Enforced. `Bump error counter`'s update expression sets `breaker_tripped = true` in the SAME write once `(consecutive_errors + 1) >= error_trip_threshold` -- `Mask + normalize`'s armed-guard reads `breaker_tripped` on the next run and returns zero items. A tripped breaker never un-trips itself; reset both columns by hand in the Data Table. |
| `known_client_domains` | string  | JSON array string, e.g. `["skynetjoe.com","skynetlabsai.com"]`. `Rules router` matches the sender's domain against this list for the `existing_client` classification.                                                                                                                                                                           |

## The one row (VPS copy only)

The VPS copy of this Data Table carries exactly one row: `max_msgs_per_run: 50`,
`max_msgs_per_day: 200`, `llm_calls_per_day: 40`, `dry_run: true`,
`kill_enabled: true`, `breaker_tripped: false`, `consecutive_errors: 0`,
`error_trip_threshold: 3`, `known_client_domains: '["skynetjoe.com","skynetlabsai.com","waseemnasir.com"]'`.
This repo's copy of `workflow.json` references `dataTableId: REPLACE_ME` -- create
your own Data Table with these columns and one row before importing.
