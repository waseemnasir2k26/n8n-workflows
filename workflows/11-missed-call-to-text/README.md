# 11 — Missed call becomes a text back, already written

`EP11 Missed call -> text back, already written (simulated send, 4 nodes)` — **4 nodes**.

A contractor is up a ladder. The phone rings out. Within about a minute the caller gets a text — _"sorry
we missed your call, want me to book you in?"_ — and the call is written into a table as a job that still
needs a callback, so it cannot be forgotten by the time the van gets back.

Four nodes. Ten minutes to build. There is deliberately nothing clever in here: no AI, no CRM, no
scheduler. The whole value is that the caller hears from you before they dial the next name on the list.

## Send safety — simulated, by design

**The send step is a simulated send.** `Log job + simulated SMS` writes the fully composed message into a
Data Table row (`sms_to`, `sms_body`, `send_mode`) and that is the end of the lane. There is **no telephony
node on this canvas**, so nothing can reach a real person by accident — not during a recording, not on a
mis-fired test, not if you POST somebody's real number into it. Turning it into a real send is one node
you add yourself, described under _Going live with a real provider_.

## No phone account needed to demo

The trigger is a plain **Webhook** that accepts a missed-call event, which is the shape every phone system
already posts — Twilio status callbacks, CallRail webhooks, Aircall, 3CX, a PBX with an HTTP hook. That
means the demo here **posts a synthetic event with curl rather than dialling a real phone.** Nothing in
this folder needs a verified number, an A2P registration or a provider account.

```bash
curl -X POST https://YOUR-N8N/webhook/ep11-missed-call \
  -H 'Content-Type: application/json' \
  -d @sample-missed-call.json
```

Payload (`sample-missed-call.json`, synthetic — the numbers are reserved test ranges):

```json
{
  "event": "call.missed",
  "call_id": "demo-0001",
  "from": "+61 491 570 156",
  "to": "+61 491 570 157",
  "ring_seconds": 22,
  "received_at": "2026-09-28T09:14:03Z"
}
```

Response:

```json
{
  "ok": true,
  "call_id": "demo-0001",
  "action": "text_composed_simulated_send",
  "job_status": "needs_callback",
  "sms_to": "+61491570156",
  "sms_body": "Sorry we missed your call - Ridgeline Roofing (demo) here, we're on site. Want me to book you in? Reply YES or pick a slot: https://example.com/book",
  "send_mode": "SIMULATED - logged to ep11_missed_calls, nothing dialled"
}
```

## Flow, node by node

```
Missed call in                 Webhook, POST /webhook/ep11-missed-call
                               responseMode: responseNode
        |
Compose the callback text      Code (runOnceForAllItems):
                               - normalises ANY provider payload to one flat shape
                                 (call_status | CallStatus | status | event,
                                  from | From | customer_phone_number,
                                  answered:false -> no-answer)
                               - 'call.missed' -> 'missed', 'no_answer' -> 'no-answer'
                               - only no-answer/busy/failed/missed/voicemail/canceled count
                                 as missed; an answered call is logged and ignored
                               - E.164 sanity on the caller; a withheld number is never texted
                               - working hours (07:00-19:00, TZ_OFFSET) picks one of two wordings
                               - decides action: text_composed_simulated_send |
                                 ignored_not_a_missed_call | ignored_unusable_number
        |
Log job + simulated SMS        Data Table INSERT into ep11_missed_calls.
                               THE SEND STEP, simulated: the composed text is stored,
                               never transmitted. job_status = needs_callback.
        |
Reply to the phone system      Respond to Webhook, JSON: echoes action + the composed text
                               so the curl output shows exactly what would have gone out.
```

Every call event gets a row, including the ones it decides not to text. The table is the job log; the
`action` column is why it did or didn't text.

## Credentials — none

| #   | Node     | Credential | Notes                                                        |
| --- | -------- | ---------- | ------------------------------------------------------------ |
| —   | all four | **none**   | No API key, no provider account, no SMTP. That is the point. |

You do need **one n8n Data Table**. It is not a credential and not SQL — create it in
**n8n → Data tables → Create**, name it `ep11_missed_calls`, and add these columns:

| Column         | Type   | Holds                                                                                    |
| -------------- | ------ | ---------------------------------------------------------------------------------------- |
| `received_at`  | string | ISO timestamp the event arrived                                                          |
| `call_id`      | string | the provider's call id                                                                   |
| `caller`       | string | digits-only caller number                                                                |
| `called`       | string | which of your numbers was dialled                                                        |
| `call_status`  | string | normalised status (`missed`, `no-answer`, `completed`…)                                  |
| `ring_seconds` | number | how long it rang                                                                         |
| `action`       | string | `text_composed_simulated_send` / `ignored_not_a_missed_call` / `ignored_unusable_number` |
| `sms_to`       | string | destination of the simulated text (empty when not texting)                               |
| `sms_body`     | string | the composed message                                                                     |
| `send_mode`    | string | the constant `SIMULATED - …` so no row is ever mistaken for a real send                  |
| `job_status`   | string | `needs_callback` or `no_action`                                                          |

Then open `Log job + simulated SMS` and re-pick the table: the shipped JSON carries
`dataTableId: REPLACE_ME`, which is the one field you must set after import.

No `schema.sql` in this folder — an n8n Data Table is created in the UI, not with SQL. If you'd rather
keep the log in Postgres, swap that node for a Postgres _insert_ into a table with the eleven columns
above and the workflow is otherwise unchanged.

## What to edit before you use it

Three constants at the top of `Compose the callback text`:

- `BUSINESS` — your trading name. Shipped as the fictional `Ridgeline Roofing (demo)`.
- `BOOK_LINK` — your booking page. Shipped as `https://example.com/book`.
- `TZ_OFFSET` / `OPEN_HOUR` / `CLOSE_HOUR` — your hours, so the after-hours wording is honest.

## Going live with a real provider

The webhook already speaks the right dialect; the mapping is the easy half.

| Provider      | Point at                                                    | Missed shows up as                                                        |
| ------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------- |
| Twilio        | Voice number → _Call status changes_ webhook → your n8n URL | `CallStatus=no-answer\|busy\|failed`, `From`, `To`, `CallSid`             |
| CallRail      | Integrations → Webhooks → _post_call_                       | `answered: false`, `customer_phone_number`, `tracking_phone_number`, `id` |
| Aircall       | Webhooks → `call.ended`                                     | `event`, `call.status`, flatten one level first                           |
| 3CX / FreePBX | CDR or dialplan HTTP hook                                   | whatever you post — add your field names to the `g(...)` lists            |

Then add the real send **as a fifth node** after `Log job + simulated SMS` (Twilio node, or an HTTP POST
to your SMS provider) using `{{ $json.sms_to }}` and `{{ $json.sms_body }}`. Keep the log row in front of
it: a text that was logged but not sent is recoverable, a text that was sent but not logged is not.
Before you flip it on, read the GOTCHAS — the first three are legal, not technical.

## GOTCHAS

- **Business-initiated SMS is consent-regulated, and this is the bit that gets people fined, not
  throttled.** US/Canada: A2P 10DLC brand + campaign registration, or your messages are filtered or
  blocked outright; unregistered traffic on a long code is dead on arrival. UK/EU/AU: an unsolicited
  marketing text needs consent — a "sorry we missed you" reply to _their_ inbound call is normally a
  legitimate service reply, "and by the way we're 10% off this week" is marketing and is not. Keep the
  message a callback, not an ad.
- **Every SMS must be replyable by a human, and this workflow does not read replies.** If your text
  says "reply YES" then somebody has to see YES. Either point the number at a real inbox/phone, or word
  the message around the booking link only. A one-way number that invites a reply is worse than no text.
- **Never let the destination number come from anywhere but the caller field of the event.** A missed-call
  lane with a number in the _body_ of an incoming payload is a free SMS relay for anyone who finds the
  webhook URL. This one derives `sms_to` from `caller` and refuses anything that isn't 7–15 digits.
- **Providers retry webhooks, and a phone system often posts several events per call** (`initiated`,
  `ringing`, `no-answer`, plus a voicemail event). You will get duplicate rows and, once you go live,
  duplicate texts. This build stays at four nodes and accepts the duplicate rows. Before the real send
  goes on, add one _Data Table → If Row Does Not Exist_ on `call_id`, or send only on a single chosen
  status, or you will text one caller three times.
- **`event: "call.missed"` is not the same string as `no-answer`.** The normaliser takes the segment after
  the last dot and turns `_` into `-` precisely because of this — it was the first thing to fail in
  testing. If your provider uses some other vocabulary, add it to `MISSED` rather than editing the
  branch logic.
- **A withheld / blocked caller ID cannot be texted.** The status arrives as missed and the number as
  `withheld`, `anonymous` or empty. Those rows land as `ignored_unusable_number` — still logged as a job,
  because a withheld number that rang for 22 seconds is still someone who wanted you.
- **The response is `responseNode`, so the caller waits for the write.** That is fine at four nodes and
  ~50 ms. If you bolt on a real SMS call, switch the Webhook to _Immediately_ (`onReceived`) first —
  otherwise the provider's webhook timeout (Twilio gives you 15 s) starts racing your SMS API.
- **Fast is the goal; the workflow itself costs milliseconds.** The delay in real life is the phone
  system's — some providers only fire the post-call webhook after voicemail finishes recording. Test with
  a stopwatch on your own number before you tell a client "one minute".
- **Data Table columns are typed.** `ring_seconds` is a number column; posting `"ring_seconds": "twenty"`
  makes the insert fail, which is why the Code node coerces with `Number(...) || 0`.

## Files

```
workflow.json             the importable workflow, 4 nodes, dataTableId REPLACE_ME
sample-missed-call.json   the synthetic payload used in the curl above
README.md                 this file
```
