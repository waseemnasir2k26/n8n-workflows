"""Feed the 20 synthetic quote emails into the workflow's webhook.

    python feed.py https://YOUR-N8N/webhook/ep04-email-in            # one POST, all 20 emails
    python feed.py https://YOUR-N8N/webhook/ep04-email-in --one-by-one # 20 POSTs, one email each
    python feed.py https://YOUR-N8N/webhook-test/ep04-email-in       # against "Listen for test event" in the editor

The workflow answers with the Run summary item when it finishes (responseMode = lastNode):
{emails_seen, rows_written, fields_filled_avg, seconds_avg, ...}. Nothing is sent to any mailbox.
No third-party packages: urllib only.
"""
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def post(url, payload, timeout=900):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode("utf-8", "replace")
        return r.status, body


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    url = sys.argv[1]
    one_by_one = "--one-by-one" in sys.argv
    with open(os.path.join(HERE, "quotes-20.json"), encoding="utf-8") as f:
        emails = json.load(f)
    if one_by_one:
        for e in emails:
            status, body = post(url, e)
            print(status, e["message_id"], body[:200])
    else:
        status, body = post(url, {"emails": emails})
        print(status)
        print(body)


if __name__ == "__main__":
    main()
