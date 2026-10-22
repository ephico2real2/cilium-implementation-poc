#!/usr/bin/env bash
# Usage: tests/spikes/r1-5_mq_traceparent.sh   (from the demo directory, against the running lab)
# Spike for R1.5 (#107): does MQ REST API v3 carry a W3C traceparent as a user property, through
# Envoy, from a put to a destructive get? Runs inside the worker, which reaches MQ only as
# mqrest.mesh, with the worker's own app credentials, on DEV.QUEUE.3, which nothing in the lab
# reads. Writes the request and response headers to output/spike-r1-5-mq-traceparent.txt.
set -euo pipefail
out="output/spike-r1-5-mq-traceparent.txt"
podman exec -i fabric-worker-1 python - <<'PY' | tee "${out}"
import os
import secrets

import httpx

base = os.environ.get("MQ_REST_URL", "http://mqrest.mesh:18080/ibmmq/rest/v3")
url = f"{base}/messaging/qmgr/QM1/queue/DEV.QUEUE.3/message"
password = open("/secrets/worker/mq-app-password").read().strip()
traceparent = f"00-{secrets.token_hex(16)}-{secrets.token_hex(8)}-01"
mq = httpx.Client(auth=("app", password), headers={"ibm-mq-rest-csrf-token": "spike"}, timeout=15)

# The documented form: name; value; type, a string value quoted.
sent = f'traceparent;"{traceparent}";string'
put = mq.post(url, content="spike r1.5", headers={"Content-Type": "text/plain", "ibm-mq-usr": sent})
print(f"put     {put.status_code}  ibm-mq-usr: {sent}")
got = mq.delete(url, params={"wait": "5000"}, headers={"Accept": "text/plain"})
print(f"get     {got.status_code}  body: {got.text!r}")
for name, value in got.headers.items():
    if name.lower().startswith("ibm-mq"):
        print(f"header  {name}: {value}")
back = got.headers.get("ibm-mq-usr", "")
verdict = "CARRIED" if traceparent in back else "NOT CARRIED"
print(f"verdict {verdict}: sent {traceparent}, got back {back!r}")
PY
