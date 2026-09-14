# workflows/

One folder per workflow, numbered in publish order:

```
NN-slug/
  workflow.json   importable n8n workflow, credentials stripped to REPLACE_ME
  README.md       what it does, nodes, credentials/env needed, gotchas
  schema.sql      only when the workflow expects database tables
```

Conventions:

- Credentials are never committed. Every credential reference is `{"id": "REPLACE_ME", "name": "Your ..."}`.
- No API keys, tokens, or hostnames that belong to us inside `workflow.json`.
- Node `jsCode` is plain ASCII so it survives copy/paste and n8n export round-trips.
