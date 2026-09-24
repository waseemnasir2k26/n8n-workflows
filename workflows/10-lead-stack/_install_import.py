#!/usr/bin/env python3
"""Helper for install.sh — rewrites credential/dataTable placeholders in each
brick's workflow.json, POSTs it to the throwaway instance as active:false,
force-deactivates it, and records the created id in installed.json.

Never touches anything but the instance named by --base-url. Called only
from install.sh, which has already run the production-host refusal check.
"""
import argparse
import json
import sys
import urllib.request

BRICKS = [
    "03-maps-lead-harvest",
    "02-speed-to-lead",
    "09-lead-draft-personaliser",
    "07-inbox-router-drafts-only",
    "08-silent-lane-watchdog",
]

# credential name substring -> (arg id key, arg name key)
CRED_NAME_MAP = [
    ("Apify", "cred_apify"),
    ("OpenRouter", None),  # disambiguated by node credential TYPE below
    ("n8n API", "cred_n8n_self"),
    ("IMAP", "cred_imap"),
    ("Gmail", None),        # swap-point only, left REPLACE_ME on purpose
    ("Postgres", "cred_postgres"),
]

DT_NAME_MAP = {
    "ep07_caps": "dt_ep07_caps",
    "ep08_lanes": "dt_ep08_lanes",
    "ep08_caps": "dt_ep08_caps",
    "ep09_caps": "dt_ep09_caps",
}


def req(method, url, api_key, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "X-N8N-API-KEY": api_key, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def rewrite_credentials(node, args):
    creds = node.get("credentials")
    if not creds:
        return
    for cred_type, cred_obj in list(creds.items()):
        old_name = cred_obj.get("name", "")
        new_id = None
        new_name = None
        if cred_type == "postgres":
            new_id, new_name = args.cred_postgres, args.cred_postgres_name
        elif cred_type == "httpQueryAuth" and "Apify" in old_name:
            new_id, new_name = args.cred_apify, args.cred_apify_name
        elif cred_type == "httpHeaderAuth" and "OpenRouter" in old_name:
            new_id, new_name = args.cred_openrouter_header, args.cred_openrouter_header_name
        elif cred_type == "httpHeaderAuth" and "n8n API" in old_name:
            new_id, new_name = args.cred_n8n_self, args.cred_n8n_self_name
        elif cred_type == "openAiApi":
            new_id, new_name = args.cred_openrouter_openai, args.cred_openrouter_openai_name
        elif cred_type == "imap":
            new_id, new_name = args.cred_imap, args.cred_imap_name
        elif cred_type == "gmailOAuth2":
            continue  # swap-point only, disabled node, stays REPLACE_ME
        if new_id:
            creds[cred_type] = {"id": new_id, "name": new_name or old_name}
        # else: secret not supplied -> leave REPLACE_ME exactly as shipped


def rewrite_data_tables(node, args):
    if node.get("type") != "n8n-nodes-base.dataTable":
        return
    params = node.get("parameters", {})
    for key in ("dataTableId",):
        rl = params.get(key)
        if isinstance(rl, dict) and rl.get("mode") == "id":
            cached_name = rl.get("cachedResultName", "")
            attr = DT_NAME_MAP.get(cached_name)
            if attr:
                new_id = getattr(args, attr)
                new_name = getattr(args, attr + "_name")
                if new_id:
                    rl["value"] = new_id
                    rl["cachedResultName"] = new_name or cached_name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--api-key", required=True)
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--installed-json", required=True)
    for flag in [
        "cred-postgres", "cred-postgres-name",
        "cred-apify", "cred-apify-name",
        "cred-openrouter-header", "cred-openrouter-header-name",
        "cred-openrouter-openai", "cred-openrouter-openai-name",
        "cred-n8n-self", "cred-n8n-self-name",
        "cred-imap", "cred-imap-name",
        "dt-ep07-caps", "dt-ep07-caps-name",
        "dt-ep08-lanes", "dt-ep08-lanes-name",
        "dt-ep08-caps", "dt-ep08-caps-name",
        "dt-ep09-caps", "dt-ep09-caps-name",
    ]:
        ap.add_argument("--" + flag, default="")
    args = ap.parse_args()

    try:
        with open(args.installed_json, encoding="utf-8") as f:
            installed = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        installed = {}
    installed.setdefault("workflows", [])
    installed.setdefault("data_tables", [])
    installed.setdefault("credentials", [])
    for b in BRICKS:
        wf_path = f"{args.repo_root}/{b}/workflow.json"
        with open(wf_path, encoding="utf-8") as f:
            wf = json.load(f)

        for node in wf.get("nodes", []):
            rewrite_credentials(node, args)
            rewrite_data_tables(node, args)

        settings = wf.get("settings", {}) or {}
        settings["executionTimeout"] = 300
        body = {
            "name": wf["name"],
            "nodes": wf["nodes"],
            "connections": wf["connections"],
            "settings": settings,
        }
        created = req("POST", f"{args.base_url}/api/v1/workflows", args.api_key, body)
        wf_id = created.get("id")
        if not wf_id:
            print(f"FAILED to import {b}: {json.dumps(created)[:300]}", file=sys.stderr)
            sys.exit(1)
        # Force inactive regardless of server default.
        req("POST", f"{args.base_url}/api/v1/workflows/{wf_id}/deactivate", args.api_key)
        installed["workflows"].append({"brick": b, "name": wf["name"], "id": wf_id})
        print(f"  + {b} -> {wf['name']} ({wf_id}) active:false", file=sys.stderr)

    with open(args.installed_json, "w", encoding="utf-8") as f:
        json.dump(installed, f, indent=2)


if __name__ == "__main__":
    main()
