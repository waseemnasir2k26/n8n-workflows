# 14 — Low stock becomes a reorder email, before you run out

`Shopify low stock to supplier reorder email (simulated send)` — **7 nodes** (+ 3 sticky notes).

**Short:** (link TBD)

A Shopify store owner finds out a bestseller is nearly gone when a customer emails to ask where it is. This workflow looks at the shelves for you at 07:00 every morning. Any variant under 20 units gets a purchase-order email written to your supplier, and you get a short heads-up with the product, SKU and what is left.

Seven nodes. The threshold is one number. The emails are plain text you can read in ten seconds.

## Send safety

Both Gmail nodes (`Email supplier PO (simulated)` and `Heads-up to owner (simulated)`) ship **disabled**. The workflow ships inactive. Until you enable them nothing is emailed to anyone. A `Limit` node caps each run at 50 variants, so a store with a broken stock feed cannot send a flood of emails. Supplier and owner addresses are `supplier@example.com` and `owner@example.com` placeholders.

## Flow

```
Schedule 07:00 -> Get Shopify products -> One row per variant (Code) -> Cap 50 per run (Limit) -> Under 20 units? (IF) -> Email supplier PO -> Heads-up to owner
```

## Import in 4 steps

1. Import `workflow.json` (n8n -> Workflows -> Import from file).
2. Add the credentials below and re-pick them on the Shopify and Gmail nodes.
3. Replace the two example addresses, and the 20 in `Under 20 units?` if your threshold differs.
4. Run once by hand, read the output, then enable the two Gmail nodes and activate.

## Credentials

Referenced by name only; create your own and re-pick them after import.

| Node | Credential |
| --- | --- |
| Get Shopify products | Shopify access token (Admin API, read products + inventory) |
| Gmail nodes | Gmail OAuth2 |

## Files

```
workflow.json   the importable workflow, inactive
README.md       this file
```
