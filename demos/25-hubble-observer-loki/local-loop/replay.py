#!/usr/bin/env python3
"""replay.py — push the observer's flow lines into a Loki, stamped over the last N minutes, with the labels the observer's
pod has in the lab ({namespace="hubble-observer", container="hubble-observer"}), so the dashboard's "Last 30 minutes"
shows them. Lines come from files: one JSON flow per line (the observer's stdout as the CI artifact keeps it in
captures/observer-flows.ndjson, or any `hubble observe -o json` capture); lines that are not JSON are skipped.

  replay.py --loki http://localhost:3100 --minutes 25 captures/observer-flows.ndjson [more files…]
  replay.py --container hubble-observer-verdicts demos/34-verdict-to-policy/output/verdicts.ndjson   # a second stream

The timestamps are rewritten (the recorded time is kept inside the line as the observer wrote it; only Loki's timestamp
moves), spread evenly so the "Flows over time" bars show a run and not one spike. No line is invented here: what is
not in the files is not in Loki.
"""
import argparse, json, sys, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("files", nargs="+")
ap.add_argument("--loki", default="http://localhost:3100")
ap.add_argument("--minutes", type=int, default=25, help="spread the lines over the last N minutes")
ap.add_argument("--namespace", default="hubble-observer")
ap.add_argument("--container", default="hubble-observer")
ap.add_argument("--batch", type=int, default=500)
a = ap.parse_args()

lines = []
for f in a.files:
    for l in open(f, encoding="utf-8", errors="replace"):
        l = l.strip()
        if not l.startswith("{"):
            continue
        try:
            json.loads(l)
        except Exception:
            continue
        lines.append(l)
if not lines:
    sys.exit("no JSON lines in the files given")

now_ns = time.time_ns(); start = now_ns - a.minutes * 60 * 1_000_000_000
step = (now_ns - start) // max(len(lines), 1)
labels = {"namespace": a.namespace, "container": a.container, "pod": f"{a.container}-local-loop", "job": "local-loop"}
sent = 0
for i in range(0, len(lines), a.batch):
    chunk = lines[i:i + a.batch]
    values = [[str(start + (i + j) * step), l] for j, l in enumerate(chunk)]
    body = json.dumps({"streams": [{"stream": labels, "values": values}]}).encode()
    req = urllib.request.Request(a.loki.rstrip("/") + "/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status not in (200, 204):
            sys.exit(f"loki answered {r.status}")
    sent += len(chunk)
print(f"{sent} lines → {a.loki} as {labels}, stamped over the last {a.minutes} minutes")
