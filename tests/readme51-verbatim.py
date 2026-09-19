#!/usr/bin/env python3
"""every line inside a recorded ```text block of demo 51's README must exist
verbatim in output/transcript.txt (record.sh's rule).

Rule: a ```text fence is recorded iff one of the three nearest preceding
non-blank lines contains 'recorded' (any case). Empty lines inside a fence
are ignored. Comparison is rstrip, so trailing spaces on either side do
not fail.
"""
import re, sys
readme = open('demos/51-eg-kube-vip/README.md').read()
tx = {l.rstrip() for l in open('demos/51-eg-kube-vip/output/transcript.txt')}
# split keeping fences so we can look at the text immediately before each
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
