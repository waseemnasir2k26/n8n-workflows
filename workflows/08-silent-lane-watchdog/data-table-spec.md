# `ep08_lanes` + `ep08_caps` -- Data Table specs

Created as native n8n **Data Tables** (2.30+, not Postgres tables) via the public
REST API: `POST /api/v1/data-tables` with a `columns` array, then
`POST /api/v1/data-tables/{id}/rows` with `{"data":[{...}]}`. `\dt` on the n8n
Postgres database will not show either of them.

On the VPS both ids are `REPLACE_ME` in this repo copy -- swap for your own Data
Table ids (or names, via the resourceLocator's "By Name" mode) after import.

## `ep08_lanes` -- one row per monitored lane (the expectation table)

Read by `Load expectations` (`resource: row`, `operation: get`, `returnAll: true`).
`lane_ref` **must** match the pseudonymous ref `Mask lane names` computes from the
real workflow name (FNV-1a hash, `lane_` + first 8 hex chars) -- work this out once
per lane you want monitored and enter the row by hand; the real workflow name is
never written into this table.

| Column                  | Type   | Meaning                                                                                                                   |
| ----------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------- |
| `lane_ref`              | string | Pseudonymous lane id, must match the hash `Mask lane names` computes.                                                     |
| `kind`                  | string | `scheduled` \| `event-driven` \| `upstream-count` \| `manual-run`.                                                        |
| `expected_interval_min` | number | scheduled/manual-run: max minutes between saved successes before it's overdue.                                            |
| `upstream_count_window` | number | event-driven/upstream-count: expected arrivals in the measurement window (7 days, matches the query).                     |
| `cooldown_min`          | number | Documented per-lane cooldown (the daily idempotency key already caps real re-opens to 1/day; this column is descriptive). |

## `ep08_caps` -- one row, the run-wide cap sheet

Read by `Load caps` / `Read caps` (error workflow). One row only.

| Column                       | Type    | Meaning                                                                                                                        |
| ---------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `max_incidents_per_run`      | number  | 3 -- Evaluate obligation stops opening new incidents past this count.                                                          |
| `reminders_per_lane_per_day` | number  | 1 -- documented; enforced structurally by the daily idempotency key.                                                           |
| `cooldown_min`               | number  | 1440 -- documented; matches the daily idempotency-key grain.                                                                   |
| `dry_run`                    | boolean | `true` = incident rows carry `dry_run:true`; no external side effect regardless (Slack ships disabled).                        |
| `kill_enabled`               | boolean | `false` = human-disarmed; Evaluate obligation refuses every 'open'.                                                            |
| `breaker_tripped`            | boolean | `true` = self-demoted after repeated errors; Evaluate obligation refuses every 'open'. Never un-trips itself -- reset by hand. |
| `consecutive_errors`         | number  | Counter toward `error_trip_threshold`, bumped by error-workflow.json's `Bump error counter`.                                   |
| `error_trip_threshold`       | number  | 3 -- trip threshold for `consecutive_errors`.                                                                                  |

## The one row (VPS copy only)

`max_incidents_per_run 3 · reminders_per_lane_per_day 1 · cooldown_min 1440 ·
dry_run true · kill_enabled true · breaker_tripped false · consecutive_errors 0 ·
error_trip_threshold 3`.
