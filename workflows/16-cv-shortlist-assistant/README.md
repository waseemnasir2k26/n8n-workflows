# 16 — CV shortlist assistant: scores and reasons, a human decides

`CV shortlist assistant, scores only, human decides` — **11 nodes** (+ 3 sticky notes).

**Short:** (link TBD)

A small recruiter or hiring manager gets forty CVs for one role and reads the first ten properly. This reads each PDF CV that lands in a Gmail label, asks an AI model to score it 0-100 against your job spec with three short reasons, and logs it to a sheet. At 17:00 a Slack message lists the top 5.

It is a sort order, not a verdict. The workflow has no reject step and sends nothing to any candidate.

## Send safety

**Shortlist assistant, human decides, no auto-reject.** There is no email node to candidates and no reject path. The model is told to judge only fit to the job spec and to ignore age, gender, name origin and nationality; read the scores with that limit in mind and check borderline CVs yourself. Digest reads max 50 rows (`Limit`). Slack is internal only. Ships inactive. Check your local rules on automated screening before you use it on real applicants.

## Flow

```
CV email arrives (Gmail Trigger) -> Read PDF text -> Build scoring prompt -> Score with LLM (Groq, OpenAI-compatible) -> Parse score -> Log to Candidates sheet
Daily 17:00 -> Read Candidates -> Cap 50 rows -> Top 5 digest text -> Slack top-5 digest
```

## Import in 4 steps

1. Import `workflow.json`.
2. Edit `JOB_SPEC` in `Build scoring prompt`, and make a sheet tab `Candidates` (`received_at`, `from`, `score`, `reason_1`..`reason_3`).
3. Connect the credentials below. The scoring call is an OpenAI-compatible chat endpoint, shipped pointing at Groq.
4. Label two test CVs `cv-inbox`, check the scores and the Slack digest, then activate.

## Credentials

Referenced by name only; create your own and re-pick them after import.

| Node | Credential |
| --- | --- |
| CV email arrives | Gmail OAuth2 |
| Score with LLM | Header Auth: name `Authorization`, value `Bearer YOUR_GROQ_KEY` |
| Sheets nodes | Google Sheets OAuth2 |
| Slack top-5 digest | Slack API |

## Files

```
workflow.json   the importable workflow, inactive
README.md       this file
```
