# SkynetLabs n8n Workflow Library

Free n8n workflows, one per video. Every automation I build on the
[SkynetLabs YouTube channel](https://www.youtube.com/@Skynetlabs2k25) is published here as
importable JSON. Nothing sold, nothing gated behind a course. MIT licence, use it in client work.

Want the new ones in your inbox? Sign up at **https://workflows.skynetjoe.com**
(your address goes into a self-hosted Postgres table and is used only to send workflow links;
reply "stop" to leave).

## Import a workflow into n8n in 4 steps

1. Open the workflow folder below and copy the raw contents of `workflow.json`.
2. In n8n, open a blank canvas and press `Ctrl/Cmd + V` (or Menu → Import from file).
3. Replace every credential marked `REPLACE_ME` with your own (Postgres, SMTP, etc.).
4. Run it once manually, then toggle Active.

Each folder has its own `README.md` with the nodes, the env/credential requirements, and any
SQL the workflow expects.

## Workflows

| #   | Workflow                                                         | What it does                                                                                                                      | Status        | Video | JSON                                                                |
| --- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------------- | ----- | ------------------------------------------------------------------- |
| 00  | [Workflow library signup](workflows/00-workflow-library-signup/) | Webhook → validate + honeypot → Postgres upsert → welcome email → JSON response. The capture lane behind workflows.skynetjoe.com. | live          | —     | [workflow.json](workflows/00-workflow-library-signup/workflow.json) |
| 01  | YouTube Shorts factory                                           | Script → voice → clips → render → upload                                                                                          | in production | —     | —                                                                   |

The same table is served as [`site/workflows.json`](site/workflows.json) and rendered on the
landing page.

## Repo layout

```
workflows/   one folder per workflow: workflow.json + README.md (+ schema.sql when needed)
site/        the landing page at workflows.skynetjoe.com (static, no build step)
```

## Need this built for your business?

- Hire: https://fiverr.com/agencies/skynetjoellc
- Book a free consultation: https://calendly.com/skynetlabs/schedule-a-free-consultation
- Email: waseem@skynetjoe.com
- Site: https://skynetjoe.com

Waseem Nasir · SkynetLabs
