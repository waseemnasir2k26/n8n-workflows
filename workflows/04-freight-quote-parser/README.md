# 04 — Freight quote email parser (Claude → table + draft reply)

`04 Freight Quote Parser (Claude -> table + draft reply)` — 16 nodes (13 working nodes + 3 sticky notes).

A freight forwarder gets quote requests by email and someone retypes each one. This workflow
reads inbound email inquiries, extracts shipment details using the Claude API (ports, weights,
dimensions, cargo type, incoterm, deadline) with a fixed JSON schema, writes one row per email into
a Postgres table keyed on the message id (a re-run updates, never duplicates), and leaves a
**draft** reply that echoes the extracted fields back to the sender for confirmation.
**Nothing sends on its own.** Commercial terms need a human, so the draft is where the workflow stops.

The last node emits one summary item you can read straight off the execution panel:
`emails_seen`, `rows_written`, `fields_filled_avg` (of 8), `seconds_avg` (email in → row written).

Built with 20 synthetic quote emails (`samples/quotes-20.json`): FCL, LCL, air and rail; Karachi →
Jebel Ali, Shanghai → Rotterdam, Mundra → Felixstowe and others; some with missing fields, one with
dimensions in inches, one with a deadline of "before Eid", one messy forwarded thread. Fictional
companies and people, `.example` addresses only. **The demo feeds these samples through a webhook;
it does not read a live mailbox.** The Gmail trigger and Gmail draft nodes are on the canvas,
disabled, as the swap points for a real inbox (see Credentials).

## The 8 fields

| Field              | Rule the model and the validator both enforce                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `origin_port`      | port or airport as `City, Country`; a named shipping city counts; never inferred from a company address             |
| `destination_port` | same                                                                                                                |
| `mode`             | `FCL` `LCL` `AIR` `ROAD` `RAIL`, else null                                                                          |
| `weight_kg`        | total gross weight as a number; lb and tonnes converted; per-container × count multiplied and noted                 |
| `dimensions`       | per-piece `L x W x H cm` + piece count; inches converted                                                            |
| `cargo_type`       | short noun phrase incl. reefer / hazardous / UN number                                                              |
| `incoterm`         | one of EXW FCA FAS FOB CFR CIF CPT CIP DAP DPU DDP ("ex works" → EXW), else null                                    |
| `deadline`         | `YYYY-MM-DD` when resolvable, otherwise the sender's own phrase ("before Eid", "ASAP") and `deadline_is_date=false` |

Unknown → `null`, never invented. `fields_filled` counts the non-null ones (0–8). `confidence` (0–1)
is the model's own estimate, clamped in code and forced to 0 when the response could not be parsed.
`pieces` and `notes` are stored as extras and not counted.

## Flow, node by node

```
Click to run (20 samples)     Manual trigger --> Fetch sample emails (HTTP GET of samples/quotes-20.json
                               from this repo). The demo path.
Email in (webhook)            POST /webhook/ep04-email-in with one email {from, subject, body,
                               message_id} or {emails:[...]}. Point an IMAP poller, a mail-provider
                               inbound webhook, or the feeder script at it. Responds with the Run summary.
Gmail trigger (DISABLED)      Swap point: enable + Gmail credential, polls label:quotes, unread.
   |
Normalize email               Code: one item per email from any of the three doors. Parses
                               "Name <addr>", falls back to a djb2 hash when there is no message id,
                               drops duplicates inside one feed, stamps arrived_ms, caps at 25 per run.
   |
Config                        Set: run_id (yyyyLLdd-HHmm), model, max_tokens 600, today. Keeps the
                               email fields (includeOtherFields). No $env: n8n 2.x Code nodes cannot
                               read environment variables, so config travels as data.
   |
Claude extract                HTTP POST api.anthropic.com/v1/messages, one call per email, batching
                               1 item / 400 ms, retry 3x. tools=[extract_quote] + tool_choice forced,
                               so the reply is ALWAYS the schema, never prose. temperature 0.
   |
Validate + score              Code (per item): reads the tool_use block (text-JSON fallback), re-checks
                               every field (enum lists, numbers, ISO dates), counts fields_filled,
                               clamps confidence, keeps raw_extraction for audit.
   |
UPSERT ep04_quotes            Postgres executeQuery: INSERT ... ON CONFLICT (message_id) DO UPDATE,
                               seconds_to_row computed in SQL from arrived_ms, RETURNING fields_filled,
                               confidence, seconds_to_row, (xmax = 0) AS inserted.
   |
Build draft reply             Code (per item): "Re: <subject>", every field echoed, NOT FOUND for nulls,
                               a request for a date when the deadline was a phrase, a [DRAFT] footer.
   |
Gmail create draft (DISABLED) Swap point: enable + Gmail credential and the draft lands in Drafts.
                               Disabled nodes pass items through, so the table below still fills.
   |
Store draft (ep04_drafts)     Postgres: full reply text, status 'draft', ON CONFLICT (message_id).
   |
Run summary                   Code: {run_id, emails_seen, rows_written, rows_inserted, rows_updated,
                               drafts_written, fields_filled_avg, confidence_avg, seconds_avg,
                               seconds_total, tokens_in, tokens_out}.
```

## Credentials — two required, one optional, all shipped as `REPLACE_ME`

| #   | Node(s)                                               | Credential type  | How to create it                                                                                                                                                 |
| --- | ----------------------------------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Claude extract`                                      | **Header Auth**  | Name `x-api-key`, value your Anthropic API key (console.anthropic.com). The node adds `anthropic-version` itself.                                                |
| 2   | `UPSERT ep04_quotes`, `Store draft (ep04_drafts)`     | **Postgres**     | Any Postgres. Run `schema.sql` first.                                                                                                                            |
| 3   | `Gmail trigger`, `Gmail create draft` (both disabled) | **Gmail OAuth2** | Optional. Google Cloud OAuth client with the Gmail scope, then enable the two nodes. Without it the webhook is the inbox and `ep04_drafts` is the Drafts folder. |

Create them in **n8n → Credentials → New**, then re-select on the matching nodes after import.
Shipped names: `Anthropic x-api-key (REPLACE_ME)`, `Postgres (REPLACE_ME)`, `Gmail (REPLACE_ME)`.

### Connecting a real inbox without Gmail

- **IMAP:** add an `Email Trigger (IMAP)` node (mailbox `quotes` or `INBOX`, format simple) wired into
  `Normalize email`; it already understands `from` / `subject` / `text` / `messageId`. Drafts stay
  in `ep04_drafts` (IMAP has no draft-create in n8n).
- **Mail-provider inbound webhook** (Hostinger, Postmark, SendGrid, Mailgun …): point it at
  `/webhook/ep04-email-in`; map the provider's fields to `{from, subject, body, message_id}` in
  `Normalize email` if the names differ.

## Run it

1. `schema.sql` against your Postgres.
2. Import `workflow.json`, set the three credentials.
3. Either press **Execute workflow** (fetches the 20 samples from GitHub) or activate and
   `python samples/feed.py https://YOUR-N8N/webhook/ep04-email-in` (add `--one-by-one` for 20
   separate executions). The response body is the Run summary.
4. `SELECT run_id, count(*), round(avg(fields_filled),2), round(avg(seconds_to_row),1) FROM ep04_quotes GROUP BY 1;`
   is the number to quote. Run it twice: the count does not change, `rows_updated` does.

## Caps

| Cap               | Where                            | Value                                        |
| ----------------- | -------------------------------- | -------------------------------------------- |
| Emails per run    | `Normalize email` (`MAX_EMAILS`) | 25, the rest are dropped and counted         |
| Tokens per email  | `Config.max_tokens`              | 600 output; ~1.8k input for a normal email   |
| Model             | `Config.model`                   | `claude-haiku-4-5-20251001` (swap here only) |
| Claude call       | `Claude extract`                 | 60 s timeout, 3 tries, 1 item / 400 ms       |
| Execution timeout | workflow settings                | 900 s                                        |

Twenty emails is roughly 40k input + 6k output tokens on Haiku. Check your own usage page before
raising `MAX_EMAILS`; the webhook has no auth in the shipped JSON, so add Header Auth on
`Email in (webhook)` before you leave it active on a public host.

## schema.sql

`ep04_quotes` (one row per email, the 8 fields + extras + `raw_extraction` jsonb + timing) and
`ep04_drafts` (the reply text, `status` never leaves `draft`). Both keyed on `message_id`.

## GOTCHAS

Each of these cost a failed run or a wrong number during the build.

- **Force the tool, do not ask for JSON.** `tool_choice: {type: "tool", name: "extract_quote"}`
  makes the API return the schema every time; a "reply only with JSON" prompt still produces fences
  and prose on messy forwarded threads. The validator keeps a text-JSON fallback for other models.
- **Nullable fields need `["string", "null"]`, and the enum needs `null` too.** Without it the
  model fills a guess to satisfy the schema, which is exactly the hallucinated-port risk.
- **Deadlines are text on purpose.** "Before Eid", "ASAP", "3rd week of November" carry
  information a `date` column would throw away; `deadline_is_date` tells you which rows are
  sortable and the draft asks the sender for a date when it is not.
- **`seconds_to_row` is stamped in SQL, not in the Code node**, so it includes the Claude call and
  the insert itself. It measures from the moment the email entered the workflow (`arrived_ms`),
  not from the sample's `received_at`, which is synthetic.
- **Per-item Code nodes (`runOnceForEachItem`) keep pairing honest.** `Validate + score` and
  `Build draft reply` read the matching email with `$('Config').item`; a run-once-for-all node
  returning a re-ordered array would silently pair the wrong email with the wrong extraction.
- **Disabled nodes pass data through.** That is what makes the two Gmail swap points safe to
  ship: the chain still runs end to end without them.
- **No `URL()` and no `$env` in the Code sandbox.** Hosts, addresses and config are string
  operations and Set-node data.
- **The webhook wraps the payload** (`body`, `headers`, `query`); `Normalize email` unwraps it
  and also accepts a bare array so the same node serves the sample fetch and a Gmail item.
- **Data Tables** are an optional swap for Postgres: replace the two Postgres nodes with Data
  Table upserts on `message_id` and drop `schema.sql`. Not built here.

## Files

```
workflow.json          the importable workflow, 16 nodes, credentials stripped to REPLACE_ME
README.md              this file
schema.sql             ep04_quotes + ep04_drafts
samples/quotes-20.json 20 synthetic quote request emails (fictional senders, .example addresses)
samples/feed.py        POSTs the samples to the webhook, prints the Run summary
```

MIT — see the repository root.
