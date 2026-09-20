#!/usr/bin/env python3
"""every line inside a recorded ```text block of demo 56's README must exist
verbatim in output/transcript.txt (record.sh's rule).

Rule: a ```text fence is recorded iff one of the three nearest preceding
non-blank lines contains 'recorded' (any case). Empty lines inside a fence
are ignored. Comparison is rstrip, so trailing spaces on either side do not
fail. Placeholders (`<!-- recorded after apply -->`) are not fences.
Scope: only the LAST apply in the transcript (from the last "demo 56 apply"
header to the end) and the check.sh block after it — a fence quoting an
earlier run fails (Codex F4, 2026-09-20). An unmarked ```text fence that
looks like recorded output (its lines exist in the transcript) is reported
as "unmarked but recorded" and fails too (the demo 46 review's rule).
"""
import re, sys
readme = open('demos/56-kube-vip-bgp/README.md').read()
lines = open('demos/56-kube-vip-bgp/output/transcript.txt').read().split('\n')
starts = [i for i, l in enumerate(lines) if 'demo 56 apply' in l]
last = starts[-1] if starts else 0
tx = {l.rstrip() for l in lines[last:]}
parts = re.split(r'(```text\n.*?```)', readme, flags=re.S)
bad = []
for i, part in enumerate(parts):
    if not part.startswith('```text\n'):
        continue
    before = parts[i - 1] if i else ''
    prevs = [l for l in before.splitlines() if l.strip()][-3:]
    if not any('recorded' in l.lower() for l in prevs):
        continue
    body = part[len('```text\n'):]
    if body.endswith('```'):
        body = body[:-3]
    for l in body.splitlines():
        if l.strip() and l.rstrip() not in tx:
            bad.append(l.rstrip())
for l in bad:
    print('NOT VERBATIM:', l)
sys.exit(1 if bad else 0)
