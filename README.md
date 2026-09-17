# SkynetLabs n8n Workflow Library

Free n8n workflows, one per video. Every automation I build on the
[SkynetLabs YouTube channel](https://www.youtube.com/@Skynetlabs2k25) is published here as
importable JSON. Nothing sold, nothing gated behind a course. MIT licence, use it in client work.

Want the new ones in your inbox? Sign up at **https://workflows.skynetjoe.com**
(your address goes into a self-hosted Postgres table and is used only to send workflow links;
reply "stop" to leave).

## Status

Last reviewed: September 2026 · release v2026.09

## Import a workflow into n8n in 4 steps

1. Open the workflow folder below and copy the raw contents of `workflow.json`.
2. In n8n, open a blank canvas and press `Ctrl/Cmd + V` (or Menu → Import from file).
3. Replace every credential marked `REPLACE_ME` with your own (Postgres, SMTP, etc.).
4. Run it once manually, then toggle Active.

Each folder has its own `README.md` with the nodes, the env/credential requirements, and any
SQL the workflow expects.

## Workflows

| #   | Workflow                                                         | What it does                                                                                                                                                                                                                                                                              | Credentials you need                                                                                                                                                                                              | Status | Video   | JSON                                                                |
| --- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------- | ------------------------------------------------------------------- |
| 00  | [Workflow library signup](workflows/00-workflow-library-signup/) | Webhook &rarr; validate + honeypot &rarr; Postgres upsert &rarr; welcome email &rarr; JSON response. The capture lane behind workflows.skynetjoe.com.                                                                                                                                     | Postgres, SMTP                                                                                                                                                                                                    | live   | &mdash; | [workflow.json](workflows/00-workflow-library-signup/workflow.json) |
| 01  | [Shorts factory (SF-01)](workflows/01-shorts-factory/)           | Topic in &rarr; six-scene script, voiceover, one image per scene, slow-zoom clips, concat, burned-in captions &rarr; a finished 9:16 MP4 in your inbox. 28 nodes.                                                                                                                         | Header Auth &times;3 (Groq, ElevenLabs, your NCA Toolkit), an S3/MinIO credential, SMTP. Needs a self-hosted [NCA Toolkit](https://github.com/stephengpope/no-code-architects-toolkit) + an S3-compatible bucket. | live   | &mdash; | [workflow.json](workflows/01-shorts-factory/workflow.json)          |
| 02  | [Speed-to-lead (simulated demo)](workflows/02-speed-to-lead/)    | Three public webhook lanes simulating a home-services speed-to-lead flow: a web lead in triggers an AI dispatcher's first text within seconds, a homeowner reply gets qualified and booked into a visit window, and a state endpoint lets a page poll the running conversation. 17 nodes. | Postgres, Header Auth (Anthropic).                                                                                                                                                                                | live   | &mdash; | [workflow.json](workflows/02-speed-to-lead/workflow.json)           |

Every URL in a published workflow that points at a host is a placeholder &mdash; `YOUR-N8N`,
`YOUR-NCA-HOST` &mdash; and every credential is `REPLACE_ME`. Nothing here talks to our servers.

The same table is served as [`site/workflows.json`](site/workflows.json) and rendered on the
landing page.

## Repo layout

```
workflows/   one folder per workflow: workflow.json + README.md (+ schema.sql when needed)
site/        the landing page at workflows.skynetjoe.com (static, no build step)
```

## Free access

- **The workflows** &mdash; this repo, MIT licence, no signup to download.
- **New ones by email** &mdash; https://workflows.skynetjoe.com
- **The videos** &mdash; https://www.youtube.com/@Skynetlabs2k25 (one workflow per video, the JSON lands here the same day)

## Need this built for your business?

- Hire: https://fiverr.com/agencies/skynetjoellc
- Book a free consultation: https://calendly.com/skynetlabs/schedule-a-free-consultation
- Email: waseem@skynetjoe.com
- Site: https://skynetjoe.com

Waseem Nasir · SkynetLabs
