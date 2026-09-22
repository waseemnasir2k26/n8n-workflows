# 05 — Clinic WhatsApp booking agent (Postgres memory, code-side handoff)

`05 Clinic WhatsApp Booking Agent (Postgres memory, code-side handoff)` — 25 nodes (22 working
nodes + 3 sticky notes).

A small clinic gets appointment requests over WhatsApp mixed in with symptom questions, price
questions and the occasional real emergency. This workflow reads inbound WhatsApp-shaped messages,
runs a **deterministic ES/EN safety guard in code, before any model call**, and routes anything
about symptoms, medication, diagnosis, price, or an emergency to a human-handoff row instead of the
AI Agent. Everything left — scheduling and general FAQ — goes to a Tools Agent pointed at
**any OpenAI-compatible chat model with tool calling** (tested with `openai/gpt-oss-20b` via
OpenRouter; Groq's free tier's 8000 TPM per-model ceiling is too small for a 12-patient batch —
three earlier passes on this episode measured 13-15 successful Groq calls before hitting that
ceiling mid-run, well short of the ~22+ calls a full run needs) with Postgres-backed chat memory
per patient and two Postgres tools:
`check_availability` and `book_slot` (the `UPDATE ... WHERE status='free' ... RETURNING` shape makes
double-booking a specific slot impossible by construction, not by a race-condition check).

**Nothing is sent over WhatsApp.** Every reply — the agent's and the handoff notice — is written to
`ep05_outbox` and left there. The WhatsApp Trigger, WhatsApp Send message, and Google Calendar
create event nodes are on the canvas, **disabled**, as the swap points for a live inbox and a real
calendar (see Credentials).

The last node emits one summary item read straight off the execution panel: `patients_simulated`,
`bookings_confirmed`, `median_seconds_to_first_reply`, `handoffs_fired`, `double_bookings`,
`duplicate_webhooks_ignored`, `languages`.

## Compliance — read this before you point it at a real number

**SCHEDULING AND FAQ ONLY. NO SYMPTOMS, NO DIAGNOSIS. NO HEALTH DATA STORED. n8n offers no BAA.**
This is not a clinical tool. The safety guard exists so the model never has to be trusted with a
health question — anything that could be one is handed to a human before it reaches the agent.
`schema.sql` has no PHI columns: message bodies are stored for the demo (dedupe + the guard need the
raw text), but nothing else about a patient is recorded. Do not wire a real clinic's inbox to this
without your own legal review — WhatsApp Business + n8n is not a covered, BAA-backed channel for
protected health information in any jurisdiction that requires one.

Built with 12 fictional patients and 26 synthetic WhatsApp messages
(`samples/patients-es.json`): 8 Spanish-speaking, 4 English-speaking, masked phone numbers only,
one deliberate duplicate message id (Meta webhooks redeliver — a real integration must dedupe, this
demo proves it does). **The demo feeds these samples through a webhook or the manual trigger; it
does not read a live WhatsApp number.**

## The safety guard (code, not a prompt)

`Safety guard` runs a fixed order of deterministic regex checks per message, in Spanish and
English, before anything reaches the model:

| Order | Reason       | Triggers on (examples)                                                                 |
| ----- | ------------ | -------------------------------------------------------------------------------------- |
| 1     | `emergency`  | emergencia / emergency                                                                 |
| 2     | `symptoms`   | dolor, duele, fiebre, sangr-, respirar, manchas / pain, fever, bleeding, breathe, rash |
| 3     | `medication` | medicamento, dosis, ibuprofeno / medication, dose, ibuprofen                           |
| 4     | `diagnosis`  | diagnostico, infeccion, grave / diagnosis, infection, is it serious                    |
| 5     | `price`      | cuanto cuesta, precio, seguro / price, cost, how much, insurance                       |

First match wins. A match sets `handoff=true` and writes a row to `ep05_handoffs` plus a fixed
bilingual notice to `ep05_outbox`: _"Gracias, un miembro del equipo te respondera en breve. /
Thanks, a team member will reply shortly."_ No match → the message goes to the AI Agent.

## Flow, node by node

```
When clicking Execute         Manual trigger --> Load sample conversations (HTTP GET of
                               samples/patients-es.json from this repo, responseFormat=json --
                               raw GitHub serves JSON as text/plain otherwise). The demo path.
ep05-wa-in (webhook)           POST /webhook/ep05-wa-in with a real Meta Cloud API payload shape
                               (entry[].changes[].value.messages[]+contacts[]). Point a WhatsApp
                               Business webhook at it. Never left active outside a sanctioned run.
WhatsApp Trigger (DISABLED)   Swap point: enable + a WhatsApp Cloud credential, polls inbound
                               messages directly instead of the webhook.
   |
Normalize message              Code: flattens any of the three doors into one item per message --
                               {message_id, wa_id, name, lang_hint, text, received_at}. Guesses
                               lang_hint from accented characters / common Spanish words, ASCII-only
                               source (accented comparisons run on char codes, never a literal byte).
   |
Dedupe on message.id           Postgres: INSERT ... ON CONFLICT (message_id) DO NOTHING RETURNING --
                               a redelivered message emits NO downstream item. alwaysOutputData=false.
   |
Safety guard                   Code (per item): the 5-category regex above. Sets handoff + reason.
   |
handoff?                       IF: TRUE -> human handoff. FALSE -> the AI Agent.
   |                    \
   |                     \--> Handoff: insert handoff + outbox   (TRUE branch)
   |                          One Postgres statement (a data-modifying CTE) inserts ep05_handoffs
   |                          then ep05_outbox in a single round trip.
   |
   \--> AI Agent (FALSE branch)
         Tools Agent + Groq gpt-oss-20b (lmChatOpenAi, OpenAI-compatible base URL) + Postgres
         Chat Memory (session key = wa_id, contextWindowLength 6) + two Postgres tools:
           check_availability  SELECT up to 1 morning + 1 earliest-afternoon ep05_slots slot PER DAY
                               for the next 7 days (a window function partitioned on day AND
                               morning/afternoon half, not a flat LIMIT), no arguments -- a flat
                               `LIMIT 8` with no per-day floor let one busy weekday's slots crowd out
                               every later day; a naive "N per day" (no AM/PM split) still only ever
                               returned mornings on a 09:00-17:00 grid, hiding every afternoon
                               request. Both fixed in Pass 5 -- the current query still only returns
                               the EARLIEST slot per half-day, so an arbitrary requested clock time
                               (e.g. "16:00" when the earliest afternoon slot is 13:00) can still be
                               unavailable; that is a known, disclosed limit, not a bug.
           book_slot            UPDATE ep05_slots SET status='booked' ... WHERE status='free' RETURNING
                                (0 rows back = already taken -- no double-book possible by construction)
         System prompt: FIRST line hard-locks the reply language from the deterministic `lang_hint`
         field (`Reply ONLY in {{ Spanish | English }}`) -- a soft "reply in the patient's language"
         instruction was not reliable enough on its own (Pass 4 measured 2/11 replies in the wrong
         language); also instructs the model to never surface internal slot ids to the patient.
         Scheduling + FAQ only, never symptoms / diagnosis / medication / price, offer max 3 slots,
         confirm date+time by day/time only (never an id), <=60 words.
   |
Parse agent output             Code (per item): reads the agent's reply text and, from
                               returnIntermediateSteps, whether book_slot actually returned a row.
   |
Insert outbox (agent reply)    Postgres: every reply into ep05_outbox, kind='agent_reply'.
   |                    \
   |                     \--> Google Calendar create event (DISABLED swap point)
Insert bookings (conditional)  Postgres: INSERT ... SELECT ... WHERE $booked = true -- a no-op
                               (0 rows) when the turn did not end in a confirmed booking.
   |                    \--> WhatsApp Send message (DISABLED swap point)
   |
Run summary                    Code: patients_simulated, bookings_confirmed,
                               median_seconds_to_first_reply, handoffs_fired, double_bookings,
                               duplicate_webhooks_ignored, languages.
   |
Insert ep05_run_summary        Postgres: one row per run, the number the video quotes.

Reminder 24h (DISABLED schedule lane) -- not wired into the run; a future lane that would read
ep05_bookings for tomorrow and remind the patient. Documented, not built.
```

## Credentials — two required, all shipped as `REPLACE_ME`

| #   | Node(s)                                                                                                                                                                                                          | Credential type                         | How to create it                                                                                                                                                                                                                                                                                                                                                                                                 |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Dedupe on message.id`, `Handoff: insert handoff + outbox`, `Postgres Chat Memory`, `check_availability`, `book_slot`, `Insert outbox (agent reply)`, `Insert bookings (conditional)`, `Insert ep05_run_summary` | **Postgres**                            | Any Postgres. Run `schema.sql` first.                                                                                                                                                                                                                                                                                                                                                                            |
| 2   | `OpenRouter gpt-oss-20b`                                                                                                                                                                                         | **OpenAI (generic, base-URL override)** | Type `openAiApi` with `url` set to `https://openrouter.ai/api/v1` and an API key from openrouter.ai — any OpenAI-compatible chat model with tool calling works the same way (swap the URL + key). Tested with Gemini Flash (`https://generativelanguage.googleapis.com/v1beta/openai`) and OpenRouter's `openai/gpt-oss-20b`; Groq's free tier's 8000 TPM per-model ceiling is too small for a 12-patient batch. |
| —   | `WhatsApp Trigger`, `WhatsApp Send message` (both disabled)                                                                                                                                                      | **WhatsApp Cloud API**                  | Optional. Meta developer app + test number, then enable the two nodes.                                                                                                                                                                                                                                                                                                                                           |
| —   | `Google Calendar create event` (disabled)                                                                                                                                                                        | **Google Calendar OAuth2**              | Optional. Enable + pick a calendar to write real bookings there too.                                                                                                                                                                                                                                                                                                                                             |

Create them in **n8n → Credentials → New**, then re-select on the matching nodes after import.

## Run it

1. `schema.sql` against your Postgres (creates 7 tables + seeds `ep05_slots` with a 7-day
   Mon–Sat 09:00–17:00 grid, 30-minute slots, starting tomorrow).
2. Import `workflow.json`, set the two credentials.
3. Press **When clicking Execute** (fetches the 26 samples from GitHub) — never activate the
   workflow for this; the webhook lane is for a real WhatsApp Business integration.
4. Read the numbers straight off the `Run summary` execution panel, or:
   ```sql
   SELECT count(*) FROM ep05_bookings;
   SELECT count(*) FROM ep05_handoffs;
   SELECT slot_id FROM ep05_bookings GROUP BY slot_id HAVING count(*) > 1;  -- must be 0 rows
   ```

## Caps

| Cap               | Where                       | Value                                                                                     |
| ----------------- | --------------------------- | ----------------------------------------------------------------------------------------- |
| Messages per run  | `Normalize message` (`MAX`) | 30, the rest are dropped                                                                  |
| Model             | `OpenRouter gpt-oss-20b`    | `openai/gpt-oss-20b` (swap the node/URL/key for any OpenAI-compatible tool-calling model) |
| Agent iterations  | `AI Agent` options          | 5 max                                                                                     |
| Execution timeout | workflow settings           | 900 s                                                                                     |

## GOTCHAS

Each of these cost a failed run or a wrong number during the build.

- **WhatsApp's core n8n node cannot send interactive buttons or list messages.** A real
  confirm/cancel UI needs raw HTTP Request calls to the Cloud API — the disabled `WhatsApp Send
message` node here is a plain text send, deliberately, as the honest swap-point baseline.
- **Meta webhooks are at-least-once delivery, unordered.** `Dedupe on message.id` is the point,
  not decoration — the sample set ships one deliberate duplicate id to prove it: 26 messages in,
  25 rows in `ep05_messages`, `duplicate_webhooks_ignored=1` in the summary.
- **Raw GitHub serves JSON as `text/plain`.** `Load sample conversations` sets
  `options.response.response.responseFormat = "json"` or every downstream node sees a string, not
  an array.
- **The Postgres node's extended protocol cannot run two parameterized statements in one query
  string.** `Handoff: insert handoff + outbox` uses a single data-modifying CTE (`WITH h AS
(INSERT ... RETURNING ...) INSERT INTO ep05_outbox SELECT ... FROM h`) instead of two separate
  INSERT statements — that is one statement to Postgres, valid with parameters.
- **A conditional insert needs no IF node.** `INSERT INTO ep05_bookings ... SELECT ... WHERE
$booked = true` inserts zero rows when the turn did not end in a booking, keeping the canvas at
  22 working nodes instead of 24.
- **`UPDATE ... WHERE status='free' ... RETURNING` makes double-booking impossible by
  construction**, not by an application-level race check — if a slot is gone, `book_slot` simply
  returns 0 rows and the agent has to offer another one.
- **jsCode must be pure ASCII.** Every Spanish accented character used inside a Code node
  (á, é, í, ó, ú, ñ) is built from `String.fromCharCode` at runtime and matched by comparing char
  codes — never a literal accented byte in the source, so nothing corrupts across a storage
  round-trip (`node --check` was run against the code as stored on the VPS after import, not just
  the local draft).
- **`PUT`/`POST` can activate a workflow that was inactive** — this workflow was GET-verified
  `active: false` immediately after creation and is never activated outside the one sanctioned run.
- **Disabled nodes pass data through.** That is what makes the three swap points safe to ship: the
  chain still runs end to end without WhatsApp or Google Calendar wired up.
- **`$fromAI()` fills tool parameters from the model's own reasoning.** `check_availability`
  takes no parameters at all (an earlier `day` filter typed via `$fromAI(..., 'string')`
  rejected the model's own `null` client-side before the query ever ran — a real n8n
  Zod-schema/`$fromAI` type mismatch, not a model error; removed rather than patched
  nullable). `book_slot`'s `slot_id` is still model-chosen via `$fromAI(..., 'number')`.
- **No Data Tables swap here.** All 7 tables are plain Postgres so the schema is portable to any
  Postgres-compatible host.
- **A flat `LIMIT N` on an availability query is not the same as "N per day."** Sorting free slots
  by start time and taking the first 8 lets one nearby busy day exhaust the limit before a later
  day's slots ever appear, so a patient can explicitly confirm a day the model can never see. Use a
  `row_number() OVER (PARTITION BY day ...)` window and cap per-day, not globally.
- **"N per day" still isn't "a morning and an afternoon option."** Capping at 2 slots/day on a
  09:00-17:00 grid returns the 2 EARLIEST slots, which are both mornings -- an afternoon-specific
  request is still invisible. Partition on `(day, CASE WHEN hour < 13 THEN 0 ELSE 1 END)` instead of
  just `(day)` to guarantee a morning and an afternoon option each, when both exist. Even this only
  returns the EARLIEST slot per half-day -- a patient asking for an exact time (e.g. 16:00 when the
  earliest afternoon slot is 13:00) can still get "not available"; that is an honest limit of a
  small, human-readable slot list, not a bug to chase forever.
- **`$('NodeName').item` inside a Postgres node used as an AI Agent TOOL does not bind to the
  currently-iterating item** the way it does in a normal main-flow node -- it resolves to the tool's
  own first invocation context, so every call across a batch can silently read the SAME item's
  field. `book_slot`'s own `wa_id` write into `ep05_slots` is a known instance of this and is left
  as-is; the correct value is instead written from a real main-flow node (`Insert bookings
(conditional)`, verified item-bound) via a data-modifying CTE that repairs both tables in one
  statement. Never trust `$('NodeName').item` for identity-critical writes inside a tool node --
  verify with a real execution, not just by reading the expression.
- **A soft "reply in the patient's language" system-prompt line is not reliable.** Pass the
  deterministic language classification in as data (`lang_hint`) and hard-lock it as the literal
  first line of the system prompt, not a suggestion buried in the middle of a longer instruction.
- **Never let the model see an internal row id it might repeat back.** `check_availability`'s
  numeric `id` has to reach `book_slot` (`$fromAI('slot_id', ...)`), but the system prompt must
  explicitly forbid quoting that id (or any id) back to the patient, or a reply will leak it as
  "(id 1)" next to the offered slot.

## Files

```
workflow.json               the importable workflow, 25 nodes, credentials stripped to REPLACE_ME
README.md                   this file
schema.sql                  7 tables (messages, sessions, slots, bookings, outbox, handoffs, run_summary)
samples/patients-es.json    26 synthetic WhatsApp messages, 12 fictional patients, masked phones
```

MIT — see the repository root.
