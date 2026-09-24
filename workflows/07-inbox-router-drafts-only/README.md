# 07 -- Inbox Router (rules-first, drafts only, no send)

`EP07 Inbox Router (rules-first, drafts only, no send)` -- 18 nodes (16 working
nodes + 2 sticky notes).

A small consulting or agency inbox mixes leads, technical support, spam and
existing-client mail in one place, and every hour of triage is an hour not spent
on the work itself. This workflow polls one mailbox (IMAP, disabled here -- manual
test only), sorts it with a **deterministic rules router first** (known-client
allowlist, spam heuristics, regex intents), and only sends the residue -- the mail
the rules genuinely cannot call -- to one LLM node that classifies it and drafts a
reply. Every row lands in Postgres. **There is no send node on this canvas.**

**GATE (from the mission spec):** ship only if rules handle >= 60% of mail. On the
13-row sample set (`samples/inbox-sample.json`, 12 clean rows + 1 deliberate edge
case that must reach the model), the rules router handles **12/13 = 92.3%** --
verified by extracting `Mask + normalize` and `Rules router`'s stored `jsCode` and
running them against the sample file with `node`, not by eyeballing the code (see
"How the numbers were measured" below).

## Real mailbox number, honestly scoped

The mailbox this workflow points at (`skynetlabsai.com` IMAP, our own domain) has
**8 messages total** as of 2026-09-24 -- too few for the mission spec's original
"tune on days 1-7, measure on days 8-14" hold-out. That hold-out needs a mailbox
with real ongoing volume; this one does not have it yet. What IS real: a read-only
smoke test (below) proved the IMAP credential works and can read actual messages,
masked before anything left the terminal. The rules-handled share above is measured
against the 13 synthetic samples instead, which is what the mission's REFUTE-FIRST
step explicitly asks for. A production fork against a live agency inbox should
re-run the hold-out once 14 days of real volume exist.

## Smoke test (read-only, 2026-09-24)

Ran directly against the `skynetlabsai.com IMAP` credential (decrypted server-side
via `n8n export:credentials`, used only in-memory for one Python IMAP session, then
deleted -- the password was never printed):

```
MAILBOX_TOTAL: 8
MSG sender_hash=sender_49d70752 subject_masked='Undelivered Mail Ret...'
MSG sender_hash=sender_33461d88 subject_masked='Undelivered Mail Ret...'
MSG sender_hash=sender_ac1195e6 subject_masked='=?UTF-8?Q?PLEASE_ADV...'
```

Mailbox opened `readonly=True`; no flags changed, nothing deleted, nothing sent.
This proves the credential + at least one real message can be read, masked before
ever being written down.

## How the numbers were measured (not eyeballed)

1. Extracted the stored `jsCode` from `Mask + normalize`, `Rules router` and
   `WRITE WHITELIST GATE` out of `workflow.json` and ran `node --check` on all six
   Code nodes' jsCode -- 0 syntax errors, pure ASCII (0 non-ASCII bytes) verified
   byte-by-byte.
2. Ran the extracted `Mask + normalize` + `Rules router` code, with a harness
   `$('Load caps')` returning the reference caps row, against all 13 rows of
   `samples/inbox-sample.json`. Result: **12 rules-handled, 1 model-handled**
   (the deliberate `unknown-edge` row), matching every row's `expected_classification`
   field exactly, including the `bounce-edge` row correctly classified `spam` via
   the bounce regex (not left `unknown`).
3. **REFUTE-FIRST:** fed `WRITE WHITELIST GATE`'s extracted code a crafted item
   `{id:1, classification:'lead', kind:'send', to:'someone@example.com', body:'hi'}`
   through the same harness. Result: **threw** --
   `WRITE WHITELIST: refusing item of kind "send". Only kind=label may reach the
mailbox.` A second, legitimate item (`{id:2, classification:'technical'}`, no
   `kind` field -- the real shape `Write inbox row` ever produces) correctly
   produced `{"kind":"label","name":"EP07/technical"}`.
4. **Breaker rehearsal:** simulated 3 consecutive IMAP/LLM errors by driving the
   `ep07_caps` Data Table through the same update the error workflow's `Bump error
counter` node performs (`consecutive_errors: 1, 2, 3`; `breaker_tripped` computed
   with the identical expression). The row read back `breaker_tripped: true` after
   the 3rd write, matching `error_trip_threshold: 3`. Reset both columns to
   `0` / `false` afterward -- the live Data Table ships in its clean, armed state.

## Compliance -- the only write is a label

`WRITE WHITELIST GATE` reads any caller-supplied `kind` FIRST and throws on
anything that is not `label` (mirrors EP06's `j.kind !== 'pause' -> throw`), then
builds the write body itself from constants -- `{kind:'label',
name:'EP07/<classification>'}` -- so the only object that can ever reach the
mailbox is a label. There is no code path that can emit a send, a reply, a delete
or a move. `dry_run` in the caps row defaults `true`: no label is ever applied: the
`Apply label` node ships **disabled** as a swap point (see "There is no send node"
sticky and GOTCHAS below), and `Run summary` only counts what WOULD be labelled.

This workflow is never left `active` on the instance. `Every 15 minutes: IMAP poll
(own mailbox)` (the Email Trigger IMAP node) ships disabled; the sanctioned way to
run it is `Manual Test` from the editor, which drives the disabled `Load sample
inbox` swap point instead of a real mailbox.

## Flow, node by node

```
Every 15 minutes: IMAP poll (own mailbox)   Email Trigger (IMAP), DISABLED. Its own
  (Email Trigger IMAP, cron: every minute)  poll interval IS the "every 15 minutes"
                                             cadence in production -- swap the
                                             pollTimes interval before enabling.
Manual Test (Manual Trigger)                The sanctioned way to run this workflow.
   |                                \
Load caps                            Load sample inbox (HTTP GET, DISABLED)
  Data Table `get`: the one row        Raw GitHub copy of samples/inbox-sample.json,
  from ep07_caps (thresholds,          responseFormat=json (raw GitHub serves JSON
  known_client_domains, dry_run,       as text/plain otherwise). Demo swap point --
  kill_enabled, breaker_tripped).      already-masked-shape rows so this lane
  Both triggers feed this AND          exercises identical downstream code to a
  Mask + normalize directly (see       real IMAP poll.
  GOTCHAS -- sibling-branch $()             |
  references, not a merge).                 |
   |  (leaf -- referenced by name       ____/
   |   downstream, not chained)       /
Mask + normalize  <---------------------
  Code (runOnceForAllItems): folds THREE guards into one node -- armed-guard
  (kill_enabled && !breaker_tripped -> zero items), max_msgs_per_run slice, AND
  masking BEFORE anything is stored: sender -> stable sender_NNNNN via an in-run
  djb2 hash (pure JS -- no crypto/URL builtins in the Code sandbox), subject
  truncated to 60 chars with any embedded email address stripped, body kept ONLY
  on this item for this run (never written to Postgres). Handles both the live
  IMAP 'simple' format and the disabled sample lane's {rows:[...]} shape.
   |
Rules router
  Code (runOnceForEachItem): known-client allowlist (from ep07_caps
  known_client_domains) -> spam/bounce regex -> technical regex -> lead regex ->
  else route='model'. Order matters -- allowlist checked first so a known
  client's mail is never mis-routed to spam.
   |
Route: rules or model (IF on route === 'model')
   |                                    \
   |  (rules, ~92%)                      \ (model, the residue)
   |                                Count LLM calls today (Postgres SELECT --
   |                                  the REAL count from ep07_inbox today,
   |                                  not a magic number)
   |                                     |
   |                                Guard: cap
   |                                  Code: reads llm_calls_per_day from
   |                                  ep07_caps and the real count above, THROWS
   |                                  before any item reaches the LLM node once
   |                                  the cap is met. Placed BEFORE the LLM node.
   |                                     |
   |                                LLM classify + draft (HTTP POST, OpenRouter)
   |                                  openrouter.ai/api/v1/chat/completions,
   |                                  model: "openai/gpt-oss-20b" as a PLAIN
   |                                  STRING, cred openrouter-jew (httpHeaderAuth).
   |                                  retryOnFail 3x20s.
   |                                    /
Confidence gate  <----------------------
  Code (runOnceForEachItem): merges both upstream shapes into one. confidence <
  0.7 -> classification downgraded to needs_review (original_classification kept
  for the run summary tally).
   |
Write inbox row (Postgres INSERT ... ON CONFLICT (idempotency_key) DO NOTHING)
   |
WRITE WHITELIST GATE
  Code: see "Compliance" above. Refute-first tested -- see "How the numbers were
  measured", item 3.
   |
Dry run? (IF on ep07_caps.dry_run)
   |  (true, default)          \ (false)
   |                       Apply label (Gmail node, DISABLED swap point -- see
   |                         GOTCHAS: no core node applies IMAP labels)
   |                            /
Run summary  <-------------------
  Code (runOnceForAllItems): the numbers the video quotes -- msgs_in,
  rules_handled, model_handled, leads, needs_review, spam, technical,
  existing_client, sent (always 0), labels_gated, rows_written, dry_run.
```

## Credentials -- three required, all shipped as `REPLACE_ME`

| #   | Node(s)                                                                  | Credential type                          | How to create it                                                                                                                                           |
| --- | ------------------------------------------------------------------------ | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Every 15 minutes: IMAP poll (own mailbox)`                              | **IMAP**                                 | Your OWN mailbox only, never a client's. App Password + `imap.<host>:993` (see memory `reference-gmail-consumer-mailbox-automation` if it's a free Gmail). |
| 2   | `Count LLM calls today`, `Write inbox row`, `Log error` (error workflow) | **Postgres**                             | Any Postgres. Run `schema.sql` first.                                                                                                                      |
| 3   | `LLM classify + draft`                                                   | **Generic Header Auth (httpHeaderAuth)** | An OpenRouter API key as an `Authorization: Bearer <key>` header credential.                                                                               |
| --  | `Apply label` (disabled)                                                 | **Gmail OAuth2**                         | Optional swap point only -- see GOTCHAS. Not needed for a plain-IMAP mailbox.                                                                              |

The Data Table `ep07_caps` is not a credential -- see `data-table-spec.md`.

## Run it

1. Create the Data Table `ep07_caps` (native n8n Data Table, 2.30+) with the
   columns in `data-table-spec.md` and insert one row. Point `Load caps` /
   `Read caps` (error workflow) `dataTableId` at it (repo ships `REPLACE_ME`).
2. `schema.sql` against your Postgres (3 tables: `ep07_inbox`, `ep07_run_summary`,
   `ep07_errors`).
3. Import `workflow.json`, set the IMAP / Postgres / OpenRouter credentials.
4. Import `error-workflow.json`, set its Postgres credential + `dataTableId`, and
   point the main workflow's `settings.errorWorkflow` at its id. It is
   load-bearing, not optional -- it is what bumps `consecutive_errors` and trips
   `breaker_tripped` (see "The error-trip loop" below).
5. Press **Manual Test** (drives the disabled `Load sample inbox` swap point by
   default -- enable the IMAP trigger only when you are ready to point this at a
   real mailbox, and keep it disabled otherwise). Read the numbers off
   `Run summary`, or:
   ```sql
   SELECT classification, route, count(*) FROM ep07_inbox GROUP BY 1,2 ORDER BY 1;
   SELECT * FROM ep07_inbox ORDER BY id DESC LIMIT 5;
   ```

## Caps (the Data Table row -- see `data-table-spec.md` for the full column list)

| Cap                    | Value (reference deployment)  |
| ---------------------- | ----------------------------- |
| `max_msgs_per_run`     | 50                            |
| `max_msgs_per_day`     | 200 (documented, see GOTCHAS) |
| `llm_calls_per_day`    | 40 (enforced)                 |
| `error_trip_threshold` | 3 (enforced)                  |
| `dry_run`              | true                          |
| `kill_enabled`         | true                          |
| Execution timeout      | 300 s (workflow settings)     |

## The LLM call cap (enforced)

`Count LLM calls today` runs a real Postgres `SELECT count(*) FROM ep07_inbox WHERE
route = 'model' AND received_at::date = current_date` immediately before `Guard:
cap`, which throws if that count is already `>= llm_calls_per_day`, and otherwise
slices the current batch down to whatever headroom remains. This is the real
number, not a running total kept in memory -- it survives a workflow restart.

## The error-trip loop (enforced)

`LLM classify + draft` and the two Postgres write nodes all keep n8n's default
`onError` (stop the workflow) -- never `continueErrorOutput`. A stopped execution
fires `settings.errorWorkflow` (`error-workflow.json`'s own id): `Error Trigger`
-> `Log error` (INSERT into `ep07_errors`) -> `Read caps` (Data Table `get`) ->
`Bump error counter` (Data Table `update`, `consecutive_errors = prior + 1` AND,
in the SAME write, `breaker_tripped = (prior + 1) >= error_trip_threshold`).
`Mask + normalize`'s armed-guard reads `breaker_tripped` on the next run and
returns zero items -- a tripped breaker never un-trips itself; reset both columns
by hand in the Data Table. Rehearsed 2026-09-24 (see "How the numbers were
measured", item 4): 3 simulated errors tripped it, then it was reset clean.

## REFUTE-FIRST (write-scope enforcement, tested not asserted)

A crafted item `{classification:'lead', kind:'send', to:'someone@example.com',
body:'hi'}` fed directly into `WRITE WHITELIST GATE`'s extracted code throws:
`WRITE WHITELIST: refusing item of kind "send". Only kind=label may reach the
mailbox.` The gate reads any caller-supplied `kind` first and refuses anything
that isn't `label` -- the real pipeline never sets a `kind` field upstream at all
(`Write inbox row`'s Postgres output has no such key), so this is a genuine refusal
path, not a check that never fires.

## GOTCHAS

- **No core n8n node applies a label/flag over plain IMAP.** Only the trigger node
  `Email Trigger (IMAP)` exists in core -- there is no core "IMAP action" node for
  marking/flagging a message after the fact (confirmed via `n8n-mcp search_nodes`,
  which returns only the trigger + third-party community packages for `imap`).
  `Apply label` ships as a **Gmail node, disabled**, as the mission spec's literal
  swap point -- it is honest about not being wired to this IMAP mailbox; a
  production fork against Gmail would enable it for real, a fork that stays on
  IMAP would need a community IMAP-STORE node or a raw IMAP call in a Code node
  instead. Either way the workflow ships `dry_run: true` and this node disabled,
  so nothing is ever actually labelled by this repo's reference deployment.
- **`Load caps` is a sibling branch, not an in-line merge.** Both triggers connect
  to `Load caps` AND directly to `Mask + normalize` in parallel (same fan-out
  pattern as EP06's `Build insights request -> [Fetch insights, Load sample
insights]`), because a `dataTable get` node's own output (the caps row) would
  otherwise replace the N real email items flowing through the main chain. Every
  downstream Code/Postgres node that needs a cap value reads it via
  `$('Load caps').first().json`, which works because Load caps executed earlier in
  the same run (an n8n `$()` reference works for any node that has already run in
  that execution, not only a direct upstream connection -- EP06 already relies on
  this for `WRITE WHITELIST GATE` referencing `$('Load caps')`).
- **The Code sandbox has neither `crypto` nor `URL`/`URLSearchParams`** (memory
  `reference-n8n-api-patch-gotchas` #13). `Mask + normalize`'s sender hash and
  idempotency key use a pure-JS djb2 string hash instead of any crypto builtin --
  it is not cryptographically strong, but it only needs to be stable and cheap,
  which djb2 is.
  `known_client_domains` is intentionally the domains list, not literal client
  business names -- masking happens one node earlier than the write, same
  ordering EP06 uses for ad-account ids.
- **`max_msgs_per_day` is documented, not enforced** in this single-manual-run
  demo, the same disclosed gap EP06 left for its `cooldown_minutes` column -- a
  production fork needs a Postgres count of the day's processed rows the same way
  `Count LLM calls today` already does for the LLM cap specifically.
- **Every Code node declares an explicit `mode`.** `Mask + normalize`, `Guard:
cap` and `Run summary` are `runOnceForAllItems` (they aggregate, slice or filter
  across the whole batch); `Rules router` and `Confidence gate` are
  `runOnceForEachItem` (one verdict per message); `WRITE WHITELIST GATE` is
  `runOnceForAllItems` (it needs to see every item to build one `out` array and
  early-throw on the first bad one).
- **Disabled nodes pass data through.** That is what makes `Every 15 minutes:
IMAP poll`, `Load sample inbox` and `Apply label` safe to ship on the canvas as
  swap points -- the chain still runs end to end without them enabled.
- **`jsCode` must be pure ASCII.** Verified byte-by-byte across all six Code
  nodes' extracted, stored jsCode (0 bytes outside 32-126 / tab / LF / CR) --
  `node --check` was also run against every one before this workflow was posted
  to the VPS.
- **Node budget:** 18 nodes total (16 working + 2 sticky), 2 short of the 20-node
  cap -- no fold was needed to stay under it, unlike EP06.
- **`raw.githubusercontent.com` serves JSON as `text/plain`.** `Load sample
inbox` sets `options.response.response.responseFormat = "json"` or every
  downstream node sees a string, not an object (same fix as EP04/EP06).
- **This is a portfolio/demo repo, not a production triage system.** A real
  agency inbox needs the `max_msgs_per_day` lookup above, a longer measurement
  window for the hold-out, and a second human eyeball on `ep07_caps.dry_run`
  before it is ever flipped to `false`.

## Files

```
workflow.json                    the importable workflow, 18 nodes (16 + 2 sticky),
                                  credentials and Data Table id stripped to REPLACE_ME
error-workflow.json              Error Trigger -> Postgres ep07_errors -> Data Table
                                  get + update (bumps consecutive_errors, trips breaker_tripped)
README.md                        this file
schema.sql                       3 tables (inbox, run_summary, errors)
data-table-spec.md               ep07_caps Data Table column spec + the reference row
samples/inbox-sample.json        13 synthetic rows: 3 lead, 3 technical, 3 spam,
                                  2 existing_client, 1 bounce edge case (classified
                                  spam via the bounce regex), 1 unknown edge case
                                  (the deliberate residue that reaches the model)
ids.txt                          VPS workflow/Data Table ids, credential ids (no values)
```

## Build notes

- 2026-09-25: the `Run summary` Code node's `spam`/`technical`/`existing_client`/`model_handled`
  counters were reading a field (`original_classification`) that `Write inbox row`'s RETURNING
  clause never carries -- silently undercounted those buckets to 0 on every real run. Fixed to
  read `classification` (the field the row actually returns for every route, rules or model).
  `rules_handled`/`model_handled` off `route`, `leads` off `classification === 'lead'` unchanged.
  Verified against psql ground truth for execution 34716: 13 in, 12 rules / 1 model, 5 spam,
  3 lead, 3 technical, 2 existing_client.

## Install it for your business

WhatsApp +92 300 1001957 · Waseem Nasir, SkynetLabs

Hire SkynetLabs, our Top Rated agency on Fiverr: https://www.fiverr.com/agencies/skynetjoellc

Repo: github.com/waseemnasir2k26/n8n-workflows

MIT -- see the repository root.
