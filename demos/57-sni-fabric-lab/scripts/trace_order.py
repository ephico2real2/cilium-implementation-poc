#!/usr/bin/env python3
"""Places one order and prints every hop it took through Envoy, from Envoy's access log.

Usage: scripts/trace_order.py [--item NAME] [--wait SECONDS] [--port N]
Best run while no other traffic flows: entries are picked by time, so a concurrent load run
adds its own hops to the list.
The hops of one order: the browser-side POST /orders (TLS passed through edge_sni), the
event's put on MQ (POST through mesh_http), the worker's get (DELETE through mesh_http), and
the worker's status update (PUT through mesh_http). Each line shows the listener's view:
method or SNI, host, path, status, Envoy's attempts, and the cluster it went to. Exits 1 if
the order is not processed within --wait seconds.
"""
import argparse
import datetime
import json
import os
import ssl
import subprocess
import time
import urllib.request
import uuid
from pathlib import Path

DEMO = Path(__file__).resolve().parent.parent
CA = str(DEMO / "certs" / "ca" / "ca.crt")
context = ssl.create_default_context(cafile=CA)


def api(method: str, url: str, body: dict | None = None, headers: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, context=context, timeout=10) as response:
        return json.load(response)


def parse_time(iso: str) -> float:
    return datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def hops(order: dict) -> list[str]:
    """The access-log lines of this order's hops, oldest first: only entries whose span
    overlaps the order's life, so other traffic is left out. The span matters for the
    worker's get, a long poll that may start waiting before the order exists."""
    first = parse_time(order["created_at"]) - 1.0
    last = parse_time(order["processed_at"]) + 1.0
    log = subprocess.run(["podman", "logs", "--since", "10m", "fabric-envoy-1"],
                         capture_output=True, text=True, check=True)
    order_id = order["id"]
    lines = []
    for raw in (log.stdout + log.stderr).splitlines():
        try:
            entry = json.loads(raw)
        except ValueError:
            continue  # Envoy's own (non-JSON) log lines
        start = parse_time(entry["start"])
        end = start + int(entry.get("duration_ms") or 0) / 1000
        if end < first or start > last:
            continue
        if entry.get("kind") == "tcp" and entry.get("sni") == "api.fabric.localtest.me":
            lines.append(f"{entry['start']}  TLS    {entry['sni']} -> {entry['cluster']} "
                         f"(passed through, {entry['bytes_in']} bytes in)")
            continue
        if entry.get("kind") != "http":
            continue
        method, path, status = entry["method"], str(entry["path"]).split("?")[0], int(entry["status"])
        is_put_event = method == "POST" and str(entry["host"]).startswith("mqrest")
        is_get_event = method == "DELETE" and status == 200  # 204 is the worker's empty poll
        is_update = method == "PUT" and path == f"/orders/{order_id}/status"
        if is_put_event or is_get_event or is_update:
            lines.append(f"{entry['start']}  {method:6} {entry['host']}{path} -> {status} "
                         f"attempts={entry['attempts']} cluster={entry['cluster']}")
    return sorted(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--item", default="cortado", help="what to order (default: cortado)")
    parser.add_argument("--wait", type=int, default=30, help="seconds to wait for processed (default: 30)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("FABRIC_TLS_PORT", "8443")),
                        help="Envoy's published TLS port (default: $FABRIC_TLS_PORT or 8443)")
    args = parser.parse_args()
    base = f"https://api.fabric.localtest.me:{args.port}"

    order = api("POST", f"{base}/orders", {"item": args.item, "quantity": 1},
                {"Idempotency-Key": str(uuid.uuid4())})
    print(f"order {order['id']} created: {order['status']}, events sent {order['events_sent']}")
    deadline = time.monotonic() + args.wait
    while order["status"] != "processed" and time.monotonic() < deadline:
        time.sleep(1)
        order = api("GET", f"{base}/orders/{order['id']}")
    print(f"order {order['id']} now: {order['status']}")
    if order["status"] != "processed":
        return 1
    # Envoy flushes its access log every second (compose.yaml); wait for the status update.
    lines: list[str] = []
    for _ in range(15):
        lines = hops(order)
        if any(" PUT " in line for line in lines):
            break
        time.sleep(1)
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
