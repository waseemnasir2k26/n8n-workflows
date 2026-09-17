# 02 — Speed-to-lead (simulated demo)

`Speed-to-Lead (simulated demo)` — 17 nodes.

Three public webhook lanes that simulate a home-services "speed to lead" flow: a web lead comes in,
an AI dispatcher texts back inside seconds, the homeowner replies, the AI qualifies the job and books
a visit window, and a page can poll the running conversation. No SMS provider is wired — the "text
message" is a JSON string returned to the caller, meant to be rendered as a chat bubble on a demo
page. The company in the demo, Lone Star Air, is fictional; the model is told this explicitly and is
instructed never to invent prices, warranties or technician names.

This is a **simulation for a demo page**, not a production lead-routing workflow. It does not touch
any outbound-messaging estate — no SMS send, no CRM contact, no send queue. It only writes to its own
three tables (`demo_sessions`, `demo_messages`, `demo_bookings`).

## Three entry points

| Trigger                          | How                                                                                                                                                                                                        |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /webhook/demo/lead`        | A lead form posts `{name, phone, city, issue}`. Creates a session, gets the AI's first text back, returns `{ok, token, message}`. The `token` is how the other two endpoints find this conversation again. |
| `POST /webhook/demo/reply`       | The homeowner's reply posts `{token, text}`. Logs it, asks the AI to qualify + decide whether to book, returns `{ok, message, booked, job_type, slot_label, slot_at}`.                                     |
| `GET /webhook/demo/state?token=` | A demo page polls this to redraw the whole conversation + any booking as JSON.                                                                                                                             |

```bash
curl -X POST https://YOUR-N8N/webhook/demo/lead \
  -H 'Content-Type: application/json' \
  -d '{"name":"Maria","phone":"555-0100","city":"Austin","issue":"AC blowing warm air"}'

curl -X POST https://YOUR-N8N/webhook/demo/reply \
  -H 'Content-Type: application/json' \
  -d '{"token":"<token from the lead response>","text":"It is not an emergency, tomorrow works"}'

curl "https://YOUR-N8N/webhook/demo/state?token=<token>"
```

The demo HTML page itself is not included in this repo — it is a static page that makes exactly
those three `fetch()` calls (POST on load with the lead form, POST on each reply the visitor types,
GET on an interval or after each POST to redraw the transcript + booking card). Build your own against
this contract.

## Flow, node by node

```
Lane 1 — new lead
Web Lead In (webhook POST /demo/lead)
   |
Clean Lead              Code: public endpoint, never trust the body. Strips control
                         chars, clamps name/phone/city/issue to fixed lengths, falls
                         back to placeholders ("there", "your area"), 400s if issue
                         is empty after cleaning.
   |
Create Session          Postgres: INSERT INTO demo_sessions ... RETURNING id, token,
                         name, city, issue. Token is md5(random || clock_timestamp()),
                         generated in SQL, not in the app.
   |
AI First Text           HTTP POST api.anthropic.com/v1/messages. System prompt casts
                         the model as the dispatcher for a DEMO HVAC company, tells it
                         to text back in under 320 chars, use the first name, reference
                         the stated problem, ask exactly one qualifying question, never
                         invent prices/warranties/technician names/arrival times.
   |
Save AI Text             Postgres: INSERT INTO demo_messages (sender='ai', ...).
   |
Respond Lead              respondToWebhook: {ok, token, message}.

Lane 2 — homeowner reply
Homeowner Reply In (webhook POST /demo/reply)
   |
Clean Reply              Code: token whitelisted to hex chars, text clamped to 400
                          chars. 400s if either is missing.
   |
Log Lead Text            Postgres: one statement that (a) inserts the new lead message,
                          then (b) builds the transcript by string-aggregating existing
                          messages AND explicitly appending the just-inserted line
                          (`|| E'\nCustomer: ' || $2`). See GOTCHAS — this append is not
                          optional.
   |
AI Qualify + Book        HTTP POST api.anthropic.com/v1/messages. System prompt asks
                          the model to decide if it knows enough to book (a stated
                          problem + urgency or a preferred time), and to reply with
                          bare JSON: {message, book, job_type, slot_hint}. slot_hint is
                          one of today_pm / tomorrow_am / tomorrow_pm / this_week —
                          never a raw date or time.
   |
Parse Decision            Code: parses the model's JSON (salvages a bare object out of
                          prose/markdown fences if the model doesn't follow instructions
                          exactly). Maps slot_hint -> a concrete day + a fixed 4-hour
                          window, and renders the finished slot_label string server-side
                          (e.g. "Tomorrow, Sep 18 - 8:00am - 12:00pm"). See GOTCHAS.
   |
Save AI Reply             Postgres: one statement that inserts the AI's reply message,
                          conditionally inserts a booking row (ON CONFLICT (session_id)
                          DO NOTHING — at most one booking per session), and stamps
                          demo_sessions.booked_at the first time book=true.
   |
Respond Reply              respondToWebhook: {ok, message, booked, job_type,
                          slot_label, slot_at}.

Lane 3 — page polling
State In (webhook GET /demo/state?token=)
   |
Read State                Postgres: one query, json_build_object of the message list
                          (sender, body, time) and the booking (job, tech, slot),
                          looked up by token.
   |
Respond State               respondToWebhook: the JSON state object, or
                          {messages: [], booking: null} if the token matches nothing.
```

## Credentials — two, both shipped as `REPLACE_ME`

| #   | Node(s)                                                                                                             | Credential type | How to create it                                                                                                                                                                                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Create Session`, `Log Lead Text` / `AI Qualify + Book`'s neighbours, `Save AI Text`, `Save AI Reply`, `Read State` | **Postgres**    | Any Postgres database. Run `schema.sql` against it first.                                                                                                                                                                              |
| 2   | `AI First Text`, `AI Qualify + Book`                                                                                | **Header Auth** | Get a key at console.anthropic.com. Name `x-api-key`, value your raw Anthropic API key. Both nodes also send a hardcoded `anthropic-version: 2023-06-01` header — no credential needed for that one, it is a literal header parameter. |

Create both in **n8n -> Credentials -> New**, then re-select them on the matching nodes after import.

## Env vars

| Var                   | Used by             | Default if unset   |
| --------------------- | ------------------- | ------------------ |
| `CLASSIFIER_MODEL`    | `AI First Text`     | `claude-haiku-4-5` |
| `CLAUDE_MODEL_SONNET` | `AI Qualify + Book` | `claude-opus-5`    |

Set these in n8n's environment (or leave unset to use the defaults). Despite the variable name
`CLAUDE_MODEL_SONNET`, the fallback in this workflow is `claude-opus-5` — rename the env var or edit
the fallback string in the `AI Qualify + Book` node if you want a different model on that lane.

## schema.sql

Three tables, derived directly from the queries inside `workflow.json` — `demo_sessions` (token, name,
phone, city, issue, booked_at), `demo_messages` (session_id, sender, body, latency_ms), `demo_bookings`
(session_id, job_type, tech, slot_at). A unique index on `demo_sessions.token` is load-bearing: every
lane after the first looks a session up by token. Column types were **derived from the SQL, not
confirmed against a live `information_schema` dump** — this workflow's tables are not on this repo
author's read-only DB introspection allowlist, so treat the types as sensible defaults, not a verified
export.

## Cost

One short Anthropic call per lead (`AI First Text`, capped at 200 output tokens) and one per reply
(`AI Qualify + Book`, capped at 300 output tokens). No other paid dependency — this workflow does no
media generation and calls no other external API.

## GOTCHAS

Each of these cost a failed run during the build.

- **A data-modifying CTE is invisible to the rest of the same statement.** `Log Lead Text` runs one
  SQL statement with an `ins AS (INSERT INTO demo_messages ... RETURNING session_id)` CTE feeding a
  transcript built by `string_agg` over `demo_messages`. Postgres CTEs all see the _same_ snapshot of
  the table taken at the start of the statement, so the row `ins` just inserted is **not** visible to
  the `string_agg` in the final `SELECT` of that statement, even though logically it "already
  happened." The fix is not another CTE — it's appending the new line by hand:
  `|| E'\nCustomer: ' || $2` on the end of the aggregated transcript. If you refactor this query and
  drop that explicit append, the AI reply lane starts qualifying leads against a transcript that is
  missing the customer's most recent message.
- **The backend ships a finished `slot_label`; the browser must not re-derive it.** `Parse Decision`
  turns the model's `slot_hint` (`today_pm` / `tomorrow_am` / `tomorrow_pm` / `this_week`) into both a
  machine timestamp (`slot_at`, UTC ISO string) and a human string (`slot_label`, e.g.
  "Tomorrow, Sep 18 - 8:00am - 12:00pm") in the same code node, from the same `Date` object. If a page
  instead re-derives the window on the client by formatting `slot_at` itself, timezone conversion from
  UTC can shift the hour across the boundary the model chose (e.g. an 8am-12pm window rendered as
  12pm-4pm), so the chat bubble text and the booking card visibly disagree about the time. Always
  render `slot_label` as-is; never recompute it from `slot_at` in the browser.
- **Inputs are clamped because these endpoints are public.** Every field from `Clean Lead` and
  `Clean Reply` is length-capped and control-character-stripped before it reaches Postgres or the
  model — there is no auth in front of any of the three webhooks. If you fork this for a real intake
  flow, add rate limiting; this demo relies on Anthropic's own token limits and the row-per-request
  cost to keep abuse cheap, not free.
- **`Parse Decision` salvages JSON out of a misbehaving model.** The system prompt tells the model to
  return bare JSON with no markdown fence, but nothing stops it from wrapping the object in prose
  anyway. The code node tries a direct `JSON.parse` first, then falls back to regex-extracting the
  first `{...}` block, and finally falls back to a generic "a technician will call you" message with
  `book: false` rather than throwing and killing the webhook response the homeowner is waiting on.

## Files

```
workflow.json   the importable workflow, 17 nodes, credentials stripped to REPLACE_ME
README.md       this file
schema.sql      demo_sessions / demo_messages / demo_bookings, derived from the queries above
```
