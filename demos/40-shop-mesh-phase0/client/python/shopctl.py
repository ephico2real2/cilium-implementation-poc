#!/usr/bin/env python3
"""shopctl.py — the shop platform's external Python client (enhancement 002 §3.3).

One contract with the Go sibling: the same flags, the same table columns, the same exit-code
rule. Standard library only. Neither client knows there are two clusters; X-Served-By is
reported, never used.
"""
from __future__ import annotations

import argparse
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

PROBE_PATHS = ("/healthz", "/ready", "/orders")
DEFAULT_TIMEOUT = 2.0

_UNITS = {"ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1.0, "m": 60.0, "h": 3600.0}
_DURATION = re.compile(r"^(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|ms|s|m|h)$")


def parse_duration(text: str) -> float:
    """Seconds as a number ("3", "0.5") or a Go duration ("3s", "500ms", "1m") — the same
    spelling the Go sibling accepts, so a runbook line works verbatim with either client."""
    try:
        v = float(text)
    except ValueError:
        v = None
    if v is None:
        parts = [_DURATION.match(tok) for tok in re.findall(r"[\d.]+[a-zµ]+", text)]
        if not text or not parts or any(m is None for m in parts) or "".join(m.group(0) for m in parts) != text:
            raise argparse.ArgumentTypeError(f"{text!r} is neither seconds (3, 0.5) nor a duration (3s, 500ms, 1m)")
        v = sum(float(m.group(1)) * _UNITS[m.group(2)] for m in parts)
    if v < 0:
        raise argparse.ArgumentTypeError(f"negative duration {text!r}")
    return v


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="shopctl.py",
        description="probe or load an HTTPS door. The client knows only --url.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--url", required=True, help="base URL of the door")
        p.add_argument("--cacert", default="", help="PEM file of the CA to trust")
        p.add_argument("-k", "--insecure", action="store_true", help="skip CA verification (the operator's flag)")
        p.add_argument("--timeout", type=parse_duration, default=DEFAULT_TIMEOUT, help="per-request timeout: seconds or a duration such as 500ms (default 2)")

    probe = sub.add_parser("probe", help="hit /healthz, /ready, /orders once")
    add_common(probe)

    load = sub.add_parser("load", help="N req/s for M seconds")
    add_common(load)
    load.add_argument("--rate", type=int, required=True, help="requests per second")
    load.add_argument("--duration", type=parse_duration, required=True, help="how long to run: seconds or a duration such as 1m")
    load.add_argument("--path", default="/healthz", help="path to hit (default /healthz)")
    return parser.parse_args(argv)


def ssl_context(insecure: bool, cacert: str) -> ssl.SSLContext | None:
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if cacert:
        return ssl.create_default_context(cafile=cacert)
    return ssl.create_default_context()


def do_hit(url: str, timeout: float, ctx: ssl.SSLContext | None) -> dict:
    start = time.perf_counter()
    status, served, err = 0, "", None
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            status = resp.status
            served = resp.headers.get("X-Served-By") or ""
            resp.read(4096)
    except urllib.error.HTTPError as e:
        status = e.code
        served = (e.headers.get("X-Served-By") if e.headers else "") or ""
    except Exception as e:  # noqa: BLE001 — connection failures are a measured miss
        err = e
    latency_ms = (time.perf_counter() - start) * 1000.0
    return {"status": status, "served": served, "err": err, "latency_ms": latency_ms}


def join_served(values: list[str]) -> str:
    seen = []
    for v in values:
        if v and v not in seen:
            seen.append(v)
    return ",".join(sorted(seen)) if seen else "-"


def aggregate_second(second: int, hits: list[dict]) -> dict:
    ok = fail = 0
    served: list[str] = []
    for h in hits:
        if h["err"] is None and 200 <= h["status"] < 300:
            ok += 1
            if h["served"]:
                served.append(h["served"])
        else:
            fail += 1
            if h["served"]:
                served.append(h["served"])
    return {"second": second, "ok": ok, "fail": fail, "served": served}


def percentile(sorted_ms: list[float], p: float) -> float:
    """Nearest lower rank, no interpolation — the Go sibling's percentile(), so both clients print
    the same numbers for the same samples (statistics.quantiles would interpolate: 5.5 where Go says 5)."""
    if not sorted_ms:
        return 0.0
    if p <= 0:
        return sorted_ms[0]
    if p >= 100:
        return sorted_ms[-1]
    return sorted_ms[int((p / 100.0) * (len(sorted_ms) - 1))]


def latency_summary(hits: list[dict]) -> tuple[float, float, float, float]:
    ms = sorted(h["latency_ms"] for h in hits)
    if not ms:
        return 0.0, 0.0, 0.0, 0.0
    return percentile(ms, 50), percentile(ms, 95), percentile(ms, 99), ms[-1]


def run_probe(base: str, timeout: float, ctx: ssl.SSLContext | None, out=sys.stdout) -> int:
    print(f"{'PATH':<10} {'STATUS':<8} X-SERVED-BY", file=out)
    fails = 0
    base = base.rstrip("/")
    for path in PROBE_PATHS:
        h = do_hit(base + path, timeout, ctx)
        if h["err"] is None:
            status = str(h["status"])
            served = h["served"] or "-"
            if not (200 <= h["status"] < 300):
                fails += 1
        else:
            status, served = "000", "-"
            fails += 1
        print(f"{path:<10} {status:<8} {served}", file=out)
    return fails


def fire_second(url: str, rate: int, timeout: float, ctx: ssl.SSLContext | None) -> list[dict]:
    hits: list[dict] = []
    with ThreadPoolExecutor(max_workers=max(rate, 1)) as pool:
        futs = [pool.submit(do_hit, url, timeout, ctx) for _ in range(rate)]
        for f in as_completed(futs):
            hits.append(f.result())
    return hits


def run_load(base: str, path: str, rate: int, duration: float, timeout: float, ctx: ssl.SSLContext | None, out=sys.stdout) -> int:
    if not path.startswith("/"):
        path = "/" + path
    url = base.rstrip("/") + path
    seconds = max(int(round(duration)), 1)
    print(f"{'SECOND':<8} {'OK':<6} {'FAIL':<6} X-SERVED-BY", file=out)
    all_hits: list[dict] = []
    fail_seconds = 0
    for sec in range(1, seconds + 1):
        t0 = time.perf_counter()
        hits = fire_second(url, rate, timeout, ctx)
        all_hits.extend(hits)
        agg = aggregate_second(sec, hits)
        print(f"{agg['second']:<8} {agg['ok']:<6} {agg['fail']:<6} {join_served(agg['served'])}", file=out)
        if agg["fail"] > 0:
            fail_seconds += 1
        remain = 1.0 - (time.perf_counter() - t0)
        if remain > 0 and sec < seconds:
            time.sleep(remain)
    p50, p95, p99, mx = latency_summary(all_hits)
    print(f"latency_ms  p50={p50:.1f}  p95={p95:.1f}  p99={p99:.1f}  max={mx:.1f}", file=out)
    return fail_seconds


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    ctx = ssl_context(args.insecure, args.cacert)
    if args.cmd == "probe":
        return run_probe(args.url, args.timeout, ctx)
    if args.rate <= 0:
        print("shopctl.py: --rate must be a positive integer", file=sys.stderr)
        return 2
    if args.duration <= 0:
        print("shopctl.py: --duration must be a positive number", file=sys.stderr)
        return 2
    return run_load(args.url, args.path, args.rate, args.duration, args.timeout, ctx)


if __name__ == "__main__":
    sys.exit(main())
