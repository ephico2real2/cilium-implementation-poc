#!/usr/bin/env python3
"""Compare ten representative Grafana queries in Prometheus and VictoriaMetrics.

The ten queries cover every dashboard section and the distinct behaviours a second store must
preserve: current health, accepted and rejected SNI connections, retries, order flow, recovery,
MQ throughput and its latency gauge, Postgres transactions, and TCP commands. They are loaded by
exact panel title and refId from fabric.json; a renamed or missing panel is an error, never an
empty comparison.

Both stores are evaluated at exactly T = now - 30 seconds. A gauge or ``up`` value must match at
T, plus a 1e-9 relative floating-point allowance. If a consume-on-read MQ gauge is absent at T in
both stores, both stores must contain the same series and value at T-s and T+s; an empty query or
a series missing from the copy therefore cannot pass.

For a ``rate`` query over W=300 seconds, Prometheus evaluates the same expression with only the
``rate`` range widened by one regular scrape interval, ``[W+s]``, at T. That value is the exact
MetricsQL result from the same regular samples: MetricsQL includes the last sample at or before
the left edge, while Prometheus's widened range includes that sample and extrapolates its sampled
interval over W+s. The values at T-s and T+s belong to different windows and are not an
allowance: accepting either would hide a store one scrape behind. ``--window-ready`` waits until
this exact cross-engine comparison succeeds for every selected rate. It is not defined while a
series is younger than the window, while a counter's window starts at zero before its first
increase (Prometheus stops extrapolating at the zero point), or while a target's outage crosses
the window's edge; a label set that keeps changing would therefore hold the gate until it times
out.

A rate reads only each series' first and last sample, so for every selected rate the number of
raw samples in (T-W-s, T] must also match per label set: a copy that lost or repeated an
interior sample, or renamed a label the query aggregates away, would otherwise pass.

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
RATE_SELECTOR = re.compile(
    r"(?P<prefix>\brate\(\s*)(?P<selector>[^()\[\]]+?)(?P<range>\s*\[5m\])(?P<suffix>\s*\))")

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


def series_match(left: Series, right: Series) -> bool:
    """Return whether two instant vectors have the same finite values within float noise."""
    if set(left) != set(right):
        return False
    for labels, left_value in left.items():
        right_value = right[labels]
        if not math.isfinite(left_value) or not math.isfinite(right_value):
            return False
        allowance = FLOAT_ALLOWANCE * max(abs(left_value), abs(right_value))
        if abs(left_value - right_value) > allowance:
            return False
    return True


def compare_series(previous: Series, prometheus: Series, following: Series,
                   victoria: Series, rate_query: bool,
                   widened: tuple[Series, Series, Series] | None = None,
                   victoria_neighbors: tuple[Series, Series] | None = None) -> Comparison:
    """Compare V(T) with P(T), or with the exact P[W+s](T) MetricsQL rate equivalent."""
    prometheus_labels = set(prometheus)
    victoria_labels = set(victoria)
    if not prometheus_labels and not victoria_labels:
        if (previous and following and victoria_neighbors is not None
                and series_match(previous, victoria_neighbors[0])
                and series_match(following, victoria_neighbors[1])):
            # MQ's consume-on-read gauges miss a scrape now and then, with one scraper too.
            return Comparison(True, 0, 0, None, None,
                              "absent at T in both stores; both agree at T±s")
        return Comparison(False, 0, 0, None, None, "no series in either store")
    if prometheus_labels != victoria_labels:
        only_prometheus = prometheus_labels - victoria_labels
        only_victoria = victoria_labels - prometheus_labels
        detail = (f"label sets differ: Prometheus-only={len(only_prometheus)}, "
                  f"VictoriaMetrics-only={len(only_victoria)}")
        return Comparison(False, len(prometheus), len(victoria), None, None, detail)

    expected = prometheus
    if rate_query:
        if widened is None:
            return Comparison(False, len(prometheus), len(victoria), None, None,
                              "rate comparison has no widened Prometheus value")
        expected = widened[1]
        if set(expected) != prometheus_labels:
            return Comparison(False, len(prometheus), len(victoria), None, None,
                              "the widened rate has different label sets at T")

    differences: list[float] = []
    tolerances: list[float] = []
    outside = 0
    for labels in sorted(prometheus_labels):
        current = prometheus[labels]
        right = victoria[labels]
        want = expected[labels]
        if not all(math.isfinite(value) for value in (current, want, right)):
            return Comparison(False, len(prometheus), len(victoria), None, None,
                              "a value in the comparison is not finite")
        scale = max(abs(current), abs(want), abs(right))
        float_allowance = FLOAT_ALLOWANCE * scale
        # Report what is checked: VictoriaMetrics' distance from the expected value, against float
        # noise (for a rate, the expected value is Prometheus's [W+s] rate, not its [5m] one).
        difference = abs(want - right)
        differences.append(difference)
        tolerances.append(float_allowance)
        if difference > float_allowance:
            outside += 1

    maximum = max(differences)
    # Report the allowance for the same series that produced the maximum difference.
    max_tolerance = tolerances[differences.index(maximum)]
    if outside:
        return Comparison(False, len(prometheus), len(victoria), maximum, max_tolerance,
                          f"{outside} series differ from the expected value at T")
    detail = f"matches Prometheus {WIDE_RANGE} at T" if rate_query else "matches at T"
    return Comparison(True, len(prometheus), len(victoria), maximum, max_tolerance, detail)


def is_rate_query(expression: str) -> bool:
    """Return whether the selected expression uses the rate semantics described above."""
    return re.search(r"\brate\s*\(", expression) is not None


def rate_selectors(expression: str) -> list[str]:
    """Return the series selector of every ``rate(<selector>[5m])``; a rate of another shape fails."""
    selectors = [match.group("selector").strip() for match in RATE_SELECTOR.finditer(expression)]
    if is_rate_query(expression) and len(selectors) != len(re.findall(r"\brate\s*\(", expression)):
        raise ValueError(f"cannot read the rate selector of {expression!r}")
    return selectors


def widened_expression(expression: str) -> str:
    """Widen only ``[5m]`` ranges directly owned by ``rate`` calls."""
    # Validate first: an unsupported rate shape must not be partly rewritten.
    rate_selectors(expression)
    return RATE_SELECTOR.sub(
        lambda match: (match.group("prefix") + match.group("selector") + WIDE_RANGE
                       + match.group("suffix")), expression)


def raw_samples_differ(prometheus_base: str, victoria_base: str, expression: str,
                       timestamp: float) -> list[str]:
    """Name each rate selector whose raw samples in (T-W-s, T] differ in count or label set."""
    differ = []
    for selector in rate_selectors(expression):
        counts = f"count_over_time({selector}{WIDE_RANGE})"
        if not series_match(instant_query(prometheus_base, counts, timestamp),
                            instant_query(victoria_base, counts, timestamp)):
            differ.append(selector)
    return differ


def incomplete_windows(prometheus_base: str, victoria_base: str,
                       expressions: list[str], timestamp: float) -> list[str]:
    """Name rates whose exact cross-engine equivalent is not ready at T."""
    shortfalls = []
    for expression in expressions:
        if not is_rate_query(expression):
            continue
        # Validation is shared with the real comparison and also prevents widening an unrelated
        # [5m] range in a mixed expression.
        rate_selectors(expression)
        expected = instant_query(prometheus_base, widened_expression(expression), timestamp)
        actual = instant_query(victoria_base, expression, timestamp)
        if not series_match(expected, actual):
            shortfalls.append(expression)
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
    # nocache=1: VictoriaMetrics otherwise evaluates any time within -search.latencyOffset (30 s)
    # of its clock at now - 30 s instead (app/vmselect/prometheus/prometheus.go:861), so the T+s
    # read would be one of T. Prometheus ignores the argument.
    url = f"{base.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode(
        {"query": expression, "time": f"{timestamp:.3f}", "nocache": "1"})
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
        print("| Query | Prometheus series | VictoriaMetrics series | Max difference from the expected value | Verdict |")
        print("|---|---:|---:|---:|---|")
        for name, result in rows:
            difference = format_number(result.max_difference)
            if result.max_tolerance is not None:
                difference += f" (allowed {format_number(result.max_tolerance)})"
            verdict = verdict_text(result)
            print(f"| {name} | {result.prometheus_series} | {result.victoria_series} | "
                  f"{difference} | {verdict} |")
        return

    widths = (58, 10, 15, 30)
    print(f"{'query':{widths[0]}}  {'Prometheus':>{widths[1]}}  "
          f"{'VictoriaMetrics':>{widths[2]}}  {'max difference from expected':>{widths[3]}}  verdict")
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
                        help="only check readiness: a complete five-minute up window in both "
                             "stores and every selected rate exactly comparable")
    args = parser.parse_args()

    evaluation_time = time.time() - EVALUATION_MARGIN_SECONDS
    if args.window_ready:
        try:
            prometheus_samples = full_window_samples(args.prometheus, evaluation_time)
            victoria_samples = full_window_samples(args.victoriametrics, evaluation_time)
            expressions = [expression for _, expression in selected_queries(Path(args.dashboard))]
            shortfalls = incomplete_windows(
                args.prometheus, args.victoriametrics, expressions, evaluation_time)
        except Exception as error:
            print(f"rate window not ready: {error}")
            return 1
        print(f"rate window samples at T: Prometheus={prometheus_samples}, "
              f"VictoriaMetrics={victoria_samples}; need at least {MIN_WINDOW_SAMPLES}")
        for shortfall in shortfalls:
            print(f"rate window not comparable at T: {shortfall}")
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
            victoria_previous = instant_query(args.victoriametrics, expression,
                                               evaluation_time - SCRAPE_INTERVAL_SECONDS)
            victoria_following = instant_query(args.victoriametrics, expression,
                                                evaluation_time + SCRAPE_INTERVAL_SECONDS)
            widened = None
            if is_rate_query(expression):
                wide = widened_expression(expression)
                widened = tuple(instant_query(args.prometheus, wide, evaluation_time + offset)
                                for offset in (-SCRAPE_INTERVAL_SECONDS, 0,
                                               SCRAPE_INTERVAL_SECONDS))
            result = compare_series(previous, prometheus, following, victoria,
                                    is_rate_query(expression), widened,
                                    (victoria_previous, victoria_following))
            differ = (raw_samples_differ(args.prometheus, args.victoriametrics, expression,
                                         evaluation_time)
                      if result.agrees and is_rate_query(expression) else [])
            if differ:
                result = Comparison(False, result.prometheus_series, result.victoria_series,
                                    result.max_difference, result.max_tolerance,
                                    f"raw samples in {WIDE_RANGE} differ: {', '.join(differ)}")
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
