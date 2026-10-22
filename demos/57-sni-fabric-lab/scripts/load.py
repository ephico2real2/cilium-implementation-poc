#!/usr/bin/env python3
"""Sends a steady mix of traffic through Envoy's published port, so every panel has data.

Usage: scripts/load.py [--seconds N] [--rate N] [--port N]
Each second, `rate` times: one new order, one replay of an earlier order (same
Idempotency-Key), one TCP ping through the API; every fifth second, one connection with an
unknown SNI, which Envoy must reset. It does not retry, so a failure shows as it happened.
At the end it prints each kind of request with the status it got and how often
(0 means no HTTP answer at all). Stops by itself after --seconds.
"""
import argparse
import os
import json
import socket
import ssl
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from pathlib import Path

DEMO = Path(__file__).resolve().parent.parent
CA = str(DEMO / "certs" / "ca" / "ca.crt")
PORT = int(os.environ.get("FABRIC_TLS_PORT", "8443"))
API = f"https://api.fabric.localtest.me:{PORT}"
ITEMS = ["espresso", "flat white", "cortado", "matcha latte"]

context = ssl.create_default_context(cafile=CA)


def call(method: str, path: str, body: dict | None = None, headers: dict | None = None) -> int:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{API}{path}", data=data, method=method,
                                     headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(request, context=context, timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except OSError:
        return 0


def unknown_sni() -> str:
    """Opens TLS with an SNI no Envoy chain matches; Envoy should reset it."""
    raw = socket.create_connection(("127.0.0.1", int(API.rsplit(":", 1)[1])), timeout=5)
    try:
        ssl.create_default_context(cafile=CA).wrap_socket(raw, server_hostname="unknown.fabric.localtest.me")
        return "accepted"
    except (ssl.SSLError, ConnectionError, OSError):
        return "reset"
    finally:
        raw.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=int, default=120, help="how long to run (default: 120)")
    parser.add_argument("--rate", type=int, default=2,
                        help="new orders per second; replays and pings follow the same rate (default: 2)")
    parser.add_argument("--port", type=int, default=PORT,
                        help="Envoy's published TLS port (default: $FABRIC_TLS_PORT or 8443)")
    args = parser.parse_args()
    global API
    API = f"https://api.fabric.localtest.me:{args.port}"

    results: Counter[str] = Counter()
    keys: list[tuple[str, dict]] = []
    end = time.monotonic() + args.seconds
    round_no = 0
    while time.monotonic() < end:
        started = time.monotonic()
        for _ in range(args.rate):
            body = {"item": ITEMS[round_no % len(ITEMS)], "quantity": 1 + round_no % 3}
            key = str(uuid.uuid4())
            results[f"POST /orders new -> {call('POST', '/orders', body, {'Idempotency-Key': key})}"] += 1
            keys.append((key, body))
            old_key, old_body = keys[round_no % len(keys)]
            results[f"POST /orders replay -> {call('POST', '/orders', old_body, {'Idempotency-Key': old_key})}"] += 1
            results[f"GET /tcp/ping -> {call('GET', '/tcp/ping')}"] += 1
        if round_no % 5 == 0:
            results[f"unknown SNI -> {unknown_sni()}"] += 1
        round_no += 1
        time.sleep(max(0.0, 1.0 - (time.monotonic() - started)))
    for line, count in sorted(results.items()):
        print(f"{count:6}  {line}")


if __name__ == "__main__":
    main()
