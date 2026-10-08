# 15 — Chase missing client documents, Monday friendly and Thursday firmer

`Client document reminders, Monday and Thursday (simulated send)` — **12 nodes** (+ 3 sticky notes).

**Short:** (link TBD)

An accountant or bookkeeper loses hours every week asking clients for the same missing paperwork. On Monday at 09:00 this reads your client tracker sheet and sends a friendly reminder to everyone whose document is still missing. On Thursday it sends a firmer note to the ones still missing who were already reminded. Each send stamps `reminded_at` in the sheet.

Two schedules, one sheet, no memory needed beyond the sheet itself.

## Send safety

Both Gmail nodes (`Friendly reminder (simulated)`, `Firmer reminder (simulated)`) ship **disabled**; the workflow ships inactive. Each branch has a `Limit` node capping a run at 50 clients. The Thursday email only goes to clients who already have a `reminded_at` value, so nobody gets the firm version first. Test with your own address in the sheet.

## Flow

```
Monday 09:00 -> Read client tracker -> Cap 50 -> Document missing? -> Friendly reminder -> Write reminded_at
Thursday 09:00 -> Read client tracker again -> Cap 50 -> Still missing and already reminded? -> Firmer reminder -> Write reminded_at
```

## Import in 4 steps

1. Import `workflow.json`.
2. Make a sheet tab `Clients` with `client_name`, `client_email`, `document`, `doc_received` (yes/no), `reminded_at`, and pick it in all four Sheets nodes (shipped as `REPLACE_ME_SHEET_ID`).
3. Connect the credentials below.
4. Put your own address in one row, run both branches by hand, then enable the Gmail nodes and activate.

## Credentials

Referenced by name only; create your own and re-pick them after import.

| Node | Credential |
| --- | --- |
| Sheets nodes | Google Sheets OAuth2 |
| Gmail nodes | Gmail OAuth2 |

## Files

```
workflow.json   the importable workflow, inactive
README.md       this file
```
