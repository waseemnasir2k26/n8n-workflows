# 00 — Workflow library signup

The email-capture lane behind https://workflows.skynetjoe.com, released as free workflow #0.
A landing-page form POSTs JSON to an n8n webhook; the workflow validates, upserts the address
into Postgres, sends a welcome email to first-time subscribers, and answers the browser with JSON.

## Flow

```
Webhook (POST /webhook/workflow-signup, CORS allow-list)
  → Code: trim + lowercase email, regex check, honeypot field `website`, capture IP + user-agent
  → IF valid?
      no  → Respond 400 {"ok":false,"error":"invalid_email"}
      yes → Postgres: INSERT ... ON CONFLICT (email) DO UPDATE ... RETURNING id, (xmax = 0) AS is_new
              error → Respond 500 {"ok":false,"error":"server_error"}
            → IF is_new?
                no  → Respond 200 {"ok":true,"new":false}
                yes → Send Email (SMTP) welcome
                        error → Respond 500 {"ok":false,"error":"email_failed"}
                      → Respond 200 {"ok":true,"new":true}
```

## Request

```bash
curl -X POST https://YOUR-N8N/webhook/workflow-signup \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","source":"workflows-page","workflow_slug":null,"website":""}'
```

- `website` is the honeypot: humans never see the field, bots fill it, non-empty = rejected.
- A raw JSON body sent as `application/x-www-form-urlencoded` (curl `-d` with no header) is also
  accepted: the Code node detects the JSON-in-key shape and re-parses it.

## Setup

1. Run `schema.sql` against your Postgres (table `workflow_subscribers`, unique lowercase email).
2. Import `workflow.json`. Replace the two `REPLACE_ME` credentials: a Postgres credential and an SMTP credential.
3. In the Webhook node, set **Allowed Origins (CORS)** to the origin of the page that posts to it.
4. In the Send Email node, change `fromEmail`/`replyTo` to a mailbox your SMTP credential is allowed to send as, and edit the email copy.
5. Activate.

## Gotchas

- `(xmax = 0) AS is_new` is the cheap way to tell insert from update in a single upsert statement.
- The write node uses `onError: continueErrorOutput` (an explicit error branch), never
  `continueRegularOutput` — a write that fails must not report success.
- `queryReplacement` is an array expression (`={{ [a, b, c] }}`), not a comma-joined string: a
  null value or a comma inside a value would otherwise shift every parameter.
- The n8n Code sandbox has no `URL`/`URLSearchParams`; string ops only.
