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
# Get this message by its id, so a message left on the queue by an earlier run cannot answer.
message_id = put.headers.get("ibm-mq-md-messageId", "")
print(f"put     ibm-mq-md-messageId: {message_id}")
if put.status_code != 201 or not message_id:
    raise SystemExit("verdict UNKNOWN: the put failed or returned no message id")
carried, removed = False, False
try:
    got = mq.delete(url, params={"messageId": message_id, "wait": "5000"}, headers={"Accept": "text/plain"})
    # 200 removed the message selected by id; 204 means that id is no longer on the queue.
    removed = got.status_code in (200, 204)
    print(f"get     {got.status_code}  body: {got.text!r}")
    for name, value in got.headers.items():
        if name.lower().startswith("ibm-mq"):
            print(f"header  {name}: {value}")
    back = got.headers.get("ibm-mq-usr", "")
    # The same message, and the same property, value and type, exactly.
    carried = got.status_code == 200 and got.headers.get("ibm-mq-md-messageId") == message_id and back == sent
    print(f"verdict {'CARRIED' if carried else 'NOT CARRIED'}: sent {traceparent}, got back {back!r}")
finally:
    if not removed:
        cleanup = mq.delete(url, params={"messageId": message_id}, headers={"Accept": "text/plain"})
        print(f"cleanup {cleanup.status_code}  messageId: {message_id}")
        if cleanup.status_code not in (200, 204):
            raise SystemExit("verdict UNKNOWN: the spike's message could not be removed")
if not carried:
    raise SystemExit(1)
PY
