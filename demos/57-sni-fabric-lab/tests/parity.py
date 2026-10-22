#!/usr/bin/env python3
"""Compare ten representative Grafana queries in Prometheus and VictoriaMetrics.

The ten queries cover every dashboard section and the distinct behaviours a second store must
preserve: current health, accepted and rejected SNI connections, retries, order flow, recovery,
MQ throughput and its latency gauge, Postgres transactions, and TCP commands. They are loaded by
exact panel title and refId from fabric.json; a renamed or missing panel is an error, never an
empty comparison.

Both stores are evaluated at exactly T = now - 30 seconds. That three-scrape margin lets both
10-second scrapers ingest the samples before either store evaluates T. For each label set, "one
scrape interval's movement" is defined as abs(Prometheus(T) - Prometheus(T - 10 seconds)); the
Prometheus/VictoriaMetrics difference at T must be less than or equal to that movement, plus a
1e-12 relative floating-point allowance. Different scrape phases can put one different counter
sample into a rate() over [5m], so this allows the amount the query itself moved across one
scrape, not an arbitrary percentage. A live Prometheus measurement on 2026-10-22 found maximum
movement 0 for nine selections and 2.37809e-07 for tcp-svc PING.

Only the dashboard's Prometheus-scraped metrics are selected. OTLP-ingested metrics in
VictoriaMetrics retain dotted resource labels such as ``service.name``; they have no Prometheus
counterpart and are deliberately outside this comparison.

Usage: python3 tests/parity.py [dashboard.json] [--prometheus URL]
       [--victoriametrics URL] [--markdown]
"""
from __future__ import annotations

import argparse
import json
import math
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DASHBOARD = (Path(__file__).resolve().parent.parent
                     / "observability/grafana/dashboards/fabric.json")
SCRAPE_INTERVAL_SECONDS = 10
EVALUATION_MARGIN_SECONDS = 30
FLOAT_ALLOWANCE = 1e-12

# Exact title plus query ref: panel renames and query reordering are intentional test failures.
SELECTIONS = (
    ("Each component, now", "A"),
    ("New connections per tenant (per second)", "A"),
    ("Connections reset: unknown or missing SNI (per second)", "A"),
    ("Envoy's retries to orders-api (per second)", "A"),
    ("Orders created, replayed and processed (per second)", "A"),
    ("Events that needed another try (per second)", "A"),
    ("Queue manager: messages put and got (per second)", "A"),
    ("Queue manager: recovery log write latency, now (seconds)", "A"),
    ("Postgres: transactions (per second)", "A"),
    ("tcp-svc: commands (per second)", "A"),
)

LabelSet = tuple[tuple[str, str], ...]
Series = dict[LabelSet, float]


@dataclass(frozen=True)
class Comparison:
    """The result for one expression, kept separate so its edge cases are unit-testable."""

    agrees: bool
    prometheus_series: int
    victoria_series: int
    max_difference: float | None
    max_tolerance: float | None
    detail: str


def compare_series(prometheus: Series, victoria: Series, movement: Series) -> Comparison:
    """Compare exact label sets and values using each series' measured one-scrape movement."""
    prometheus_labels = set(prometheus)
    victoria_labels = set(victoria)
    if not prometheus_labels and not victoria_labels:
        return Comparison(False, 0, 0, None, None, "no series in either store")
    if prometheus_labels != victoria_labels:
        only_prometheus = prometheus_labels - victoria_labels
        only_victoria = victoria_labels - prometheus_labels
        detail = (f"label sets differ: Prometheus-only={len(only_prometheus)}, "
                  f"VictoriaMetrics-only={len(only_victoria)}")
        return Comparison(False, len(prometheus), len(victoria), None, None, detail)

    differences: list[float] = []
    tolerances: list[float] = []
    outside = 0
    for labels in sorted(prometheus_labels):
        left = prometheus[labels]
        right = victoria[labels]
        one_scrape = movement.get(labels, 0.0)
        if not all(math.isfinite(value) for value in (left, right, one_scrape)):
            return Comparison(False, len(prometheus), len(victoria), None, None,
                              "a value or movement is not finite")
        allowance = FLOAT_ALLOWANCE * max(1.0, abs(left), abs(right))
        tolerance = abs(one_scrape) + allowance
        difference = abs(left - right)
        differences.append(difference)
        tolerances.append(tolerance)
        if difference > tolerance:
            outside += 1

    maximum = max(differences)
    # Report the allowance for the same series that produced the maximum difference.
    max_tolerance = tolerances[differences.index(maximum)]
    if outside:
        return Comparison(False, len(prometheus), len(victoria), maximum, max_tolerance,
                          f"{outside} series outside one-scrape movement")
    return Comparison(True, len(prometheus), len(victoria), maximum, max_tolerance,
                      "within one-scrape movement")


def selected_queries(path: Path) -> list[tuple[str, str]]:
    """Return display name and expression for every exact selection, or fail loudly."""
    dashboard = json.loads(path.read_text())
    panels: dict[str, list[dict]] = {}
    for panel in dashboard.get("panels", []):
        panels.setdefault(panel.get("title", ""), []).append(panel)

    selected: list[tuple[str, str]] = []
    for title, ref_id in SELECTIONS:
        matches = panels.get(title, [])
        if len(matches) != 1:
            raise ValueError(f"panel title {title!r}: expected one match, found {len(matches)}")
        targets = [target for target in matches[0].get("targets", [])
                   if target.get("refId") == ref_id]
        if len(targets) != 1 or not targets[0].get("expr"):
            raise ValueError(f"panel {title!r}: expected one non-empty target {ref_id}")
        selected.append((title, targets[0]["expr"]))
    return selected


def instant_query(base: str, expression: str, timestamp: float) -> Series:
    """Evaluate one expression, rejecting warnings and dotted-label OTLP series."""
    url = f"{base.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode(
        {"query": expression, "time": f"{timestamp:.3f}"})
    with urllib.request.urlopen(url, timeout=30) as response:
        payload = json.load(response)
    if payload.get("status") != "success":
        raise ValueError(f"query status is {payload.get('status')!r}: {payload.get('error', '')}")
    notices = payload.get("warnings", []) + payload.get("infos", [])
    if notices:
        raise ValueError("; ".join(str(notice) for notice in notices))

    values: Series = {}
    for result in payload.get("data", {}).get("result", []):
        metric = result.get("metric", {})
        # The selected expressions should never yield one; keep AC 6 explicit if they change.
        if any("." in label for label in metric):
            continue
        labels = tuple(sorted((str(label), str(value)) for label, value in metric.items()))
        sample = result.get("value")
        if not sample or len(sample) != 2:
            raise ValueError("instant query returned a non-instant sample")
        if labels in values:
            raise ValueError(f"duplicate label set: {labels}")
        values[labels] = float(sample[1])
    return values


def format_number(value: float | None) -> str:
    return "—" if value is None else f"{value:.6g}"


def print_table(rows: list[tuple[str, Comparison]], markdown: bool) -> None:
    if markdown:
        print("| Query | Prometheus series | VictoriaMetrics series | Max difference | Verdict |")
        print("|---|---:|---:|---:|---|")
        for name, result in rows:
            difference = format_number(result.max_difference)
            if result.max_tolerance is not None:
                difference += f" (allowed {format_number(result.max_tolerance)})"
            verdict = "PASS" if result.agrees else f"FAIL: {result.detail}"
            print(f"| {name} | {result.prometheus_series} | {result.victoria_series} | "
                  f"{difference} | {verdict} |")
        return

    widths = (58, 10, 15, 27)
    print(f"{'query':{widths[0]}}  {'Prometheus':>{widths[1]}}  "
          f"{'VictoriaMetrics':>{widths[2]}}  {'max difference':>{widths[3]}}  verdict")
    for name, result in rows:
        difference = format_number(result.max_difference)
        if result.max_tolerance is not None:
            difference += f" <= {format_number(result.max_tolerance)}"
        verdict = "PASS" if result.agrees else f"FAIL: {result.detail}"
        print(f"{name[:widths[0]]:{widths[0]}}  {result.prometheus_series:>{widths[1]}}  "
              f"{result.victoria_series:>{widths[2]}}  {difference:>{widths[3]}}  {verdict}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dashboard", nargs="?", default=str(DEFAULT_DASHBOARD),
                        help="Grafana dashboard JSON (default: the lab's)")
    parser.add_argument("--prometheus", default="http://prometheus.fabric.localtest.me:8080")
    parser.add_argument("--victoriametrics",
                        default="http://victoriametrics.fabric.localtest.me:8080")
    parser.add_argument("--markdown", action="store_true", help="print the result table as Markdown")
    args = parser.parse_args()

    evaluation_time = time.time() - EVALUATION_MARGIN_SECONDS
    rows: list[tuple[str, Comparison]] = []
    try:
        queries = selected_queries(Path(args.dashboard))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}")
        return 1

    for title, expression in queries:
        try:
            prometheus = instant_query(args.prometheus, expression, evaluation_time)
            victoria = instant_query(args.victoriametrics, expression, evaluation_time)
            previous = instant_query(args.prometheus, expression,
                                     evaluation_time - SCRAPE_INTERVAL_SECONDS)
            movement = {labels: abs(value - previous.get(labels, value))
                        for labels, value in prometheus.items()}
            result = compare_series(prometheus, victoria, movement)
        except Exception as error:  # Keep all ten rows visible when one endpoint or query fails.
            result = Comparison(False, 0, 0, None, None, f"query error: {error}")
        rows.append((title, result))

    print(f"Evaluation timestamp: {evaluation_time:.3f} (now - {EVALUATION_MARGIN_SECONDS}s; "
          f"scrape interval {SCRAPE_INTERVAL_SECONDS}s)")
    print("Scope: scraped dashboard series only; OTLP metrics with dotted labels "
          "(for example service.name) are left out because Prometheus has no counterpart.")
    print_table(rows, args.markdown)
    failures = sum(not result.agrees for _, result in rows)
    print(f"\n{len(rows)} queries, {failures} disagreements")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
