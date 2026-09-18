# 03 — Maps lead harvest (Apify → Postgres)

`03 Maps Lead Harvest (Apify -> Postgres)` — 18 nodes (15 working nodes + 3 sticky notes).

Type a trade and a city, click Execute, and get a lead table. The workflow starts the Apify actor
`compass/crawler-google-places` for one search string ("roofing contractors Denver"), waits for the
run to finish with a bounded poll loop, pulls the dataset, cleans each business (phone digits-only,
website host-only), dedupes on the Google `place_id`, and upserts every row into Postgres with a
`run_id` so this run is separate from last week's. The last node emits one summary item —
`rows_seen`, `rows_written`, `seconds` — so the number you quote is the number the table holds.

Google Maps data via the Apify actor `compass/crawler-google-places`. This workflow does not scrape
Google itself; every Maps call goes through the actor. Business listings only, no person data.

Framed for home-services buyers (roofing, HVAC, plumbing, electrical) — a raw list of local
operators with a phone, a website (or not: `has_website=false` is the interesting column), a rating
and a review count. It writes to its **own table** (`ep03_leads`) and nothing else.

## Inputs

There is no form. Open the `Inputs` Set node and edit three strings:

| Field   | Example               | Used for                                                              |
| ------- | --------------------- | --------------------------------------------------------------------- |
| `trade` | `roofing contractors` | first half of the search string                                       |
| `city`  | `Denver`              | second half of the search string + Apify `locationQuery`              |
| `state` | `CO`                  | Apify `locationQuery` (`city, state`) and the `state` column fallback |

`Config` derives everything else: `query = trade + ' ' + city`, `run_id = yyyyLLdd-HHmm`,
`started_at = now`, `maxResults = 100`. Nothing reads environment variables — n8n 2.x Code nodes
run in task runners with no `$env`, so config travels as data through the Set node.

## Flow, node by node

```
Click to run             Manual trigger.
   |
Inputs                   Set: trade / city / state. The only node you edit.
   |
Config                   Set: query, run_id, started_at, maxResults (100). Keeps the input
                          fields (includeOtherFields) so every later node can read them.
   |
Start Apify Actor        HTTP POST api.apify.com/v2/acts/compass~crawler-google-places/runs
(async)                   Body: {searchStringsArray: [query], locationQuery: "city, state",
                          maxCrawledPlacesPerSearch: 100, language: en, countryCode: us}.
                          ASYNC on purpose — run-sync times out past 300 s on a real query.
   |
Prep Poll                Set: runId = data.id, datasetId = data.defaultDatasetId.
   |
Wait 30s  <----------------------------------------------------+
   |                                                           |
Poll Run Status          HTTP GET api.apify.com/v2/actor-runs/{runId}                |
   |                                                           |
Check Finished           Code: status, attempt ($runIndex + 1), succeeded,       |
                          proceed = terminal status OR attempt >= 20.            |
   |                                                           |
Run Finished?            IF proceed.  false ---------------------------------------+
   | true
Run Succeeded?           IF succeeded.  false --> Run failed (NoOp, end of run)
   | true
Fetch Dataset Items      HTTP GET api.apify.com/v2/datasets/{datasetId}/items?clean=true&format=json
   |
Normalize + Dedupe       Code: flattens whatever shape the dataset endpoint returns, drops
                          rows with no placeId, drops obvious non-operators by category
                          (supplier / wholesale / distributor / store / charity / non-profit),
                          cleans phone + website, dedupes on place_id with a Set, and puts
                          rows_seen / rows_written on every emitted item. Throws on 0 rows.
   |
UPSERT ep03_leads        Postgres executeQuery, one statement per row:
                          INSERT ... ON CONFLICT (place_id) DO UPDATE ... RETURNING place_id.
   |
Run Summary              Code: {run_id, query, rows_seen, rows_written, rows_deduped, seconds}.
                          rows_written = number of RETURNING rows, seconds = now - started_at.
```

## Credentials — two, both shipped as `REPLACE_ME`

| #   | Node(s)                                                               | Credential type | How to create it                                                                                                                                                 |
| --- | --------------------------------------------------------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Start Apify Actor (async)`, `Poll Run Status`, `Fetch Dataset Items` | **Query Auth**  | Get a token at console.apify.com → Settings → Integrations. Name `token`, value your Apify API token. The three HTTP nodes append it as `?token=` on every call. |
| 2   | `UPSERT ep03_leads`                                                   | **Postgres**    | Any Postgres database. Run `schema.sql` against it first.                                                                                                        |

Create both in **n8n -> Credentials -> New**, then re-select them on the matching nodes after import.
The shipped credential names are `Apify Token (REPLACE_ME)` and `Postgres (REPLACE_ME)`.

## Caps

| Cap               | Where                               | Value                                   |
| ----------------- | ----------------------------------- | --------------------------------------- |
| Places per run    | `Config.maxResults`                 | 100 (`maxCrawledPlacesPerSearch`)       |
| Poll ceiling      | `Check Finished` (`attempt >= 20`)  | 20 polls × 30 s ≈ 10 min, then gives up |
| Execution timeout | workflow settings                   | 900 s                                   |
| HTTP timeouts     | start 60 s · poll 30 s · fetch 60 s |                                         |

One search string at 100 places is a small Apify run. Check the actual cost on the actor run page
before you raise `maxResults` or add more search strings.

## schema.sql

One table, `ep03_leads`, keyed on `place_id`, plus an index on `run_id`. `seen_at` is stamped on
every upsert, so `SELECT run_id, count(*) FROM ep03_leads GROUP BY 1` tells you what each run
wrote and `WHERE has_website = false` gives you the operators with no site.

## GOTCHAS

Each of these cost a failed run during the build.

- **The Apify run is asynchronous and the poll is bounded.** `run-sync` endpoints time out past
  300 s and a real Maps query for 100 places can take longer than that. The workflow starts the
  run, stores `runId` + `datasetId`, then loops Wait → Poll → Check. `$runIndex` counts the loop
  passes; at 20 the loop stops regardless of status so a stuck actor can never spin the workflow
  forever. A status other than `SUCCEEDED` ends at `Run failed` and writes nothing.
- **Dedupe across pages happens in code, not in SQL.** The actor walks the Maps results page by
  page and the same business can appear on two pages. `Normalize + Dedupe` keeps a `Set` of
  `place_id` and emits each one once; the UPSERT's `ON CONFLICT (place_id)` is the second line of
  defence for re-runs. `rows_seen − rows_written` in the summary is the number of duplicates the
  page walk produced.
- **Phone is stored as digits only, and short numbers become NULL.** `String(phone).replace(/[^0-9]/g, '')`
  and anything under 10 digits is not a dialable number. Format it on the way out, not on the way
  in; the column is `text`, not a number.
- **Website is stored as the host only, and there is no `URL()` in a Code node.** The Code sandbox
  has no browser globals, so the host is extracted with string operations (strip scheme → split on
  `/`, `?`, `#` → drop `user@` → drop `:port` → drop `www.`). `has_website` is set from the raw
  field before cleaning, so a junk website string still counts as "has one".
- **Data Tables are an optional swap for Postgres.** n8n's built-in Data Tables can hold this table
  if you do not want an external database; replace the `UPSERT ep03_leads` node with a Data Table
  upsert on `place_id` and drop `schema.sql`. Not built here.
- **Zero rows throws on purpose.** If Apify returns no usable places, `Normalize + Dedupe` throws
  instead of writing an empty run, so the execution is red and the summary never claims 0 written
  as a success.

## Files

```
workflow.json   the importable workflow, 18 nodes, credentials stripped to REPLACE_ME
README.md       this file
schema.sql      ep03_leads + run_id index
```

MIT — see the repository root.
