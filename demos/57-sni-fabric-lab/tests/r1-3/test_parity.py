#!/usr/bin/env python3
"""Lab-free controls for parity.py's series-and-tolerance comparison."""
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


cases = [
    ("equal", {labels(job="api"): 1.0}, {labels(job="api"): 1.0},
     {labels(job="api"): 0.0}, True),
    ("within tolerance", {labels(job="api"): 1.0}, {labels(job="api"): 1.1},
     {labels(job="api"): 0.2}, True),
    ("outside tolerance", {labels(job="api"): 1.0}, {labels(job="api"): 1.3},
     {labels(job="api"): 0.2}, False),
    ("series only on one side", {labels(job="api"): 1.0}, {},
     {labels(job="api"): 0.0}, False),
    ("empty on both sides", {}, {}, {}, False),
]

failures = 0
for name, prometheus, victoria, movement, want in cases:
    result = parity.compare_series(prometheus, victoria, movement)
    if result.agrees == want:
        print(f"ok        {name}")
    else:
        failures += 1
        print(f"MISMATCH  {name}: got {result.agrees}, want {want} ({result.detail})")

print(f"mismatches: {failures}")
raise SystemExit(failures)
