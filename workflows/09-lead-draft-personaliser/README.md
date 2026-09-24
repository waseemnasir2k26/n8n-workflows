# EP09 -- Lead-draft personaliser (never sends)

Reads a batch of cold leads, dedupes them by host (not by row -- a chain with
four branches and one shared inbox is one lead, not four), checks a daily
model-call budget, drafts ONE short outreach message per unique lead with an
open-weights model over OpenRouter, runs the draft through a schema gate that
rejects anything over 120 words or carrying a URL that was not in the source
row, and writes the surviving drafts to Postgres with a stage
(`draft-ready` or `needs-review`). **There is no send node anywhere in this
workflow.** Every draft is read by a human before anything leaves -- see
GOTCHAS below for why that is a hard rule here, not a soft one.

Zero client data. The five test leads are SkynetLabs-owned domains
(`skynetjoe.com`, `waseemnasir.com`) or reserved/synthetic `.example` domains
(RFC 2606) -- never a real third party. Real hosts are masked to a stable hash
(`host_ref`) before anything reaches storage.

## Node-by-node

1. **Manual Test** -- manual trigger, the only way this workflow ever runs.
2. **Webhook: leads in** -- DISABLED swap point. A future inbound lane (a form,
   a harvest hook) would post leads here instead of using the sample file.
3. **Load caps** -- reads the `ep09_caps` Data Table row. Runs FIRST (ahead of
   the leads chain -- see GOTCHAS, DEVIATION 1) so every later node can read
   its VALUES via `$('Load caps')` with the guarantee that it has already run.
4. **Load leads (GitHub sample)** -- DISABLED. GET of
   `samples/leads-sample.json` from the raw GitHub URL. Only resolves once
   this repo folder is actually pushed to GitHub -- this build was never
   committed by the agent that built it (see Build notes), so this path is the
   documented swap point for after Waseem publishes the repo, not the
   default.
5. **Load leads (Postgres ep09_leads)** -- ENABLED default for this build.
   Reads the same 7 sample rows from the `ep09_leads` Postgres table (seeded
   by hand on the VPS from `samples/leads-sample.json` -- see Build notes).
6. **Mask + normalize** -- computes `host_ref` (a stable hash of the host)
   BEFORE anything is stored. The real host stays in-memory on the item as
   `raw_host` for the rest of THIS SAME execution only (dedupe + the schema
   gate's own-URL check); it never reaches Postgres.
7. **Dedupe by host** -- keeps the first occurrence per `raw_host` within the
   batch, drops the rest. This is the fix for the exact class of bug documented
   in memory `feedback-outreach-dedupe-by-host-not-place`: a lead harvested
   twice (a `www.` variant, a second Maps branch) is one company, not two
   drafts.
8. **Guard: cap** -- reads the caps row (by node reference, not via its own
   `$json`) and throws if `kill_enabled` is false, `breaker_tripped` is true,
   or the daily LLM budget is already spent; otherwise slices the batch to
   `max_drafts_per_run` and to whatever of `llm_calls_per_day` remains today.
   Throws, never silently truncates to zero.
9. **Build prompt** -- builds the per-lead prompt string. Asks for raw JSON
   (`{draft, confidence, reason}`), no hype, no superlatives, no price talk, no
   invented links, max 120 words.
10. **OpenRouter gpt-oss-20b** -- `@n8n/n8n-nodes-langchain.lmChatOpenAi`,
    model `openai/gpt-oss-20b` as a plain string (never a resourceLocator),
    credential id verified live at build time (see Build notes).
11. **Draft** -- `@n8n/n8n-nodes-langchain.chainLlm`, `retryOnFail` 3 x 20s.
    One LLM call per surviving lead.
12. **Schema gate** -- parses the model's JSON (with a plain-text fallback if
    the model does not comply), rejects a draft over 120 words, rejects a
    draft containing any URL that is not the lead's own `raw_host`, and sets
    `stage = confidence >= 0.7 ? 'draft-ready' : 'needs-review'`. Runs
    `onError: continueRegularOutput` (see Build notes, DEVIATION 3) so one bad
    draft does not abort the other good ones in the same run.
13. **Valid draft?** -- routes Schema gate's per-item error wrapper (a
    rejected draft) away from Write draft.
14. **Rejected (schema gate)** -- NoOp sink so a rejection is counted in Run
    summary, never silently dropped.
15. **Write draft** -- Postgres insert into `ep09_drafts`, one row per
    surviving draft, `idempotency_key = ep09:<host_ref>:<date>` with
    `ON CONFLICT DO NOTHING` so a same-day re-run never duplicates a draft for
    the same host.
16. **Tally drafts** -- collapses the per-item write stream to one item before
    the cap-counter update (see Build notes, DEVIATION 2).
17. **Bump caps** -- one Data Table update per run, `llm_calls_today` set to
    the pre-run value plus however many drafts this run actually wrote.
18. **Run summary** -- one item: leads in, after dedupe, dedupe dropped,
    drafts attempted, drafts rejected by the schema gate, drafts written, stage
    counts, LLM calls this run.
    19-20. Sticky notes: the cap sheet, and "there is no send node."

## CAP SHEET (`ep09_caps` Data Table, one row, `cap_id='ep09'`)

| Field                  | Value                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------------- |
| `max_drafts_per_run`   | 5                                                                                                 |
| `max_drafts_per_day`   | 50 (documented; see GOTCHAS -- not enforced by a day-total lookup in this single-manual-run demo) |
| `llm_calls_per_day`    | 50                                                                                                |
| `llm_calls_today`      | running counter, enforced BEFORE the model is called                                              |
| `kill_enabled`         | true (false disarms the whole run)                                                                |
| `breaker_tripped`      | false (self-demoted after repeated errors; never un-trips itself)                                 |
| `consecutive_errors`   | running counter toward `error_trip_threshold`                                                     |
| `error_trip_threshold` | 3                                                                                                 |
| `executionTimeout`     | 300s (workflow settings)                                                                          |

Both workflows are confirmed `active:false` after every write -- this repo's
copy uses `REPLACE_ME` credential/Data-Table ids throughout; see `ids.txt` for
the real ids on the SkynetLabs VPS.

## Proof run (canonical, execution 34613)

7 leads in (`samples/leads-sample.json` -- 5 distinct hosts, 2 duplicates by
host to prove dedupe, 1 edge row with no niche/city/signal) -> **5 unique
hosts after Dedupe by host** (2 dropped) -> 5 LLM calls -> **5 rows written to
`ep09_drafts`** (4 `draft-ready`, 1 `needs-review` -- the edge row with no
signal, correctly low-confidence) -> 0 rejected by the schema gate on this
run. **56.5 seconds wall clock for the 5 drafts.** `llm_calls_today` on
`ep09_caps` correctly reads 5 after the run. A masking grep over every
`draft` value in `ep09_drafts` for the 5 real/synthetic hostnames returns 0.

## REFUTE-FIRST -- proving the schema gate actually rejects

Ran the EXACT stored `Schema gate` jsCode (extracted from `workflow.json`)
against two adversarial cases in an isolated harness:

- A 130-word draft -> **threw**: `SCHEMA GATE: draft is 130 words, over the
120-word limit.`
- A draft containing `totally-unrelated-domain.com` (not the lead's host) ->
  **threw**: `SCHEMA GATE: draft contains a URL
(totally-unrelated-domain.com) not present in the lead row.`
- Control case (draft mentioning the lead's OWN host) -> passed through
  cleanly.

This was also observed LIVE, unprompted, on execution 34612: the model wrote
"acmeplumbing.com" for a lead whose real host was "acme-plumbing.example" (a
plausible-looking but foreign domain), and the gate rejected it. That
execution is exactly why DEVIATION 3 below exists -- the first version of this
gate aborted the whole batch over one bad item.

## Cap rehearsal (rehearsed and restored)

Set `llm_calls_per_day = 2` on the caps row, ran the 7-lead batch: result was
**exactly 2 drafts written, 0 errors** (`drafts_attempted: 2,
drafts_written: 2` in Run summary) -- Guard: cap sliced the batch to the
remaining budget and stopped cleanly, it did not throw. Caps restored to
`llm_calls_per_day: 50, llm_calls_today: 0` afterward.

## Breaker rehearsal (rehearsed and reset)

Pointed the OpenRouter model at a nonexistent id (`does-not-exist/bad-model-xyz`)
and fired the error workflow three times directly (an n8n manual/test
execution does not route through `settings.errorWorkflow` the way a
triggered production execution does -- see GOTCHAS -- so the rehearsal called
`error-workflow.json` itself three times to exercise the exact same
Log error -> Read caps -> Bump error counter -> Trip check -> Trip breaker
chain). `consecutive_errors` went 1 -> 2 -> 3 and `breaker_tripped` flipped to
`true` exactly at the third error, matching `error_trip_threshold: 3`. Reset
afterward (`consecutive_errors: 0, breaker_tripped: false`) and the model
string restored to `openai/gpt-oss-20b`.

## Provider check (2026-09-24)

Census flagged the OpenRouter lane's last confirmed success as 2026-09-16.
Live-tested it today via the actual `Draft` node in the actual workflow: the
credential (`p72XkT0du5Eq7Ywl`, "EP05 OpenRouter (OpenAI-compatible)") is
current, not stale, and `openai/gpt-oss-20b` returned usable drafts on every
successful run above. **Provider works today, 2026-09-24, confirmed by a real
call, not a health-check ping.**

## Sent/reply history lookup (for the copy team, read-only)

Live counts today [observed 2026-09-24, direct VPS read]:

- `ops_lead_draft`: 79 drafts total (66 `draft-ready`, 13 `needs-review`),
  matching the live lead-personaliser worker's own record.
- `send_queue` (email): 36 rows `status='sent'`, 3 `skipped`.
- `dm_queue`: 34 rows `status='sent'`, 84 `staged`, 246 `no_social`, 8
  `skipped`.
- `replies` table: 10 rows total, system-wide -- **not filtered to only the
  70 sent rows above**, so this is an upper bound on replies to this
  cohort, not a proven count. No column on `replies` links it 1:1 back to
  `send_queue`/`dm_queue` in a way a 10-percent-effort lookup could safely
  join.

So the defensible on-screen number is **70 sent (36 email + 34 DM), 0 to 10
replies depending how the 10 system-wide reply rows split**, not the
`66 SENT * 0 WON` figure the topic card carried in from an older, unverified
memory note (32 emails + 34 DMs). Use the measured 70/36/34 split, and say
"replies unverified against this specific cohort" rather than asserting 0.

## GOTCHAS

- **A disabled swap-point node still fires its downstream connection.** n8n
  does not merge two connections feeding the same input index -- it runs the
  downstream node ONCE PER incoming edge. Wiring both `Load leads (GitHub
sample)` (disabled, instant pass-through) and `Load leads (Postgres
ep09_leads)` (enabled, real DB round-trip) into `Mask + normalize` fired the
  Code node prematurely on the disabled branch's empty pass-through, before
  the Postgres branch's real rows arrived, aborting the run with "zero rows"
  [observed 2026-09-24, exec 34575]. **DEVIATION 1**: only the enabled
  loader's output feeds `Mask + normalize`; swapping loaders means
  re-pointing that one connection, not just flipping `disabled`. The same
  root cause is why `Load caps` now runs FIRST in the chain (ahead of the
  leads loaders) rather than being spliced between `Dedupe by host` and
  `Guard: cap` -- the latter wiring replaced the flowing lead items with the
  single caps row instead of merging them.
- **`@n8n/n8n-nodes-langchain.outputParserStructured` is not reliable against
  a 20B open-weights model.** It hard-threw "Model output doesn't fit
  required format" with no retry path [observed 2026-09-24, exec 34587].
  **DEVIATION 2**: dropped the separate parser node; the prompt itself
  demands raw JSON and `Schema gate` parses it leniently with a plain-text
  fallback, so a malformed reply degrades to `needs-review` (or a rejection)
  instead of aborting the node.
- **`chainLlm`'s own output (`{text:"..."}`) does not carry the input item's
  other fields through**, unlike a Code node's `Object.assign` passthrough.
  `host_ref`/`raw_host` must be pulled from the paired upstream item
  (`$('Build prompt').item.json`) by node reference and item-index pairing,
  not from the Draft node's own `$json` [observed 2026-09-24, exec 34588 --
  every `idempotency_key` came back `ep09:undefined:...` until this fix].
- **A per-item Data Table `update` computing `old + 1` from a static node
  reference does not accumulate across items in one run** -- five parallel
  writes each independently read the SAME pre-run `llm_calls_today` and wrote
  the SAME `+1` result, leaving the counter at 1 after 5 real calls
  [observed 2026-09-24, exec 34594]. **DEVIATION 3** (well, the third fix,
  numbered with the others above): `Tally drafts` collapses the write stream
  to one item first; `Bump caps` does exactly one update per run.
- **A manual/test execution (via the internal `/rest/workflows/{id}/run`
  endpoint, the only way to trigger a workflow without a webhook or schedule)
  does NOT route through `settings.errorWorkflow`** the way a triggered
  production execution does. The breaker rehearsal above calls
  `error-workflow.json` directly instead of relying on a manual Draft-node
  failure to trigger it -- disclosed, not worked around.
- `Guard: cap`'s `max_drafts_per_day` is documented in the cap sheet but not
  enforced by a live day-total query in this single-manual-run demo (same
  disclosed shape as EP06's `max_actions_per_run`) -- a production install
  would add a `count(*) where created_at::date = current_date` read, the same
  pattern EP06 uses for `actions_today`.
- Masking happens in `Mask + normalize`, the FIRST node to touch a lead row --
  never rely on a later node to mask something already written.
- No send-capable node type appears anywhere in this workflow or the error
  workflow. Full node type list: `n8n-nodes-base.manualTrigger`,
  `n8n-nodes-base.webhook` (inbound only, disabled), `n8n-nodes-base.httpRequest`
  (GET only, GitHub raw reads), `n8n-nodes-base.code`,
  `n8n-nodes-base.dataTable`, `n8n-nodes-base.postgres`, `n8n-nodes-base.if`,
  `n8n-nodes-base.noOp`, `n8n-nodes-base.stickyNote`,
  `@n8n/n8n-nodes-langchain.lmChatOpenAi`,
  `@n8n/n8n-nodes-langchain.chainLlm`.

## Why no send node

There is no send node ON PURPOSE. This estate's own outreach history shows
70 real sends (36 email, 34 DM) against a system-wide reply count that cannot
honestly be attributed higher than 10 -- see the sent/reply lookup above --
and autosend was explicitly ruled NO on 2026-09-21 (memory
`hq-followup-autosend-engine`). This workflow writes a draft and stops. A
human decides what, if anything, gets sent.

## Install it for your business

WhatsApp +92 300 1001957 - Waseem Nasir, SkynetLabs
Hire SkynetLabs, our Top Rated agency on Fiverr: https://www.fiverr.com/agencies/skynetjoellc
Repo: github.com/waseemnasir2k26/n8n-workflows

Paste 5 leads, get 5 drafts back. Every draft is a starting point a human
edits or discards -- never something that leaves on its own.

## Build notes (deviations from plan, logged per the build brief)

- The GitHub-sample loader path is disabled by default because this repo
  folder was never git-committed as part of this build (explicit instruction:
  never commit) -- the Postgres loader is the enabled default until the repo
  is actually pushed and the GitHub raw URL resolves.
- Three structural node-wiring fixes (DEVIATIONS 1-3 above) were made live,
  in order, after each one surfaced on a real execution -- none of them were
  anticipated in the original design; all three are now part of the shipped
  `workflow.json`, not just this note.
- The card's OpenRouter credential id (`p72XkT0du5Eq7Ywl`) was NOT stale --
  verified live via `GET /api/v1/credentials` and a real successful call.
- The card's `66 SENT / 0 WON` history figure does not match a direct VPS
  read today; see the sent/reply lookup section above for the corrected,
  measured numbers (70 sent, replies unverified against this cohort).
