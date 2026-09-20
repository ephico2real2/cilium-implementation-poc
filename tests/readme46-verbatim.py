#!/usr/bin/env python3
"""every line inside a recorded ```text block of demo 46's README must exist
verbatim in output/transcript.txt (record.sh's rule).

Rule: a ```text fence is recorded iff one of the three nearest preceding
non-blank lines contains 'recorded' (any case). Empty lines inside a fence
are ignored. Comparison is rstrip, so trailing spaces on either side do not
fail.
Scope: only the LAST apply in the transcript (from the last "— demo 46 apply"
header to the end), so a fence quoting an earlier run fails — the rule demo
56 already carries (Codex F4, 2026-09-20). The one exception is the "Runs
that did not go to plan" section, whose fences quote a superseded run on
purpose: those are matched against the whole transcript.
"""
import re, sys

readme = open('demos/46-bgp-fabric/README.md').read()
lines = open('demos/46-bgp-fabric/output/transcript.txt').read().split('\n')
starts = [i for i, l in enumerate(lines) if l.rstrip().endswith('— demo 46 apply')]
last_run = {l.rstrip() for l in lines[starts[-1] if starts else 0:]}
whole = {l.rstrip() for l in lines}

# the section runs from its heading to the next heading of the same or a
# higher level ("## "), or the end of the page; [^\n]* keeps the heading match
# on one line (a bare .* under re.S would swallow the rest of the document)
m = re.search(r'^##+ [^\n]*did not go to plan[^\n]*\n.*?(?=^## |\Z)', readme, flags=re.S | re.M)
historic = range(m.start(), m.end()) if m else range(0)

bad = []
for fence in re.finditer(r'```text\n(.*?)```', readme, flags=re.S):
    before = readme[:fence.start()]
    prevs = [l for l in before.splitlines() if l.strip()][-3:]
    if not any('recorded' in l.lower() for l in prevs):
        continue
    allowed = whole if fence.start() in historic else last_run
    for l in fence.group(1).splitlines():
        if l.strip() and l.rstrip() not in allowed:
            bad.append((l.rstrip(), l.rstrip() in whole))
for line, earlier in bad:
    print('NOT VERBATIM%s:' % (' (an earlier run)' if earlier else ''), line)
sys.exit(1 if bad else 0)
