# 19 - Review reply drafts: bad reviews get a calm draft, a human posts it

**10 nodes** (including 3 sticky notes). Imported inactive.

A restaurant or clinic owner dreads the 2-star review. This picks up the review notification email, reads the star rating, and for 1 to 3 stars writes a calm reply (no excuses, an invitation to talk offline) and drops it in Slack for approval. You paste it yourself. Nothing is ever posted for you.

## Flow

Gmail Trigger -> Cap 50 per run -> Parse stars (Code) -> Stars 3 or less? (If) -> Draft calm reply (Basic LLM Chain + Groq model) -> Post to #approvals (Slack, disabled).

## Send safety

There is **no node that posts a review reply anywhere**. The only output is a Slack message to your own channel, and it ships **disabled**. A person reads the draft, edits it and posts it by hand. Every send node is labelled SIMULATED in the canvas notes. All names, numbers and addresses in the file are placeholders (`+1 555 010 0000`, `owner@example.com`).

## Import in 4 steps

1. In n8n choose **Workflows -> Import from file** and pick `workflow.json`.
2. Create the credentials listed below and attach them (the file refers to them by name only).
3. Replace every `REPLACE_ME` (Google Sheet id, WhatsApp phone number id) and set up the sheet: Change the Gmail search (`from:noreply@example.com subject:review`) to match your review notification emails.
4. Run it once by hand, check the result, then enable the send nodes and activate.

## Credentials

Gmail OAuth2, Slack, OpenAI-compatible (Groq).

## Files

```
workflow.json   the importable workflow, active: false
README.md       this file
```

Short: (link TBD)
