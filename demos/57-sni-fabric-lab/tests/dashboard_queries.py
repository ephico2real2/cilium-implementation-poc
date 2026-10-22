"""Runs every query in the Grafana dashboard against the lab's Prometheus and reports each one.

Usage: python tests/dashboard_queries.py [dashboard.json] [--prometheus URL] [--minutes 15]
For each panel query: the status, warnings, how many series came back and the latest value of
each. Exits non-zero if any query errors or warns. A query that returns no series is listed,
not failed: some are empty by design (no rollbacks, no dead letters); the report says which.
"""
import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT = Path(__file__).resolve().parent.parent / "observability" / "grafana" / "dashboards" / "fabric.json"


def query(base: str, expr: str, instant: bool, minutes: int) -> dict:
    now = time.time()
    if instant:
        url = f"{base}/api/v1/query?" + urllib.parse.urlencode({"query": expr, "time": now})
    else:
        url = f"{base}/api/v1/query_range?" + urllib.parse.urlencode(
            {"query": expr, "start": now - minutes * 60, "end": now, "step": 15})
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dashboard", nargs="?", default=str(DEFAULT), help="Grafana dashboard JSON (default: the lab's)")
    parser.add_argument("--prometheus", default="http://prometheus.fabric.localtest.me:8080",
                        help="Prometheus base URL (default: the lab's, through Envoy's ops_http)")
    parser.add_argument("--minutes", type=int, default=15, help="range queried for time series (default: 15)")
    args = parser.parse_args()

    board = json.loads(Path(args.dashboard).read_text())
    problems = empty = total = 0
    started = time.monotonic()
    for panel in board["panels"]:
        for target in panel.get("targets", []):
            total += 1
            result = query(args.prometheus, target["expr"], target.get("instant", False), args.minutes)
            warnings = result.get("warnings", []) + result.get("infos", [])
            data = result.get("data", {}).get("result", [])
            latest = []
            for series in data:
                value = series["value"][1] if "value" in series else (series["values"][-1][1] if series["values"] else "-")
                label = ",".join(f"{k}={v}" for k, v in series["metric"].items() if k not in ("__name__", "instance", "component"))
                latest.append(f"{label or 'value'}={float(value):.4g}" if value != "-" else f"{label}=-")
            status = result.get("status")
            if status != "success" or warnings:
                problems += 1
                flag = "ERROR"
            elif not data:
                empty += 1
                flag = "EMPTY"
            else:
                flag = "ok"
            print(f"{flag:5}  {panel['title'][:58]:58}  {target['refId']}  series={len(data)}  {'; '.join(latest)[:110]}")
            for warning in warnings:
                print(f"       warning: {warning}")
    print(f"\n{total} queries, {problems} with errors or warnings, {empty} empty, "
          f"{time.monotonic() - started:.2f} s in all")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
