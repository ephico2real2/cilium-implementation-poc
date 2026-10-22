#!/usr/bin/env bash
# Usage: test_status_auth.sh <services/orders-api/app> <a CA certificate>
# Envoy's mesh_http routes api.mesh from every lab network, so PUT /orders/{id}/status must
# refuse a caller without the worker token. Runs the given app code in the built orders-api
# image, with no network and no database: a call that passes the token check stops at the
# database check (503), one that does not gets 401.
set -u
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'pg' > "${work}/postgres-password"
printf 'right-token' > "${work}/worker-token"
: > "${work}/empty-worker-token"
cp "$2" "${work}/ca.crt"
chmod 644 "${work}"/*
worker_dir="$(cd "$1/../../worker" && pwd)"
podman run --rm -i --network none --read-only \
  -v "$(cd "$1" && pwd):/srv/app:ro" -v "${worker_dir}:/srv/worker:ro" -v "${work}:/s:ro" \
  -e DB_PASSWORD_FILE=/s/postgres-password -e WORKER_TOKEN_FILE=/s/worker-token -e CA_FILE=/s/ca.crt \
  -e PYTHONDONTWRITEBYTECODE=1 \
  localhost/fabric-orders-api:dev python - <<'PY'
import sys
import importlib.util
from fastapi.testclient import TestClient
from app.main import internal

client = TestClient(internal)
cases = [
    ("no token", {}, 401),
    ("wrong token", {"Authorization": "Bearer wrong"}, 401),
    ("bare token", {"Authorization": "right-token"}, 401),
    ("lowercase scheme", {"Authorization": "bearer right-token"}, 401),
    ("repeated scheme", {"Authorization": "Bearer Bearer right-token"}, 401),
    ("extra whitespace", {"Authorization": "Bearer  right-token"}, 401),
    ("worker token", {"Authorization": "Bearer right-token"}, 503),
]
bad = 0
for name, headers, want in cases:
    got = client.put("/orders/1/status", json={"status": "failed"}, headers=headers).status_code
    verdict = "ok" if got == want else "MISMATCH"
    bad += verdict != "ok"
    print(f"{verdict:9} {name:16} -> {got} (want {want})")

spec = importlib.util.spec_from_file_location("fabric_worker", "/srv/worker/worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
reader = getattr(worker, "required_secret", lambda path: open(path, encoding="utf-8").read().strip())
for name, path in [("empty worker file", "/s/empty-worker-token"),
                   ("missing worker file", "/s/missing-worker-token")]:
    try:
        reader(path)
        got = "accepted"
    except (OSError, RuntimeError):
        got = "refused"
    verdict = "ok" if got == "refused" else "MISMATCH"
    bad += verdict != "ok"
    print(f"{verdict:9} {name:19} -> {got} (want refused)")
print(f"mismatches: {bad}")
sys.exit(bad)
PY
