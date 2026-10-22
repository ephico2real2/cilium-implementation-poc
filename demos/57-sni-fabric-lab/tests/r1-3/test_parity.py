#!/usr/bin/env python3
"""Lab-free controls for parity.py's three-point series-envelope comparison."""
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
]

failures = 0
for name, previous, prometheus, following, victoria, rate_query, want in cases:
    result = parity.compare_series(previous, prometheus, following, victoria, rate_query)
    if result.agrees == want:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}: got {result.agrees}, want {want} ({result.detail})")

print(f"mismatches: {failures}")
raise SystemExit(failures)
