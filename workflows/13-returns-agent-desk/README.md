# 13 — Returns Agent Desk

`EP13 Returns Agent Desk (team of agents, rules first, human approval queue, DRY RUN refunds)` — **39 nodes** (plus 3 sticky notes) and a 4-node error workflow.

A mid-size shop gets two dozen return requests a day. Most are boring: wrong size, still in the bag,
refund it. A few are not: a final-sale dress, a tablet opened and set up, a customer on their ninth
return this year, a 420-dollar TV with a cracked screen and no photo. This workflow sorts them with a
**team of AI agents**, each doing one job, and a **rule engine that runs before any of them**.

Clean low-value cases are approved. Anything flagged or expensive waits in a queue for a person, who
approves or declines on their own terms. Hard policy failures are rejected with the rule that applies.

Then it stops. **There is no payment node.**

## Nothing in it can move money or reach your customer

Open the JSON and check the node list yourself. **No HTTP Request node. No payment node. No email node.
No messaging node.** Not present, not disabled, not as an example.

- An approved refund is one line of text: `WOULD REFUND 24 - DRY RUN (no payment node exists)`, written
  by the Code node `WOULD REFUND (dry run)` and stored in the ledger.
- An approved exchange is `WOULD SHIP EXCHANGE JKT-RAIN-L - DRY RUN`.
- Every customer reply is a **draft** in a Data Table, suffixed `[DRAFT - not sent]`.

The only outbound calls are the five AI Agent nodes talking to the model endpoint you choose (shipped
pointing at OpenRouter, `openai/gpt-oss-20b`). Those calls carry the request text and rule results to a
model. They carry no payment instruction and have no route to a customer.

Issuing the refund is **your own action**, in your own payment system, outside this file.

## The team

| Agent node                     | Job                                                                                                                 | Runs on                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `Orchestrator agent`           | Reads each request, classifies the reason, checks the customer's words against the reason they picked, picks a lane | every request                                         |
| `Policy agent`                 | Explains the policy ruling (window, condition, final sale). Cannot overturn a hard rule fail                        | the policy lane                                       |
| `Fraud agent (second opinion)` | Says what a human should check. Cannot lower the rule score, cannot clear a flag                                    | fraud lane, borderline scores only (30-59)            |
| `Inventory agent`              | restock / refurbish / write_off / exchange / inspect                                                                | the inventory lane                                    |
| `Reply drafter agent`          | Words the customer reply for cases a human reviews or that were rejected. Never sent                                | human-review + rejected cases, while LLM budget lasts |

All five share one model node, `OpenRouter gpt-oss-20b`. Each agent node has `retryOnFail` 3 tries,
20 s apart, and `onError: stopWorkflow` so a model failure stops the run and reaches the error workflow.

## Rules first, the model second

`Rules precheck` runs **before any model call**:

| Rule | Meaning                                                                       | Effect       |
| ---- | ----------------------------------------------------------------------------- | ------------ |
| P1   | change-of-mind or fit return after `return_window_days` (30)                  | hard fail    |
| P1b  | defect / wrong / damaged claim after `defect_window_days` (90)                | hard fail    |
| P1c  | defect claim between 30 and 90 days                                           | human review |
| P2   | final-sale item, unless wrong item or damaged in transit                      | hard fail    |
| P2b  | final-sale item with a wrong/damaged claim                                    | human review |
| P3   | opened hygiene item (beauty, swimwear, underwear, earbuds) on change of mind  | hard fail    |
| P4   | used or worn item on change of mind or fit                                    | hard fail    |
| P4b  | opened electronics on change of mind                                          | human review |
| F1   | serial returner: at least 5 returns and return rate at least 50% in 12 months | +40          |
| F2   | refunds in 12 months at least 1000                                            | +20          |
| F3   | any chargeback in 12 months                                                   | +30          |
| F4   | apparel worn with tags removed (wardrobing signal)                            | +20          |
| F5   | value at least 150, defect/damage claim, no photo                             | +25          |
| F6   | account younger than 30 days, value at least 200                              | +15          |

`Parse + lane guard` then applies the orchestrator's choice **only where the rules allow it**:
fraud score at or above `fraud_human_threshold` (30) forces the fraud lane, a policy fail or review
forces the policy lane, a customer text that contradicts the chosen reason code goes to the policy lane,
and `fast_track` is only allowed when the rules say the case is fast-track eligible. The model can add
scrutiny. It can never remove it. Every override is counted and stored (`lane_overridden`).

## The decision (deterministic)

`Risk router` is a Code node, not a model:

1. Hard policy fail -> **reject**, with the rule text as the reason.
2. Any fraud score at or above 30, any policy review, a reason mismatch, a specialist asking for a human,
   a specialist confidence under 0.6, or a refund over `auto_approve_max_value` (75) -> **human review**.
3. Everything else -> **auto-approve** (refund, or an in-stock exchange with 0 refund).

A flagged case never auto-approves. A rejection never depends on a model's opinion.

## The human approval gate ("on your terms")

Human-review cases land in the Data Table `ep13_approval_queue` with `approval_status =
awaiting_human_approval`, the reasons, the fraud flags, the specialist's view and a reply draft.

A person decides by POSTing to the second webhook, `Approval decision in` (`/webhook/ep13-approval`):

```json
{ "queue_ref": "ep13-41594-R08", "decision": "approve", "refund_amount": 120, "approver": "sam", "note": "partial, missing box" }
{ "queue_ref": "ep13-41594-R19", "decision": "decline", "approver": "sam", "note": "ninth return, offer store credit by phone" }
```

`Validate decision` refuses anything but `approve` / `decline`, refuses a row that was already decided,
and refuses a `refund_amount` above the original. `Update queue row` stores the decision,
`Ledger: human decision` appends it to the ledger, and the reply is still `WOULD REFUND ... - DRY RUN`.

## Caps (Data Table `ep13_caps`, one row, `cap_id = ep13`)

| Column                                        | Seed   | Used by                                                                                       |
| --------------------------------------------- | ------ | --------------------------------------------------------------------------------------------- |
| `kill_switch`                                 | false  | `Caps gate` throws before any model call when true                                            |
| `breaker_tripped`                             | false  | `Caps gate` throws when true; set by the error workflow after 3 consecutive errors            |
| `max_items_per_run`                           | 24     | step cap: requests beyond it are deferred                                                     |
| `max_llm_calls_per_run`                       | 58     | `Caps gate` reserves 2 calls per request; `Draft budget check` gives drafts only what is left |
| `llm_calls_per_day`                           | 200    | daily ceiling, with `llm_calls_today` (bumped by `Bump caps` after each run)                  |
| `est_usd_per_call`                            | 0.0003 | spend cap: budget x this must not exceed `spend_cap_usd_per_run`                              |
| `spend_cap_usd_per_run`                       | 0.05   | see above; `Caps gate` throws if the budget could exceed it                                   |
| `auto_approve_max_value`                      | 75     | refund ceiling for auto-approval                                                              |
| `return_window_days`                          | 30     | P1                                                                                            |
| `defect_window_days`                          | 90     | P1b / P1c                                                                                     |
| `fraud_human_threshold`                       | 30     | fraud lane + human review                                                                     |
| `fraud_borderline_max`                        | 59     | fraud scores 30-59 get the Fraud agent's second opinion; 60+ the rules alone decide           |
| `consecutive_errors` / `error_trip_threshold` | 0 / 3  | error workflow counter and trip point                                                         |
| `last_run_id`, `last_error`                   | ""     | written by `Bump caps` and the error workflow                                                 |

Wall-clock: `settings.executionTimeout = 900` (15 minutes).

## Flow, node by node

**Intake**

1. `Run fixture (manual)` — manual trigger for the test run.
2. `Load fixture (24 synthetic)` — the 24 synthetic requests from `fixture-return-requests.json`, inline.
3. `Return request in` — POST `/webhook/ep13-return-request`, one request or `{ "requests": [...] }`.
4. `Normalize request` — required fields check, days since delivery, flat history fields.
5. `Load caps` — reads `ep13_caps` once (`executeOnce`).
6. `Caps gate` — kill switch, breaker, item cap, LLM budget, spend cap. Throws, never skips silently.
7. `Rules precheck` — policy rules P1-P4b and fraud rules F1-F6, then builds the orchestrator prompt.

**Orchestration**

8. `Orchestrator agent` + `OpenRouter gpt-oss-20b` — one call per request, raw JSON out.
9. `Parse + lane guard` — parses, enforces the rule-forced lanes, builds the specialist prompt.
10. `Route to specialist` — Switch: `policy` / `fraud` / `inventory` / `fast_track`.

**Specialist lanes**

11. `Policy agent` -> 12. `Parse policy ruling` (a hard fail stays a hard fail; disagreement is logged).
12. `Borderline fraud score?` -> 14. `Fraud agent (second opinion)` -> 15. `Parse fraud opinion`. Scores of 60+ skip the model: the rules alone send them to a human.
13. `Inventory agent` -> 17. `Parse disposition` (an exchange is only allowed if it was requested and the SKU is in stock).
14. `fast_track` goes straight on, no model call.
15. `Merge lanes` — 5 inputs, append.

**Decision + drafts**

20. `Risk router` — auto-approve / human review / reject, with reasons.
21. `Draft budget check` — counts calls already spent, gives drafts the rest, templates the remainder.
22. `Needs an LLM draft?` -> 23. `Reply drafter agent` -> 24. `Parse draft (never sent)` (rejects any draft that claims money already moved or mentions fraud signals to the customer).
23. `Merge drafts`.
24. `Decision` — Switch: `auto_approve` / `human_review` / `reject`.
25. `WOULD REFUND (dry run)` · 28. `Approval queue row` (insert into `ep13_approval_queue`) · 29. `Reject with reason`.
26. `Merge outcomes` -> 31. `Ledger write` (insert into `ep13_ledger`, one row per request) -> 32. `Run summary` -> 33. `Bump caps`.

**Approval lane**

34. `Approval decision in` -> 35. `Find queue row` -> 36. `Validate decision` -> 37. `Update queue row` -> 38. `Ledger: human decision` -> 39. `Reply to approver`.

**Error workflow** (`error-workflow.json`): `Error Trigger` -> `Read caps` -> `Count error + trip check` -> `Write counter + breaker`.

## The proof run (fixture, 2026-09-29)

One manual run on our own n8n (2.33.7), workflow inactive before and after, execution `41594`,
2026-09-29 11:48:51 to 11:59:37 UTC (10 min 46 s). Input: the 24-request **synthetic fixture**.

| What                         | Observed                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| Lanes                        | policy 8 · fraud 5 · inventory 6 · fast_track 5                                            |
| Decisions                    | auto-approve 8 · human review 11 · reject 5                                                |
| Approval queue rows          | 11 (all `awaiting_human_approval`)                                                         |
| Ledger rows                  | 24                                                                                         |
| Fraud flags fired            | F1 serial returner 3 · F2 high refund value 2 · F3 chargeback 2 · F4 wardrobing 1 · F5 no-photo high value 1 · F6 new account high value 2 |
| Policy                       | 5 hard fails (rejected) · 3 reviews · 1 customer text contradicting the reason code       |
| Model calls                  | 57 (orchestrator 24 · policy 8 · fraud 3 · inventory 6 · reply drafter 16), budget 58, 0 model errors |
| Tokens                       | 21,606 prompt · 30,668 completion                                                          |
| Replies                      | 16 model drafts · 8 templates · 0 sent                                                     |
| Refunds                      | `WOULD REFUND` lines totalling 270 across 7 refunds + 1 `WOULD SHIP EXCHANGE`; 0 executed |
| Lane guard                   | 1 orchestrator lane overridden by the fraud rules                                          |

An earlier run the same day (execution `41585`) finished too, but the orchestrator sent every
defect, damage, wrong-item and exchange case to the policy lane, so the inventory lane never fired. The
lane definitions were tightened and the guard now sends a "policy" pick with no policy question to
inventory. That run's table rows were deleted; the execution is kept.

## Try it with the fixture

`fixture-return-requests.json` is a **FIXTURE: 24 synthetic return requests written by hand for this
episode.** No real customer, order, email address or payment appears in it. Every history figure is
invented. It is built so every lane fires: 5 clean fast-track cases, 6 inventory cases (including one
exchange), 8 policy cases (hard fails and reviews, including a final-sale item and one customer whose
text contradicts the reason they picked), and 5 fraud cases (serial returner, chargeback history,
no-photo high-value damage claim, a wardrobing pattern, and one with three flags).

## What you need

- An OpenAI-compatible credential (`openAiApi`) with the base URL set to your provider. Shipped pointing
  at OpenRouter with `openai/gpt-oss-20b`. Credential id is `REPLACE_ME`.
- Three n8n Data Tables (n8n 2.30+): `ep13_caps`, `ep13_approval_queue`, `ep13_ledger`. Columns and the
  caps seed row are in `data-tables.json`. Create them in the UI or with `POST /api/v1/data-tables`,
  then replace every `REPLACE_ME` Data Table id in `workflow.json` and `error-workflow.json`.
- Import `error-workflow.json` first and put its id in `settings.errorWorkflow` of `workflow.json`.

## What to edit before you use it

- Your policy: the P rules and the category lists in `Rules precheck`, and the windows in `ep13_caps`.
- Your fraud rules: F1-F6 weights in `Rules precheck`. Tune against your own returns history before trusting them.
- `STOCK` in `Rules precheck` is an illustrative stock sheet. Swap it for your inventory lookup.
- The reply templates in `Draft budget check`.

## GOTCHAS

- **One model node feeds five agents.** The LLM call count for a run is the number of runs of
  `OpenRouter gpt-oss-20b` in the execution data, including retries. The in-workflow counter in
  `Run summary` counts agent items, which excludes retries.
- **The AI Agent node output is only `{ output }`.** Every parse node runs `runOnceForEachItem` and pulls
  the request back with `$('Parse + lane guard').item` (paired items). Without per-item mode the outputs
  collapse to one item.
- **`lmChatOpenAi` `model` is a plain string**, not a resource-locator object, or LangChain throws.
- **Manual run is not activation.** The test run was started from the manual trigger with the workflow
  inactive; both webhooks only listen when you activate it.
- **Merge with 5 inputs in append mode** waits for every connected input that will run. Lanes with no
  items simply contribute nothing.
- **Load caps runs once.** Without `executeOnce` a Data Table get fed N items runs N times.
- **The expression sandbox refuses some identifiers** (`caller` for one). Field names here avoid them.
- **No `URL` / `URLSearchParams` in the Code sandbox.** Nothing here parses URLs.
- **Never auto-reject on a fraud score.** Fraud flags route to a human. Only a written policy rule rejects.
- **A model draft can say the wrong thing.** `Parse draft (never sent)` swaps in a neutral template if a
  draft claims money moved or mentions fraud signals; the count is in the ledger (`draft_source`).

- **The orchestrator will over-escalate if you let it.** With loose lane definitions gpt-oss-20b put
  every defect and exchange case in the policy lane (run `41585`). Define each lane by the rule facts it
  can see, and have the guard downgrade a lane that has no rule basis to the one that does the work.
- **It is slow on purpose.** 57 sequential model calls took 10 min 46 s on gpt-oss-20b through
  OpenRouter. `executionTimeout` is 900 s; a bigger batch needs a bigger timeout or a faster model.

## Files

- `workflow.json` — the 39-node workflow (placeholders `REPLACE_ME`, no secrets).
- `error-workflow.json` — the 4-node error workflow.
- `fixture-return-requests.json` — the 24 synthetic requests (FIXTURE).
- `data-tables.json` — the three Data Table schemas and the `ep13_caps` seed row.

MIT licensed, like the rest of the repo.
