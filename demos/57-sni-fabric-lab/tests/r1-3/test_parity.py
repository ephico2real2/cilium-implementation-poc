#!/usr/bin/env python3
"""Lab-free controls for parity.py's envelopes and its complete-window gate."""
import importlib.util
import sys
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


job = labels(job="api")
components = {labels(job=f"job-{number}"): 1.0 for number in range(11)}
cases = [
    # name, P(T-s), P(T), P(T+s), V(T), is rate, want
    ("measured component health: eleven 1/1 pairs", components, components, components,
     components, False, True),
    ("equal gauge", {job: 1.0}, {job: 1.0}, {job: 1.0}, {job: 1.0}, False, True),
    ("measured MQ latency 0.000299/0.000299", {job: 0.000299}, {job: 0.000299},
     {job: 0.000299}, {job: 0.000299}, False, True),
    ("gauge within one scrape's movement", {job: 0.9}, {job: 1.0}, {job: 1.1},
     {job: 1.05}, False, True),
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
    # The resolution the docstring states: within about s/W of a steady rate passes, beyond fails.
    ("resolution: 3.2 % above a steady rate passes", steady, steady, steady, {job: 3.48}, True,
     steady_wide, True),
    ("resolution: 4.4 % above a steady rate fails", steady, steady, steady, {job: 3.52}, True,
     steady_wide, False),
]

failures = 0
for name, previous, prometheus, following, victoria, rate_query, want in cases:
    result = parity.compare_series(previous, prometheus, following, victoria, rate_query)
    if result.agrees == want:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}: got {result.agrees}, want {want} ({result.detail})")
for name, previous, prometheus, following, victoria, rate_query, widened, want in widened_cases:
    try:
        result = parity.compare_series(previous, prometheus, following, victoria, rate_query,
                                       widened)
        got, detail = result.agrees, result.detail
    except TypeError as error:  # a compare_series without the wider window
        got, detail = None, str(error)
    if got == want:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}: got {got}, want {want} ({detail})")

# The window gate: every rate selector is read, and one with a gap is named. The MQ count is the
# live one at T = 1792656830, 60 s after MQ stopped, when min(count_over_time(up[5m])) was 30.
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


def fake_counts(_base: str, expression: str, _timestamp: float):
    return {(): 26.0 if "ibmmq_qmgr_mqput_mqput1_total" in expression else 32.0}


real_query = parity.instant_query
parity.instant_query = fake_counts
try:
    gaps = parity.incomplete_windows("http://unused", [e for found in selectors for e in found
                                                       for e in [f"sum(rate({e}[5m]))"]], 0.0)
finally:
    parity.instant_query = real_query
gate_cases.append(("a gap in MQ's counter is named, nothing else",
                   gaps == ["ibmmq_qmgr_mqput_mqput1_total: 26 of 32 samples"]))
for name, ok in gate_cases:
    if ok:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}")

print(f"mismatches: {failures}")
raise SystemExit(failures)
