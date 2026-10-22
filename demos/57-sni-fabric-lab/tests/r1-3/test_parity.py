#!/usr/bin/env python3
"""Lab-free controls for parity.py's envelopes and its complete-window gate."""
import contextlib
import http.server
import importlib.util
import io
import json
import sys
import threading
import time
import urllib.parse
from pathlib import Path

PARITY = Path(__file__).resolve().parents[1] / "parity.py"
spec = importlib.util.spec_from_file_location("fabric_parity", PARITY)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load {PARITY}")
parity = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = parity
spec.loader.exec_module(parity)


def labels(**values: str) -> tuple[tuple[str, str], ...]:
    return tuple(sorted(values.items()))


def compare(previous, prometheus, following, victoria, rate_query, widened=None,
            victoria_neighbors=None):
    """Call either signature so these controls report old behavior instead of stopping early."""
    try:
        return parity.compare_series(previous, prometheus, following, victoria, rate_query,
                                     widened, victoria_neighbors)
    except TypeError:
        return parity.compare_series(previous, prometheus, following, victoria, rate_query,
                                     widened)


job = labels(job="api")
components = {labels(job=f"job-{number}"): 1.0 for number in range(11)}
cases = [
    # name, P(T-s), P(T), P(T+s), V(T), is rate, want
    ("measured component health: eleven 1/1 pairs", components, components, components,
     components, False, True),
    ("equal gauge", {job: 1.0}, {job: 1.0}, {job: 1.0}, {job: 1.0}, False, True),
    ("measured MQ latency 0.000299/0.000299", {job: 0.000299}, {job: 0.000299},
     {job: 0.000299}, {job: 0.000299}, False, True),
    ("a gauge from between scrapes is not the copied value at T", {job: 0.9}, {job: 1.0},
     {job: 1.1}, {job: 1.05}, False, False),
    ("steady gauge gets no rate allowance", {job: 1.0}, {job: 1.0}, {job: 1.0},
     {job: 1.01}, False, False),
    # The four measured Postgres pairs: s/W alone covers the steady-window difference.
    ("measured postgres 3.372414/3.383333", {job: 3.372414}, {job: 3.372414},
     {job: 3.372414}, {job: 3.383333}, True, True),
    ("measured postgres 3.393103/3.39", {job: 3.393103}, {job: 3.393103},
     {job: 3.393103}, {job: 3.39}, True, True),
    ("measured postgres 3.386207/3.38", {job: 3.386207}, {job: 3.386207},
     {job: 3.386207}, {job: 3.38}, True, True),
    ("measured postgres 3.389655/3.383333", {job: 3.389655}, {job: 3.389655},
     {job: 3.389655}, {job: 3.383333}, True, True),
    # At the edge event, the neighbouring P evaluation supplies the other numerator (4/290,
    # then 5/290); the three later measured pairs are the reverse direction of the same envelope.
    ("measured edge 0.013793/0.016667", {job: 0.013793}, {job: 0.013793},
     {job: 0.017241}, {job: 0.016667}, True, True),
    ("measured edge 0.017241/0.016667", {job: 0.013793}, {job: 0.017241},
     {job: 0.017241}, {job: 0.016667}, True, True),
    ("measured edge repeat 2: 0.017241/0.016667", {job: 0.013793}, {job: 0.017241},
     {job: 0.017241}, {job: 0.016667}, True, True),
    ("measured edge repeat 3: 0.017241/0.016667", {job: 0.013793}, {job: 0.017241},
     {job: 0.017241}, {job: 0.016667}, True, True),
    ("measured equal 1.3/1.3", {job: 1.3}, {job: 1.3}, {job: 1.3},
     {job: 1.3}, True, True),
    ("measured zero rate 1", {job: 0.0}, {job: 0.0}, {job: 0.0}, {job: 0.0}, True, True),
    ("measured zero rate 2", {job: 0.0}, {job: 0.0}, {job: 0.0}, {job: 0.0}, True, True),
    ("measured zero rate 3", {job: 0.0}, {job: 0.0}, {job: 0.0}, {job: 0.0}, True, True),
    ("measured zero rate 4", {job: 0.0}, {job: 0.0}, {job: 0.0}, {job: 0.0}, True, True),
    ("twice Prometheus is wrong", {job: 1.0}, {job: 1.0}, {job: 1.0},
     {job: 2.0}, True, False),
    ("zero when Prometheus is positive is wrong", {job: 1.0}, {job: 1.0}, {job: 1.0},
     {job: 0.0}, True, False),
    ("series only on one side", {job: 1.0}, {job: 1.0}, {job: 1.0},
     {}, True, False),
    ("empty on both sides", {}, {}, {}, {}, True, False),
    # Measured 08:21:07Z: MQ's latency gauge missed one scrape, so both stores lacked it at T only.
    ("gauge absent at T in both, present at T-s and T+s", {job: 0.000282}, {}, {job: 0.000282},
     {}, False, True),
    ("gauge absent at T in both and at T-s and T+s", {}, {}, {}, {}, False, False),
]

# The same, with the rate one interval wider, [310s], at T-s, T and T+s. The first two are live
# lab reads (2026-10-22, T = 1792656829 and 1792656831) that the [5m] envelope alone failed: an
# event in the interval before the window and one in its last interval, nothing between.
steady = {job: 3.372414}
steady_wide = ({job: 3.38}, {job: 3.38}, {job: 3.38})
widened_cases = [
    # name, P(T-s), P(T), P(T+s), V(T), is rate, P[310s] at T-s/T/T+s, want
    ("measured tcp-svc 9/290 thrice, V 10/300", {job: 0.031034482758620693},
     {job: 0.031034482758620693}, {job: 0.031034482758620693}, {job: 0.03333333333333333}, True,
     ({job: 0.03333333333333333}, {job: 0.03333333333333333}, {job: 0.030000000000000002}), True),
    ("measured new connections, V 11/300", {job: 0.03448275862068966},
     {job: 0.024137931034482762}, {job: 0.024137931034482762}, {job: 0.03666666666666667}, True,
     ({job: 0.03666666666666667}, {job: 0.03666666666666667}, {job: 0.023333333333333334}), True),
    ("the wider window rescues no wrong value", steady, steady, steady, {job: 3.6}, True,
     steady_wide, False),
    ("a gauge gets no wider window", {job: 1.0}, {job: 1.0}, {job: 1.0}, {job: 1.2}, False,
     ({job: 1.2}, {job: 1.2}, {job: 1.2}), False),
    ("the wider window needs all three reads", steady, steady, steady, {job: 3.6}, True,
     ({job: 3.6}, {}, {job: 3.6}), False),
    ("a value 3.2 % above the exact expected rate fails", steady, steady, steady, {job: 3.48}, True,
     steady_wide, False),
    ("resolution: 4.4 % above a steady rate fails", steady, steady, steady, {job: 3.52}, True,
     steady_wide, False),
]

failures = 0
for name, previous, prometheus, following, victoria, rate_query, want in cases:
    # Production obtains the expected rate from P[310s](T). Supply the measured value for a
    # positive case and the source value for a deliberately wrong case.
    widened = None
    if rate_query:
        expected = victoria if want else prometheus
        widened = (expected, expected, expected)
    result = compare(previous, prometheus, following, victoria, rate_query,
                     widened, (previous, following))
    if result.agrees == want:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}: got {result.agrees}, want {want} ({result.detail})")
for name, previous, prometheus, following, victoria, rate_query, widened, want in widened_cases:
    try:
        result = compare(previous, prometheus, following, victoria, rate_query,
                         widened, (previous, following))
        got, detail = result.agrees, result.detail
    except TypeError as error:  # a compare_series without the wider window
        got, detail = None, str(error)
    if got == want:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}: got {got}, want {want} ({detail})")

# Wrong store values equal to neighbouring P[310s] evaluations used to pass the second envelope.
wrong_widened_cases = [
    ("one scrape behind", [0.1, 0.1310344827586207, 0.1310344827586207], 0.1,
     [0.1, 0.13, 0.13]),
    ("dropped boundary sample across resets",
     [0.2482758620689655, 0.2482758620689655, 0.24482758620689657],
     0.25806451612903225,
     [0.26333333333333336, 0.24333333333333335, 0.25666666666666665]),
    ("previous scrape duplicated at T",
     [0.3448275862068966, 0.3448275862068966, 0.3448275862068966],
     0.3333333333333333,
     [0.35333333333333333, 0.35333333333333333, 0.3333333333333333]),
]
for name, points, wrong, wide_points in wrong_widened_cases:
    result = compare(
        {job: points[0]}, {job: points[1]}, {job: points[2]}, {job: wrong}, True,
        tuple({job: value} for value in wide_points), ({job: points[0]}, {job: points[2]}))
    if not result.agrees:
        print(f"ok        wrong copy refused: {name}")
    else:
        failures += 1
        print(f"MISMATCH  wrong copy passed: {name} ({result.detail})")

# Rewriting is confined to rate's own range, even in a mixed expression.
mixed = "sum(rate(requests_total[5m])) + avg_over_time(queue_depth[5m])"
rewritten = "sum(rate(requests_total[310s])) + avg_over_time(queue_depth[5m])"
if parity.widened_expression(mixed) == rewritten:
    print("ok        a non-rate [5m] range is not widened")
else:
    failures += 1
    print(f"MISMATCH  mixed expression became {parity.widened_expression(mixed)!r}")

# The readiness gate uses the actual exact comparison. A new/churning label set need not have 32
# samples; a selected rate whose cross-engine values still differ remains named.
selectors = [parity.rate_selectors(expression)
             for _, expression in parity.selected_queries(parity.DEFAULT_DASHBOARD)]
gate_cases = [("eight rate queries, one selector each, two gauges with none",
               sorted(len(found) for found in selectors) == [0, 0] + [1] * 8)]
for shape in ("sum(rate(x[1m]))", "rate(sum(x)[5m:])"):
    try:
        parity.rate_selectors(shape)
        gate_cases.append((f"a rate it cannot read is refused: {shape}", False))
    except ValueError:
        gate_cases.append((f"a rate it cannot read is refused: {shape}", True))


def fake_counts(base: str, expression: str, _timestamp: float):
    if "ibmmq_qmgr_mqput_mqput1_total" in expression and base == "victoria":
        return {(): 1.1}
    return {(): 1.0}


real_query = parity.instant_query
parity.instant_query = fake_counts
try:
    expressions = [f"sum(rate({selector}[5m]))" for found in selectors for selector in found]
    try:
        gaps = parity.incomplete_windows("prometheus", "victoria", expressions, 0.0)
    except TypeError:
        gaps = parity.incomplete_windows("victoria", expressions, 0.0)
finally:
    parity.instant_query = real_query
gate_cases.append(("the one rate not yet exactly comparable is named, nothing else",
                   gaps == ["sum(rate(ibmmq_qmgr_mqput_mqput1_total[5m]))"]))

# A shared gauge hole agrees only if VictoriaMetrics has both neighbouring values too.
shared_gap = compare({job: 0.000282}, {}, {job: 0.000282}, {}, False, None,
                     ({job: 0.000282}, {job: 0.000282}))
lost_copy = compare({job: 0.000282}, {}, {job: 0.000282}, {}, False, None, ({}, {}))
gate_cases.extend([
    ("shared one-scrape gauge hole agrees in both stores", shared_gap.agrees),
    ("a copy that lost the gauge does not use Prometheus's neighbours", not lost_copy.agrees),
])

# Both stores over HTTP, with VictoriaMetrics' latency offset (app/vmselect/prometheus/prometheus.go
# :861): without nocache=1 it evaluates a time within 30 s of its clock at now - 30 s instead.
# Each answer's value is the time it was evaluated at; count_over_time answers as the store holds.
class Stores(http.server.BaseHTTPRequestHandler):
    victoria_counts: dict[str, int] = {}

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        args = dict(urllib.parse.parse_qsl(url.query))
        at, store = float(args["time"]), url.path.split("/")[1]
        if store == "victoria" and args.get("nocache") != "1" and time.time() - at < 30:
            at = time.time() - 30
        series = [({"job": "api"}, at)]
        if args["query"].startswith("count_over_time("):
            series = [({"job": "api"}, 31.0)]
            if store == "victoria":
                series = [(labels_, float(n)) for labels_, n in
                          ((json.loads(k), v) for k, v in Stores.victoria_counts.items())]
        elif args["query"].startswith("max by (job) (up)") or "(up[5m])" in args["query"]:
            series = [({"job": "api"}, 30.0 if "count_over_time" in args["query"] else 1.0)]
        elif "rate(" in args["query"]:
            series = [({}, 1.0)]
        body = json.dumps({"status": "success", "data": {"resultType": "vector", "result": [
            {"metric": m, "value": [at, repr(v)]} for m, v in series]}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stores)
threading.Thread(target=server.serve_forever, daemon=True).start()
stores = f"http://127.0.0.1:{server.server_port}"
asked = time.time() - 20
got = next(iter(parity.instant_query(f"{stores}/victoria", "x", asked).values()))
gate_cases.append(("a VictoriaMetrics read at T+s is evaluated at T+s, not at now - 30 s",
                   abs(got - asked) < 0.01))


def parity_run(victoria_counts):
    """Exit status of parity.py's own main() against the two stores."""
    Stores.victoria_counts = victoria_counts
    argv, sys.argv = sys.argv, ["parity.py", "--prometheus", f"{stores}/prometheus",
                                "--victoriametrics", f"{stores}/victoria"]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return parity.main()
    finally:
        sys.argv = argv


api = json.dumps({"job": "api"})
gate_cases.extend([
    ("every rate's raw samples the same in both stores agree", parity_run({api: 31}) == 0),
    ("a copy that lost an interior sample is refused", parity_run({api: 30}) == 1),
    ("a copy that repeated an interior sample is refused", parity_run({api: 32}) == 1),
    ("a copy with a label renamed under sum() is refused",
     parity_run({json.dumps({"job": "api-renamed"}): 31}) == 1),
])
server.shutdown()

for name, ok in gate_cases:
    if ok:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}")

print(f"mismatches: {failures}")
raise SystemExit(failures)
