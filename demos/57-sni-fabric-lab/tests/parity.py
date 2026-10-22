#!/usr/bin/env python3
"""Compare ten representative Grafana queries in Prometheus and VictoriaMetrics.

The ten queries cover every dashboard section and the distinct behaviours a second store must
preserve: current health, accepted and rejected SNI connections, retries, order flow, recovery,
MQ throughput and its latency gauge, Postgres transactions, and TCP commands. They are loaded by
exact panel title and refId from fabric.json; a renamed or missing panel is an error, never an
empty comparison.

Both stores are evaluated at exactly T = now - 30 seconds, so T + one 10-second scrape interval
is in the past. For each exact label set, Prometheus is also evaluated at T-s and T+s. A gauge
or ``up`` value from VictoriaMetrics must lie inside the three Prometheus values' [min, max]
envelope, plus a 1e-9 relative floating-point allowance.

For ``rate`` queries over W=300 seconds a VictoriaMetrics value passes when it lies in either of
two envelopes, each the [min, max] of three Prometheus values plus the float allowance:

- the same expression at T-s, T and T+s, widened on both sides by m*s/W, where m is the largest
  absolute value of the three. Prometheus (v3.15.0 ``promql/functions.go`` ``extrapolatedRate``)
  divides the increase of the samples inside (T-W, T] by W after extrapolating to the range's
  edges, by at most 1.1 average intervals, and only towards zero for a counter that started at
  zero; this envelope covers those counters;
- the expression with its range widened by one interval, ``[W+s]``, at T-s, T and T+s. With
  regular scrapes it covers the same 30 intervals VictoriaMetrics uses: MetricsQL's ``rate``
  takes the last sample before the window as its start (v1.153.0
  ``app/vmselect/promql/rollup.go`` ``rollupDerivFast``, prevValue at lines 779-783) and divides
  by the time between that sample and the last one. Without it, one event in the interval before
  the window and one in the last interval put V above every [5m] value by more than m*s/W:
  measured on the lab, tcp-svc P = 9/290 at T-s, T and T+s, V = 10/300.

The comparison is only defined over a window with every scrape in it. A target that is down
leaves a gap Prometheus bridges with a counter reset and VictoriaMetrics restarts from (rollup.go
``removeCounterResets``, lines 940-947), so ``--window-ready`` requires every series of every
rate selector to hold all (W+2s)/s samples of (T-W-2s, T] in both stores. ``up`` alone cannot
show it: it is written on every scrape, a failed one included.

Resolution: in a steady window, a VictoriaMetrics rate within about s/W (3.3 %) of Prometheus's
passes; the controls in tests/r1-3/test_parity.py pin that boundary.

Only the dashboard's Prometheus-scraped metrics are selected. OTLP-ingested metrics in
VictoriaMetrics retain dotted resource labels such as ``service.name``; they have no Prometheus
counterpart and are deliberately outside this comparison.

Usage: python3 tests/parity.py [dashboard.json] [--prometheus URL]
       [--victoriametrics URL] [--markdown] [--window-ready]
"""
from __future__ import annotations

import argparse
import json
import math
import re
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DASHBOARD = (Path(__file__).resolve().parent.parent
                     / "observability/grafana/dashboards/fabric.json")
SCRAPE_INTERVAL_SECONDS = 10
EVALUATION_MARGIN_SECONDS = 30
RATE_WINDOW_SECONDS = 300
FLOAT_ALLOWANCE = 1e-9
MIN_WINDOW_SAMPLES = RATE_WINDOW_SECONDS // SCRAPE_INTERVAL_SECONDS
WIDE_RANGE = f"[{RATE_WINDOW_SECONDS + SCRAPE_INTERVAL_SECONDS}s]"
# A rate's own samples, from P(T-s)'s first interval to T: one per scrape, none missing.
GATE_SPAN_SECONDS = RATE_WINDOW_SECONDS + 2 * SCRAPE_INTERVAL_SECONDS
MIN_GATE_SAMPLES = GATE_SPAN_SECONDS // SCRAPE_INTERVAL_SECONDS
RATE_SELECTOR = re.compile(r"\brate\(\s*([^()\[\]]+?)\s*\[5m\]\s*\)")

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


def compare_series(previous: Series, prometheus: Series, following: Series,
                   victoria: Series, rate_query: bool,
                   widened: tuple[Series, Series, Series] | None = None) -> Comparison:
    """Compare V(T) with P(T-s,T,T+s), adding m*s/W only for a rate query.

    ``widened`` is the rate with its range one interval wider at T-s, T and T+s; a series also
    agrees when V(T) lies within those three values.
    """
    prometheus_labels = set(prometheus)
    victoria_labels = set(victoria)
    if not prometheus_labels and not victoria_labels:
        if previous or following:
            # MQ's consume-on-read gauges miss a scrape now and then, with one scraper too
            # (measured 2026-10-22): both stores then share the gap and the query is there at T±s.
            return Comparison(True, 0, 0, None, None, "absent at T in both stores, present at T±s")
        return Comparison(False, 0, 0, None, None, "no series in either store")
    if prometheus_labels != victoria_labels:
        only_prometheus = prometheus_labels - victoria_labels
        only_victoria = victoria_labels - prometheus_labels
        detail = (f"label sets differ: Prometheus-only={len(only_prometheus)}, "
                  f"VictoriaMetrics-only={len(only_victoria)}")
        return Comparison(False, len(prometheus), len(victoria), None, None, detail)

    differences: list[float] = []
    tolerances: list[float] = []
    outside = wide_only = 0
    for labels in sorted(prometheus_labels):
        current = prometheus[labels]
        right = victoria[labels]
        points = (previous.get(labels, current), current, following.get(labels, current))
        if not all(math.isfinite(value) for value in (*points, right)):
            return Comparison(False, len(prometheus), len(victoria), None, None,
                              "a value in the comparison envelope is not finite")
        scale = max(*(abs(value) for value in points), abs(right))
        float_allowance = FLOAT_ALLOWANCE * scale
        rate_allowance = (max(abs(value) for value in points)
                          * SCRAPE_INTERVAL_SECONDS / RATE_WINDOW_SECONDS
                          if rate_query else 0.0)
        lower = min(points) - rate_allowance - float_allowance
        upper = max(points) + rate_allowance + float_allowance
        tolerance = max(abs(current - lower), abs(upper - current))
        difference = abs(current - right)
        differences.append(difference)
        tolerances.append(tolerance)
        if lower <= right <= upper:
            continue
        wide = [series[labels] for series in widened or () if labels in series]
        if (rate_query and len(wide) == 3 and all(math.isfinite(value) for value in wide)
                and min(wide) - float_allowance <= right <= max(wide) + float_allowance):
            wide_only += 1
            continue
        outside += 1

    maximum = max(differences)
    # Report the allowance for the same series that produced the maximum difference.
    max_tolerance = tolerances[differences.index(maximum)]
    if outside:
        return Comparison(False, len(prometheus), len(victoria), maximum, max_tolerance,
                          f"{outside} series outside the one-scrape envelope")
    detail = "within the one-scrape envelope"
    if wide_only:
        detail += f"; {wide_only} series within the {WIDE_RANGE} rate instead"
    return Comparison(True, len(prometheus), len(victoria), maximum, max_tolerance, detail)


def is_rate_query(expression: str) -> bool:
    """Return whether the selected expression uses the rate semantics described above."""
    return re.search(r"\brate\s*\(", expression) is not None


def rate_selectors(expression: str) -> list[str]:
    """Return the series selector of every ``rate(<selector>[5m])``; a rate of another shape fails."""
    selectors = RATE_SELECTOR.findall(expression)
    if is_rate_query(expression) and len(selectors) != len(re.findall(r"\brate\s*\(", expression)):
        raise ValueError(f"cannot read the rate selector of {expression!r}")
    return selectors


def widened_expression(expression: str) -> str:
    """Return the expression with each [5m] range one scrape interval wider."""
    if "[5m]" not in expression:
        raise ValueError(f"rate query without a [5m] range: {expression!r}")
    return expression.replace("[5m]", WIDE_RANGE)


def incomplete_windows(base: str, expressions: list[str], timestamp: float) -> list[str]:
    """Name each rate selector whose least-sampled series lacks a scrape in (T-W-2s, T]."""
    shortfalls = []
    for selector in sorted({s for e in expressions for s in rate_selectors(e)}):
        values = instant_query(
            base, f"min(count_over_time({selector}[{GATE_SPAN_SECONDS}s]))", timestamp)
        count = next(iter(values.values()), 0.0)
        if count < MIN_GATE_SAMPLES:
            shortfalls.append(f"{selector}: {count:g} of {MIN_GATE_SAMPLES} samples")
    return shortfalls


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


def full_window_samples(base: str, timestamp: float) -> int:
    """Return the least number of raw up samples held for any job in the five-minute window."""
    values = instant_query(base, "min(count_over_time(up[5m]))", timestamp)
    if len(values) != 1:
        raise ValueError(f"full-window gate returned {len(values)} series")
    value = next(iter(values.values()))
    if value < 0 or not value.is_integer():
        raise ValueError(f"full-window gate returned invalid sample count {value}")
    return int(value)


def verdict_text(result: Comparison) -> str:
    """PASS, naming the wider window when it decided; FAIL with the reason."""
    if not result.agrees:
        return f"FAIL: {result.detail}"
    return "PASS" if "instead" not in result.detail else f"PASS ({result.detail.split('; ', 1)[1]})"


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
            verdict = verdict_text(result)
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
        verdict = verdict_text(result)
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
    parser.add_argument("--window-ready", action="store_true",
                        help="only require both stores to hold a complete five-minute up window")
    args = parser.parse_args()

    evaluation_time = time.time() - EVALUATION_MARGIN_SECONDS
    if args.window_ready:
        try:
            prometheus_samples = full_window_samples(args.prometheus, evaluation_time)
            victoria_samples = full_window_samples(args.victoriametrics, evaluation_time)
            expressions = [expression for _, expression in selected_queries(Path(args.dashboard))]
            shortfalls = [f"{name}: {gap}" for name, base in
                          (("Prometheus", args.prometheus), ("VictoriaMetrics", args.victoriametrics))
                          for gap in incomplete_windows(base, expressions, evaluation_time)]
        except Exception as error:
            print(f"rate window not ready: {error}")
            return 1
        print(f"rate window samples at T: Prometheus={prometheus_samples}, "
              f"VictoriaMetrics={victoria_samples}; need at least {MIN_WINDOW_SAMPLES}")
        for shortfall in shortfalls:
            print(f"rate window incomplete: {shortfall}")
        ready = min(prometheus_samples, victoria_samples) >= MIN_WINDOW_SAMPLES and not shortfalls
        return 0 if ready else 1

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
            following = instant_query(args.prometheus, expression,
                                      evaluation_time + SCRAPE_INTERVAL_SECONDS)
            widened = None
            if is_rate_query(expression):
                wide = widened_expression(expression)
                widened = tuple(instant_query(args.prometheus, wide, evaluation_time + offset)
                                for offset in (-SCRAPE_INTERVAL_SECONDS, 0,
                                               SCRAPE_INTERVAL_SECONDS))
            result = compare_series(previous, prometheus, following, victoria,
                                    is_rate_query(expression), widened)
        except Exception as error:  # Keep all ten rows visible when one endpoint or query fails.
            result = Comparison(False, 0, 0, None, None, f"query error: {error}")
        rows.append((title, result))

    print(f"Evaluation timestamp: {evaluation_time:.3f} (now - {EVALUATION_MARGIN_SECONDS}s; "
          f"scrape interval {SCRAPE_INTERVAL_SECONDS}s; rate window {RATE_WINDOW_SECONDS}s)")
    print("Scope: scraped dashboard series only; OTLP metrics with dotted labels "
          "(for example service.name) are left out because Prometheus has no counterpart.")
    print_table(rows, args.markdown)
    failures = sum(not result.agrees for _, result in rows)
    print(f"\n{len(rows)} queries, {failures} disagreements")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
