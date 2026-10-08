# 21 - WhatsApp order capture: plain-text orders become sheet rows

**11 nodes** (including 3 sticky notes). Imported inactive.

A wholesaler takes orders over WhatsApp: "send me 20 of SKU-1001, it's Sam". This reads the message, pulls out the SKU, quantity and customer, checks stock in a Google Sheet, writes an order row if it is in stock and replies with a confirmation, or tells your sales rep if it is not.

## Flow

WhatsApp Trigger -> Extract order (Information Extractor + Groq model) -> Look up stock (Google Sheets) -> In stock? (If) -> Write order row -> WhatsApp confirm (disabled) / Tell the rep (Slack, disabled).

## Send safety

The WhatsApp confirmation and the Slack alert are **disabled**, so a customer never gets a message until you enable them. Orders are written to the sheet either way. Every send node is labelled SIMULATED in the canvas notes. All names, numbers and addresses in the file are placeholders (`+1 555 010 0000`, `owner@example.com`).

## Import in 4 steps

1. In n8n choose **Workflows -> Import from file** and pick `workflow.json`.
2. Create the credentials listed below and attach them (the file refers to them by name only).
3. Replace every `REPLACE_ME` (Google Sheet id, WhatsApp phone number id) and set up the sheet: Sheet tabs `stock` (`sku, stock`) and `orders` (`received_at, customer, sku, qty`).
4. Run it once by hand, check the result, then enable the send nodes and activate.

## Credentials

WhatsApp Business Cloud (trigger and send), Google Sheets OAuth2, Slack, OpenAI-compatible (Groq).

## Files

```
workflow.json   the importable workflow, active: false
README.md       this file
```

Short: (link TBD)
