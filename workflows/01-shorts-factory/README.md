# 01 — Shorts factory (SF-01)

`SF-01 Shorts Factory (script -> voice -> clips -> render -> upload)` — 28 nodes.

Give it a topic string. It writes a six-scene Short script, voices every scene, generates one vertical
image per scene, turns each image into a slow-zoom clip the exact length of its own voiceover, muxes
voice onto clip, concatenates the six clips, burns word-highlight captions, and emails you the finished
9:16 MP4 with a title, description and tags. A YouTube upload node is wired at the end and left
**disabled** — connect your own account and enable it if you want it to post.

The real run this workflow was built from produced a 41-second Short in about 9 minutes end to end,
roughly two of those minutes being deliberate waits (see GOTCHAS).

## Two entry points

| Trigger | How                                                                                                                                                                                                                                              |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Manual  | Open the workflow, press **Execute workflow**. The `Topic` node holds the topic string — edit it there.                                                                                                                                          |
| Webhook | `POST` to the `shorts-factory` webhook path with `{"topic": "..."}`. Responds immediately (`onReceived`) and runs in the background; the finished video arrives by email. Omit `topic` and it falls back to the default in `Topic from webhook`. |

```bash
curl -X POST https://YOUR-N8N/webhook/shorts-factory \
  -H 'Content-Type: application/json' \
  -d '{"topic":"Why small businesses lose leads after 5pm, and the auto-reply fix"}'
```

Both entry points converge on the same `Build Groq request` node.

## Flow, node by node

```
Run (manual)            Run via webhook (POST /webhook/shorts-factory)
   |                       |
Topic                   Topic from webhook          -- topic + system prompt
   \_______________________/
              |
      Build Groq request                Code: assemble the chat-completions body
              |
      Groq: write script                HTTP POST api.groq.com, json_object response format
              |
      Parse script                      Code: JSON -> one item per scene (6 items).
                                        ASCII-folds smart quotes/dashes, builds a run_id,
                                        builds the Pollinations image URL per scene.
              |
      ElevenLabs: voice                 HTTP POST, one MP3 per scene (batch size 1, 800ms apart)
              |
      Upload VO to MinIO                S3 node -> sf/<run_id>-<index>.mp3
              |
      NCA: VO duration                  POST /v1/media/metadata -> real seconds of each MP3
              |
      Scene plan                        Code: pair duration back to scene.
                                        clip length = VO seconds + 0.4s, rounded up to 0.1s.
              |
      Loop over scenes  ----(done)----> Images ready ---> (render chain below)
              |  (each item)
           Breathe                      Wait 20 seconds  <-- the Pollinations throttle
              |
      Pollinations: image               HTTP GET, responseFormat file, 180s timeout,
                                        onError: continueRegularOutput, alwaysOutputData
              |
         Got image?                     IF $binary.data exists
            |     \__(no)__> Breathe    retry lane: wait another 20s and ask again
         (yes)
      Upload image to MinIO             S3 node -> sf/<run_id>-<index>.jpg
              |
      back to Loop over scenes

      Images ready                      Code: re-emit all six scenes (hosted URLs are deterministic)
              |
      NCA: image to clip                POST /v1/image/convert/video, frame_rate 30, zoom_speed 3,
                                        length = that scene's clip length
              |
      Mux body                          Code (runOnceForEachItem): build the ffmpeg compose body —
                                        crop the watermark, scale/crop to 1080x1920, apad the audio,
                                        hard -t clip length
              |
      NCA: mux voice                    POST /v1/ffmpeg/compose  -> one finished scene clip
              |
      Collect clips                     Code: ordered list of the six clip URLs + carry title/desc/tags
              |
      NCA: concatenate                  POST /v1/video/concatenate -> one silent-cut Short
              |
      Caption body                      Code: caption settings (highlight style, middle-centre,
                                        white text, yellow active word, black outline, 4 words/line, caps)
              |
      NCA: captions                     POST /v1/video/caption (Whisper on the server).
                                        onError: continueRegularOutput — a caption failure must not
                                        destroy the render.
              |
      Final                             Code: pick the captioned URL, fall back to the uncaptioned one
              |
      Email me the Short                SMTP: both URLs, title, description, tags, 14-day expiry note
              |
      Download final                    HTTP GET the MP4 as binary
              |
      YouTube: upload                   DISABLED. Connect your own OAuth credential and enable.
                                        Defaults to privacyStatus "unlisted", category 28.
```

## Credentials — five, all shipped as `REPLACE_ME`

Every credential in `workflow.json` is `{"id": "REPLACE_ME", "name": "Your ..."}`. Create these five in
**n8n → Credentials → New**, then re-select them on the matching nodes after import.

| #   | Node(s)                                                                                         | Credential type                                      | How to create it                                                                                                                                                                                                                                                       |
| --- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `Groq: write script`                                                                            | **Header Auth**                                      | Get a key at console.groq.com. Name `Authorization`, Value `Bearer <your Groq key>`. Free tier is enough for one video at a time.                                                                                                                                              |
| 2   | `ElevenLabs: voice`                                                                             | **Header Auth**                                      | Get a key at elevenlabs.io → Profile → API key. Name `xi-api-key`, Value the raw key (no `Bearer`).                                                                                                                                                                    |
| 3   | `NCA: VO duration`, `NCA: image to clip`, `NCA: mux voice`, `NCA: concatenate`, `NCA: captions` | **Header Auth** (one credential, reused on all five) | Whatever you set as `API_KEY` when you deployed the NCA Toolkit. Name `x-api-key`, Value that key.                                                                                                                                                                     |
| 4   | `Upload VO to MinIO`, `Upload image to MinIO`                                                   | **S3**                                               | Any S3-compatible bucket. For MinIO: endpoint `https://YOUR-BUCKET-HOST`, force path style **on**, access key + secret from MinIO. The workflow writes into bucket `nca` under the prefix `sf/` — change `bucketName` on both nodes if yours is called something else. |
| 5   | `Email me the Short`                                                                            | **SMTP**                                             | Any SMTP host. Then edit `fromEmail` (`n8n <you@example.com>`) to an address your SMTP is allowed to send as, and `toEmail` to wherever you want the video.                                                                                                            |

The disabled YouTube node needs a sixth (Google OAuth2) only if you enable it.

## What you must self-host

This workflow does no rendering itself. Everything video-shaped is an HTTP call to the
**No-Code Architects Toolkit** — an open-source media API you deploy yourself:
<https://github.com/stephengpope/no-code-architects-toolkit>.

You also need an **S3-compatible bucket** it can read from and write to (MinIO, Backblaze B2, Wasabi, AWS
S3 — anything that speaks S3). The toolkit needs the bucket; the workflow needs the bucket; they must be
the same bucket, and the objects must be readable over HTTP at a predictable URL, because the workflow
builds those URLs itself from `run_id` and scene index.

Then replace the placeholder host. Every NCA URL in `workflow.json` reads
`https://YOUR-NCA-HOST/...` — find and replace it with your own deployment, in all seven places:

- `https://YOUR-NCA-HOST/v1/media/metadata`
- `https://YOUR-NCA-HOST/v1/image/convert/video`
- `https://YOUR-NCA-HOST/v1/ffmpeg/compose`
- `https://YOUR-NCA-HOST/v1/video/concatenate`
- `https://YOUR-NCA-HOST/v1/video/caption`
- and the two object-URL bases inside the `Scene plan` code node
  (`https://YOUR-NCA-HOST/nca/sf/...`) — point these at however your bucket serves public objects.

Sizing, learned the hard way: give the toolkit container **at least 3GB of memory**. Captioning runs
Whisper on CPU and is killed at 2GB.

## Cost

Groq free tier, ElevenLabs character quota (~100 spoken words a video), Pollinations anonymous tier (free),
and your own box for rendering and storage. The marginal cost of an extra video is the TTS characters and
nothing else.

**The image quality ceiling is the free tier's.** The pictures are serviceable, not beautiful, and they carry
a watermark this workflow crops off. Swapping in a paid image API (or a stock-video provider) is a one-node
change: replace `Pollinations: image` with an HTTP call to whatever you pay for, keep the rest of the chain,
and you can delete the `Breathe` wait with it.

## GOTCHAS

Each of these cost a failed run during the build. They are the reason the workflow is shaped the way it is.

- **Pollinations' anonymous tier allows exactly one queued request per IP.** Parallel calls, or serial calls
  sent too quickly, come back `HTTP 429 — Queue full for IP`. That is why images are produced by an explicit
  `Loop over scenes` (batch size 1) → `Wait 20s` → request → `IF got image?` retry lane, instead of
  node-level batching. Six images therefore take about two minutes of pure waiting. That is the price of the
  free tier, not a bug.
- **n8n caps `waitBetweenTries` at 5000ms.** A node's own retry setting cannot express a 20-second backoff, so
  the backoff has to be a real `Wait` node inside a loop. The `Pollinations: image` node keeps its 3 tries at
  5s as a first line of defence, with `onError: continueRegularOutput` + `alwaysOutputData` so a hard failure
  falls through to the IF node instead of killing the execution.
- **A Code node in `runOnceForEachItem` mode must `return { json: {...} }`** — a bare object, _not_
  `return [{ json: {...} }]`. The array form is only valid in `runOnceForAllItems`. `Mux body` is the one node
  here in per-item mode; every other Code node is per-run and returns an array.
- **ffmpeg `-shortest` does not truncate when `apad` is in the filter chain.** `apad` pads audio forever, so
  "shortest" never arrives: six ~5-second clips produced a **2217-second** container. Fixed by passing an
  explicit `-t <clip length>` computed from the measured VO duration. If your clips come out absurdly long,
  this is why.
- **The anonymous Pollinations image carries a bottom-right watermark.** It is removed before scaling with
  `crop=in_w:in_h-72:0:0`, then the frame is scaled and cropped to 1080x1920. Change the image source and you
  should delete that crop, or you will be cutting 72 pixels off a clean image.
- **`/v1/video/caption` runs Whisper on CPU and was OOM-killed at a 2GB container memory limit** — SIGKILL on
  the server, `HTTP 502` at the n8n node. 3GB works. The node is set to `continueRegularOutput` so a caption
  failure still delivers the uncaptioned render rather than losing the whole run.
- **`/v1/video/thumbnail` streams with a small probesize and fails on non-faststart MP4s.** No thumbnail node
  is included here for that reason. If you add one, re-mux the final file with `-movflags +faststart` first.

## Files

```
workflow.json   the importable workflow, 28 nodes, credentials stripped to REPLACE_ME
README.md       this file
```
