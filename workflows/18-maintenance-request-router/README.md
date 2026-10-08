# 18 - Maintenance request router: emergencies get a text, the rest get logged

**13 nodes** (including 3 sticky notes). Imported inactive.

A property manager gets maintenance messages all day: a dripping tap, then a burst pipe. This reads each message, decides whether it is an emergency (flood, gas smell, no heat) or routine, texts the on-call person for emergencies only, logs every request in a Google Sheet, and drafts a short acknowledgement to the tenant.

## Flow

Gmail Trigger (on) or WhatsApp Trigger (off, enable one of the two) -> Normalise message -> Emergency or routine? (Text Classifier + Groq model) -> Tag emergency -> SMS on-call (Twilio, disabled) / Tag routine -> Log request (Google Sheets) -> Reply to tenant (Gmail, disabled).

## Send safety

The Twilio SMS and the Gmail reply are **disabled**. Both say SIMULATED in the sticky notes. With them off, the workflow only classifies and logs. Enable them after you have connected credentials and tested with one email. Every send node is labelled SIMULATED in the canvas notes. All names, numbers and addresses in the file are placeholders (`+1 555 010 0000`, `owner@example.com`).

## Import in 4 steps

1. In n8n choose **Workflows -> Import from file** and pick `workflow.json`.
2. Create the credentials listed below and attach them (the file refers to them by name only).
3. Replace every `REPLACE_ME` (Google Sheet id, WhatsApp phone number id) and set up the sheet: Sheet tab `requests` with columns `received_at, from, text, urgency`.
4. Run it once by hand, check the result, then enable the send nodes and activate.

## Credentials

Gmail OAuth2, Google Sheets OAuth2, Twilio, WhatsApp (trigger, optional), OpenAI-compatible (Groq).

## Files

```
workflow.json   the importable workflow, active: false
README.md       this file
```

Short: (link TBD)
