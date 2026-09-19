#!/usr/bin/env python3
"""every line inside a recorded ```text block of demo 40's README must exist
verbatim in output/transcript.txt (record.sh's rule).

Rule: a ```text fence is recorded iff one of the three nearest preceding
non-blank lines contains 'recorded' (any case) — those lines are checked.
A fence whose marker says 'not recorded' (any case) is a declared quote
from outside the transcript and is skipped. A fence with NEITHER marker
FAILS: nothing quoted as output may escape the gate by omitting its label.
Empty lines inside a fence are ignored. Comparison is rstrip, so trailing
spaces on either side do not fail.
"""
import re, sys
DEMO = sys.argv[1] if len(sys.argv) > 1 else 'demos/40-shop-mesh-phase0'
readme = open(f'{DEMO}/README.md').read()
tx = {l.rstrip() for l in open(f'{DEMO}/output/transcript.txt')}
# split keeping fences so we can look at the text immediately before each
parts = re.split(r'(```text\n.*?```)', readme, flags=re.S)
bad, unmarked = [], []
for i, part in enumerate(parts):
    if not part.startswith('```text\n'):
        continue
    before = parts[i - 1] if i else ''
    prevs = [l for l in before.splitlines() if l.strip()][-3:]
    line = sum(p.count('\n') for p in parts[:i]) + 1
    if any('not recorded' in l.lower() for l in prevs):
        continue
    if not any('recorded' in l.lower() for l in prevs):
        unmarked.append(line)
        continue
    body = part[len('```text\n'):]
    if body.endswith('```'):
        body = body[:-3]
    for l in body.splitlines():
        if l.strip() and l.rstrip() not in tx:
            bad.append(l.rstrip())
for l in bad:
    print('NOT VERBATIM:', l)
for n in unmarked:
    print(f'UNMARKED ```text fence at line {n}: label it "Recorded …" or "Not recorded …"')
sys.exit(1 if bad or unmarked else 0)
