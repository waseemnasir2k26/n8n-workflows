# Episode ledger — n8n Workflows series

One free, MIT-licensed n8n workflow per video. This table is the single source of truth
for what has shipped, what's scheduled, and where the upload-pack copy lives for each
episode. Daily-capable; targeting 100+ episodes.

| Ep  | Date       | Workflow                                                                                                                    | Repo folder                                                                        | YouTube                                              | Socials                                                              | QC (YouTube / socials) | Notes              |
| --- | ---------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------- | ---------------------- | ------------------ |
| 01  | 2026-09-16 | SF-01 Shorts Factory — topic in, captioned 9:16 Short out                                                                   | [`workflows/01-shorts-factory`](../workflows/01-shorts-factory/)                   | [youtu.be/5p7IYgR-c2E](https://youtu.be/5p7IYgR-c2E) | Scheduled 2026-09-17 09:30 — FB reel, IG reel, LinkedIn, TikTok      | 92 / 91                | [EP01.md](EP01.md) |
| 02  | 2026-09-17 | Speed-to-lead (simulated demo) — AI dispatcher texts back in seconds, qualifies, books a visit window                       | [`workflows/02-speed-to-lead`](../workflows/02-speed-to-lead/)                     | [youtu.be/-lEQYzTgI5o](https://youtu.be/-lEQYzTgI5o) | Scheduled 2026-09-18 09:30 — FB reel, IG reel, LinkedIn, TikTok      | 91 / 89                | [EP02.md](EP02.md) |
| 03  | 2026-09-18 | Maps lead harvest (Apify → Postgres) — Trade + city in, deduped lead table with a run_id out                                | [`workflows/03-maps-lead-harvest`](../workflows/03-maps-lead-harvest/)             | [youtu.be/FwBva2bm_d8](https://youtu.be/FwBva2bm_d8) | Scheduled 2026-09-19 09:30 — FB reel, IG reel, LinkedIn, TikTok      | 91 / 92                | [EP03.md](EP03.md) |
| 04  | 2026-09-18 | Freight quote email parser (Claude → table + draft reply) — 20 sample emails, 8-field extract, Postgres upsert, draft reply | [`workflows/04-freight-quote-parser`](../workflows/04-freight-quote-parser/)       | [youtu.be/vuOnqlIa_rw](https://youtu.be/vuOnqlIa_rw) | Scheduled 2026-09-23 09:30 — FB reel, IG reel, LinkedIn, TikTok      | 88 / 89                | [EP04.md](EP04.md) |
| 05  | 2026-09-23 | Clinic WhatsApp booking agent — Spanish-first patients, code-side medical handoff, Postgres memory                          | [`workflows/05-clinic-whatsapp-booking`](../workflows/05-clinic-whatsapp-booking/) | [youtu.be/hbWm05jjwYU](https://youtu.be/hbWm05jjwYU) | Scheduled 2026-09-24 09:30 — FB reel, IG reel, LinkedIn, TikTok      | 91 / 91                | [EP05.md](EP05.md) |
| 06  | 2026-09-24 | Meta ads circuit breaker — ad-set-level spend cap, pause-only write, DRY RUN                                                | [`workflows/06-meta-ads-breaker`](../workflows/06-meta-ads-breaker/)               | [youtu.be/jrVFBmUCsfo](https://youtu.be/jrVFBmUCsfo) | GHL CSV queued 2026-09-25 09:30 — FB reel, IG reel, LinkedIn, TikTok | 93 / 90                | [EP06.md](EP06.md) |

## How an episode ships

1. Build the workflow into `workflows/NN-<slug>/` with its own `workflow.json` + `README.md` (+ `schema.sql` when needed) and push it to the VPS n8n.
2. Record a real dark-canvas run and cut a 16:9 YouTube video plus a 9:16 socials reel in the locked SkynetLabs format, with a matching thumbnail.
3. Run both cuts through the QC gate (SHIP ≥85, 0 blockers) before anything ships.
4. Write the upload pack — title, description, tags, links, sources — and hand it to Waseem, who publishes by hand (YouTube first, then socials).
5. After publish, verify the links are live and add the row here plus a public-safe `episodes/EPNN.md` pack.
6. Update the root `README.md` workflow table's Video column with the live YouTube link.
