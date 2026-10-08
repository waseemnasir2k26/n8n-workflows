# 20 - Car service reminders: a text when it is time to come back

**9 nodes** (including 3 sticky notes). Imported inactive.

A garage owner has a job sheet and no time to chase customers. Every morning this finds customers whose last service was 6 or more months ago and who have not been reminded, texts them a booking link, and stamps the sheet so they are never texted twice.

## Flow

Every day 08:00 (Schedule) -> Read job sheet (Google Sheets) -> 6+ months and not reminded? (If) -> Cap 50 per run (Limit) -> SMS reminder (Twilio, disabled) -> Mark reminded (Google Sheets).

## Send safety

The SMS node is **disabled**. A Limit node caps every run at **50 customers**, and `reminded_at` prevents repeats. Check the SMS consent rules in your country before turning it on. Every send node is labelled SIMULATED in the canvas notes. All names, numbers and addresses in the file are placeholders (`+1 555 010 0000`, `owner@example.com`).

## Import in 4 steps

1. In n8n choose **Workflows -> Import from file** and pick `workflow.json`.
2. Create the credentials listed below and attach them (the file refers to them by name only).
3. Replace every `REPLACE_ME` (Google Sheet id, WhatsApp phone number id) and set up the sheet: Sheet tab `jobs` with columns `job_id, name, phone, last_service, reminded_at`. Use `YYYY-MM-DD` dates and placeholder numbers like `+1 555 010 0000` while testing.
4. Run it once by hand, check the result, then enable the send nodes and activate.

## Credentials

Google Sheets OAuth2, Twilio.

## Files

```
workflow.json   the importable workflow, active: false
README.md       this file
```

Short: (link TBD)
