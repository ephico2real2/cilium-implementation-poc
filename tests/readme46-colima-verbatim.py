#!/usr/bin/env python3
"""every line inside a ```text block of demo 46-colima's README must exist
verbatim in output/transcript.txt (record.sh's rule).

Scope: only the LAST apply in the transcript (from the last
"— demo 46-colima apply" header to the end). Two exceptions, both explicit:

  - the "Runs that did not go to plan" section is matched against the whole
    transcript;
  - a block introduced by "From <page>.md:" is matched against that page.

Every other ```text block is checked, whether or not the word "recorded"
appears above it: the older gate only looked at blocks preceded by
"recorded", so a block that dropped the word could carry a superseded run's
numbers and still pass (demonstrated 2026-09-20 with "20 packets received by
filter", a line from the apply before last).
"""
import os
import re
import sys

HERE = 'demos/46-bgp-fabric-colima'
MARKER = '— demo 46-colima apply'

readme = open(os.path.join(HERE, 'README.md')).read()
lines = open(os.path.join(HERE, 'output/transcript.txt')).read().split('\n')
starts = [i for i, l in enumerate(lines) if l.rstrip().endswith(MARKER)]
last_run = {l.rstrip() for l in lines[starts[-1] if starts else 0:]}
whole = {l.rstrip() for l in lines}

m = re.search(r'^##+ [^\n]*did not go to plan[^\n]*\n.*?(?=^## |\Z)', readme, flags=re.S | re.M)
historic = range(m.start(), m.end()) if m else range(0)

cited = {}


def corpus_for(before):
    """The lines a block may quote, from the three non-empty lines above it."""
    prevs = [l for l in before.splitlines() if l.strip()][-3:]
    for l in prevs:
        cite = re.search(r'From \[?([A-Za-z0-9._-]+\.md)', l)
        if cite:
            page = cite.group(1)
            if page not in cited:
                path = os.path.join(HERE, page)
                cited[page] = ({l.rstrip() for l in open(path).read().split('\n')}
                               if os.path.isfile(path) else set())
            return cited[page], page
    return None, None


bad = []
for fence in re.finditer(r'```text\n(.*?)```', readme, flags=re.S):
    before = readme[:fence.start()]
    cite_lines, page = corpus_for(before)
    if cite_lines is not None:
        allowed, where = cite_lines, page
    elif fence.start() in historic:
        allowed, where = whole, 'transcript (any run)'
    else:
        allowed, where = last_run, 'the last apply'
    for l in fence.group(1).splitlines():
        if l.strip() and l.rstrip() not in allowed:
            bad.append((l.rstrip(), where, l.rstrip() in whole))
for line, where, earlier in bad:
    print('NOT IN %s%s:' % (where, ' (an earlier run)' if earlier else ''), line)
sys.exit(1 if bad else 0)
