# 12 — Your foreman sends a photo, you send a price

`EP12 Photo from site -> line-itemed quote draft (human approval gate, no send step, 12 nodes)` — **12 nodes**.

Your lad on site sends a photo at four o'clock. You write the quote at nine that night, after dinner,
tired. This lane does the typing: the photo and his note go in, a vision model reads them, the work it
can see is matched against **your** rate card, and a line-itemed draft is waiting in a table before you
have left the site.

Then it stops.

## It does not send anything

**There is no send step in this workflow at all.** Not disabled, not commented out, not as an example.
Grep the file: there is no email node, no SMTP, no Gmail, no Twilio, no WhatsApp, no SMS, no Slack, no
Telegram, no CRM. The flow ends with a drafted quote sitting in a table.

The one outbound HTTP call it makes goes to **your vision model endpoint**, carrying the photo and the
site note. It never carries a quote and it never goes to a customer. The Respond-to-Webhook node replies
to whatever posted the photo — your own intake, your own foreman's form — not to a customer.

Sending the approved quote is **your own action**, taken by you, outside this file. That is not a gap in
the build. It is the build.

## The approval gate is the build, not a caveat

Node 9 is a **Wait** node called `APPROVAL GATE - wait for a human`. The execution stops dead there and
stays stopped — for an hour, for a day, forever — until a person opens one of two links. There is no
timeout that lets it through, no retry that slips past it, no schedule that resumes it.

```
                                    +-- approve --------> Approved - the human said yes
Reply with the draft ---> APPROVAL GATE ---> Did the human   |                        (TERMINAL)
+ approval links          (Wait: on          approve it?     +-- anything else ----> Held - the human
                           webhook call)                                               said no (TERMINAL)
```

The branch **fails closed**: the IF compares the decision to the literal string `approve`. A blank click,
a truncated link, a crawler hitting the URL, a typo — all of it lands on HOLD.

**Both branches are terminal.** Approve does not lead anywhere: it marks the row `approved_by_human`,
stamps who and when, and the workflow ends. Hold marks it `held_by_human` and the workflow ends. The
gate decides what the row says, and the row is the last thing that happens. Nothing downstream of a
human's click can reach a customer, because there is nothing downstream of it at all.

## ⚠️ The prices in this folder are made up

`rate-card-sample.csv` ships 23 line items with plausible-looking numbers. **They are illustrative demo
values, not market rates, not benchmarks, and not advice.** Every row's `notes` column says so, and the
`Load the rate card` node carries the same warning in its node note. Replace them with your own rates
before you quote anybody. Nothing in this repo knows what your labour costs.

The design point survives whatever numbers you put in: **the model never sees a price.** It is shown a
catalogue of `item_code | description | unit` and may only return codes and quantities. Every pound in the
draft is looked up in your Data Table by `Price it against the rate card`. A model that hallucinates a
price cannot put it on a quote; a model that hallucinates a _code_ gets it dropped and flagged in
`unmatched_note`, where the human sees it at the gate.

## Try it without a real job

```bash
curl -X POST https://YOUR-N8N/webhook/ep12-photo-to-quote \
  -H 'Content-Type: application/json' \
  -d @sample-site-photo.json
```

`sample-site-photo.json` is synthetic. Point `photo_url` at any publicly reachable **https** image —
a photo of your own roof is ideal; do not use a client's job.

```json
{
  "site_ref": "DEMO-SITE-01",
  "from_name": "Site (demo)",
  "from_email": "site@example.com",
  "photo_url": "https://YOUR-PHOTO-HOST/demo/roof-back-elevation.jpg",
  "note": "Back elevation. Four or five tiles come off in the wind, ridge looks loose at the far end, gutter full of moss the whole run. Two storeys so we'd need a tower."
}
```

The response hands back the draft plus the two gate links:

```json
{
  "ok": true,
  "quote_ref": "Q-20260929-001",
  "approval_status": "awaiting_human_approval",
  "line_count": 4,
  "currency_code": "GBP",
  "total_amount": 0,
  "flags": "none",
  "release_mode": "NOT SENT - no customer-facing send node exists on this canvas",
  "approve_url": "https://YOUR-N8N/webhook-waiting/<execution-id>?decision=approve",
  "hold_url": "https://YOUR-N8N/webhook-waiting/<execution-id>?decision=hold",
  "quote_summary": "DRAFT QUOTE Q-20260929-001 ..."
}
```

`line_count` and `total_amount` depend entirely on your rate card and what the model reads in your photo —
the values above are placeholders for the shape, not a result anyone measured.

## Flow, node by node

```
1  Site photo in                          Webhook, POST /webhook/ep12-photo-to-quote
                                          responseMode: responseNode
           |
2  Read the photo and the note            Code: normalises any INBOUND intake shape (web form,
                                          email-to-webhook parser, WhatsApp-to-webhook bridge)
                                          into one flat item; refuses a
                                          photo URL that is not https; mints quote_ref; carries
                                          trade_code / currency_code / tax_rate
           |
3  Load the rate card                     Data Table GET, returnAll, ep12_rate_card.
                                          YOUR prices. Sample values are illustrative.
           |
4  Build the vision request               Code: one chat-completions body — system prompt, the
                                          site note, the catalogue of item_codes, and the image.
                                          NO PRICE IS PUT IN THE PROMPT.
           |
5  Vision model reads the photo           HTTP Request, POST to any OpenAI-compatible vision
                                          endpoint. Header Auth. onError=continueRegularOutput
                                          on purpose: a dead model still produces a flagged draft.
           |
6  Price it against the rate card         Code: parses the model's JSON, matches item_code against
                                          the table, applies min_qty, clamps qty at 500, computes
                                          subtotal / tax / total from TABLE prices only, writes
                                          every reason-for-human-attention into unmatched_note,
                                          renders quote_summary. approval_status is hardcoded to
                                          awaiting_human_approval — there is no other value it emits.
           |
7  Queue the draft for approval           Data Table INSERT into ep12_quote_queue.
                                          This table IS the approval inbox.
           |
8  Reply with the draft + approval links  Respond to Webhook: the draft, the flags, and the two
                                          gate URLs built from $execution.resumeUrl. It sits HERE
                                          because resumeUrl must be read before the Wait node.
           |
9  APPROVAL GATE - wait for a human       Wait, resume: On Webhook Call.  <-- EXECUTION STOPS
           |
10 Did the human approve it?              IF: decision === 'approve', else HOLD. Fails closed.
        /        \
11 Approved -     12 Held -               Data Table UPDATE on quote_ref: approved_by_human /
   the human         the human            held_by_human, decided_at, decided_by.
   said yes          said no              BOTH ARE TERMINAL. The workflow ends here.
   (TERMINAL)        (TERMINAL)           Neither branch sends anything, to anyone.
```

Every photo gets a row, including the ones nothing could be priced from. `unmatched_note` is the column
that tells you why the human has to look.

## What you need

| #                    | Node                         | Credential                              | Notes                                                             |
| -------------------- | ---------------------------- | --------------------------------------- | ----------------------------------------------------------------- |
| 5                    | Vision model reads the photo | **Header Auth** — `REPLACE_ME`          | Any OpenAI-compatible vision endpoint. Shipped URL is OpenRouter. |
| 3, 7, 11, 12         | Data Table nodes             | none (Data Tables are not a credential) | Two tables, `dataTableId` is `REPLACE_ME` in all four.            |
| 1, 2, 4, 6, 8, 9, 10 | —                            | **none**                                | No SMTP, no CRM, no telephony. Deliberately.                      |

Header Auth credential: name `Authorization`, value `Bearer sk-...` for OpenRouter. Swap the URL in node 5
for `https://api.openai.com/v1/chat/completions`, a Groq endpoint, or your own gateway — the body is plain
OpenAI chat-completions with an `image_url` content part.

### Data Table 1 — `ep12_rate_card`

n8n → **Data tables → Create**, name it `ep12_rate_card`, then import `rate-card-sample.csv` (or type your
own rows). Columns:

| Column       | Type   | Holds                                                                         |
| ------------ | ------ | ----------------------------------------------------------------------------- |
| `item_code`  | string | the code the model is allowed to return, e.g. `RF-TILE-REPLACE`               |
| `item_label` | string | what it is called on the quote                                                |
| `unit_label` | string | `per tile`, `per metre`, `per m2`, `per day` — shown to the model, not parsed |
| `unit_price` | number | **your** price. Sample values are illustrative.                               |
| `min_qty`    | number | minimum billable quantity; a smaller estimate is raised to this               |
| `trade_code` | string | `roofing`, or `any` for access/waste/labour rows shared across trades         |
| `notes`      | string | free text; the sample rows use it to shout that the price is illustrative     |

### Data Table 2 — `ep12_quote_queue`

Create it empty. Columns:

| Column             | Type   | Holds                                                                    |
| ------------------ | ------ | ------------------------------------------------------------------------ | -------------------- |
| `quote_ref`        | string | `Q-YYYYMMDD-NNN`, minted in node 2 — the key the gate updates on         |
| `received_at`      | string | ISO timestamp the photo arrived                                          |
| `site_ref`         | string | your own job reference. Not the customer's address.                      |
| `requester_name`   | string | who sent the photo                                                       |
| `requester_email`  | string | reply-to, if the intake had one                                          |
| `photo_url`        | string | the photo that was read                                                  |
| `site_note`        | string | what came typed with it                                                  |
| `observed_summary` | string | the model's one-sentence read of the damage                              |
| `line_items_text`  | string | the priced lines as JSON                                                 |
| `line_count`       | number | how many lines were priced                                               |
| `currency_code`    | string | `GBP` as shipped                                                         |
| `subtotal_amount`  | number | sum of the line totals                                                   |
| `tax_amount`       | number | subtotal × `TAX_RATE`                                                    |
| `total_amount`     | number | what the customer would see                                              |
| `model_confidence` | number | the model's own 0–1 confidence. A number it made up; treat it as a hint. |
| `unmatched_note`   | string | every reason a human should look, joined with `                          | `; `none` when clean |
| `quote_summary`    | string | the rendered draft, ready to paste                                       |
| `approval_status`  | string | `awaiting_human_approval` → `approved_by_human` / `held_by_human`        |
| `release_mode`     | string | the constant that says nothing was sent                                  |
| `decided_at`       | string | when a human clicked                                                     |
| `decided_by`       | string | `?approver=` from the gate link, or `approval link`                      |

Then open nodes 3, 7, 11 and 12 and re-pick the tables: the shipped JSON carries `dataTableId: REPLACE_ME`
in all four, which is the only thing you must set after import.

## What to edit before you use it

- **`rate-card-sample.csv` → your real prices.** This is the whole job. Everything else works out of the box.
- Node 2, four constants: `TRADE_CODE` (`roofing`), `CURRENCY` (`GBP`), `TAX_RATE` (`0.20` — set `0` if you
  quote tax-exclusive), `MAX_NOTE_LEN`.
- Node 4, `MODEL` — shipped as `anthropic/claude-sonnet-4.5`. Any vision model your endpoint serves.
- Node 6, `QTY_CEILING` (500) — the point past which a quantity is clamped and flagged rather than billed.

## Using it for real

1. Run it a few dozen times and read the drafts **without approving any of them**. You are calibrating your
   rate card, not the model.
2. Put the gate links somewhere a human actually looks. The webhook response is fine for testing and
   useless in the van.
3. Protect the resume URL before it goes anywhere public: the Wait node has an **Authentication** option
   (Basic / Header / JWT). An unauthenticated resume URL is a one-click approve for anyone who gets it.
4. **Send the quote yourself.** Copy `quote_summary` out of the `approved_by_human` row and send it the way
   you already send quotes. This workflow will not do it for you and is not built to. If you later decide to
   automate that last step, you are adding a node that can contact customers to a lane that currently
   cannot — that is a different risk profile and a decision only you can make, with your name on the quote.

## GOTCHAS

- **A photo is not a survey, and a quote is a contract.** Everything in this lane is an estimate drawn from
  one image: it cannot see what is under the tiles, behind the render, or up the chimney. Send the approved
  draft as an _indicative_ price subject to inspection, or carry the "nothing_priced / needs_site_visit"
  flags through to your wording. In the UK a consumer quote given as fixed is binding; an estimate is not.
  That distinction is worth more than the automation.
- **The prices shipped here are invented.** Twenty-three plausible-looking numbers that came from nowhere.
  Using them unchanged would mean quoting someone a made-up price with your name on it.
- **The model never sees a price, and it must stay that way.** If you "helpfully" paste your rate card
  _with_ prices into the prompt, a model can and will nudge a figure to make a quote look sensible. Codes
  in, prices from the table, always.
- **`$execution.resumeUrl` is only populated before the Wait node runs.** Read it in a node that sits
  _upstream_ of the gate — node 8 here. Try to read it after, and you get an empty string and a quote
  nobody can approve.
- **A Wait node holds the execution open, and n8n prunes executions.** With `EXECUTIONS_DATA_MAX_AGE` set
  short, a draft nobody approved for a fortnight can be pruned mid-wait — the row stays in the table at
  `awaiting_human_approval` forever and nothing ever resumes it. Sweep the queue table for stale rows
  rather than trusting the execution list.
- **Unauthenticated resume URLs approve quotes.** Anyone holding the link is the approver. Turn on the Wait
  node's Authentication before the link leaves your own inbox, and never post the JSON response into a
  shared channel.
- **The IF compares strings, so it fails closed — keep it that way.** Do not "simplify" it to a boolean
  check on the query object. `?decision=Approve`, `?decision=yes`, a link-preview crawler firing a bare GET:
  all of them must hold, and they do only because the comparison is to the exact word `approve`.
- **The model's `confidence` is a number it made up.** It is stored because it is occasionally a useful
  smell, not because it measures anything. Do not gate an auto-send on it. Do not put it in front of a
  customer.
- **Vision models read EXIF-rotated phone photos exactly as stored.** A picture your phone shows upright can
  arrive on its side, and a sideways roof gets read as a wall. If your intake re-hosts the image, strip and
  apply the EXIF orientation first.
- **Big photos cost real money and real seconds.** A 12 MP phone photo is a lot of image tokens per quote.
  Downscale to ~1600 px on the long edge in your intake; nothing in a quote needs more.
- **`onError: continueRegularOutput` on node 5 is deliberate and it is load-bearing.** When the vision call
  dies, the draft still gets written with `vision_call_unreadable` in `unmatched_note` and zero lines — a
  visible empty quote a human rejects. The alternative is a photo that silently vanished, which is how a
  contractor loses a job and never finds out.
- **Data Table columns are typed.** `unit_price`, `min_qty`, `line_count` and the three amounts are number
  columns; a CSV row with `28.00 GBP` in `unit_price` fails the insert. The Code node coerces with
  `Number(...) || 0`, so a bad rate-card row silently prices at zero — check your import.
- **n8n's expression sandbox refuses some identifiers outright.** `{{ $json.caller }}` is rejected with
  _"Cannot access \"caller\" due to security concerns"_ (found the hard way in EP11). Nothing this workflow
  emits is named `caller`, `callee`, `arguments`, `constructor` or `prototype`. If you rename a field, keep
  clear of that list.

## Files

```
workflow.json           the importable workflow, 12 nodes, no send step, dataTableId REPLACE_ME x4
rate-card-sample.csv    23 seed rows for ep12_rate_card - ILLUSTRATIVE PRICES
sample-site-photo.json  the synthetic intake payload used in the curl above
README.md               this file
```
