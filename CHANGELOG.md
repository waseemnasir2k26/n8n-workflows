# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026.09] - 2026-09-16

- Maintenance review of n8n-workflows — the public SkynetLabs n8n workflow library, one importable `workflow.json` per YouTube video.
- Status: two workflows published (00 workflow-library-signup, 01 shorts factory SF-01), each with its own README and, where needed, `schema.sql`; a static landing page in `site/` backs https://workflows.skynetjoe.com and is driven by `site/workflows.json`.
- Stack: raw n8n workflow JSON plus a no-build static HTML/JSON site; MIT licensed, no package manifest and no build step.
- Reviewed September 2026: docs refreshed, versioned as v2026.09. No workflow JSON, credentials or site code were changed.
- Known gaps: no CHANGELOG existed before this release (now created); the workflow table lists no video links yet (both rows show "—"); only 2 of the promised one-per-video workflows are in the repo so far.
