# 17 — Gym members who went quiet get a win-back text

`Gym member win-back text, 14 days quiet (simulated send)` — **6 nodes** (+ 3 sticky notes).

**Short:** (link TBD)

A gym owner loses members slowly: they skip a week, then two, then stop paying. Every night at 20:00 this reads your check-in sheet, finds anyone who has not been in for more than 14 days, texts them a short come-back message, and posts in Slack so their coach can follow up in person.

Six nodes. The 14 is one number you can change.

## Send safety

The Twilio node (`Win-back SMS (simulated)`) ships **disabled**; the workflow ships inactive. With it disabled the Slack note still tells the coach who would have been texted, so you can run it for a week as a read-only report. A `Limit` node caps a night at 50 members. Business texts are consent-regulated (A2P 10DLC in the US, opt-in rules elsewhere): the shipped message includes an opt-out line, but check your member terms before enabling. The `From` number is the placeholder `+1 555 010 0000`.

## Flow

```
Nightly 20:00 -> Read check-ins -> Cap 50 per night -> Quiet more than 14 days? -> Win-back SMS -> Tell the coach (Slack)
```

## Import in 4 steps

1. Import `workflow.json`.
2. Make a sheet tab `Members` with `name`, `phone`, `last_checkin` (a date), `coach`, and pick it in `Read check-ins` (shipped as `REPLACE_ME_SHEET_ID`).
3. Connect the credentials below and set your Twilio `From` number.
4. Put only your own number in the sheet, run it, then enable the Twilio node and activate.

## Credentials

Referenced by name only; create your own and re-pick them after import.

| Node | Credential |
| --- | --- |
| Read check-ins | Google Sheets OAuth2 |
| Win-back SMS | Twilio API |
| Tell the coach | Slack API |

## Files

```
workflow.json   the importable workflow, inactive
README.md       this file
```
