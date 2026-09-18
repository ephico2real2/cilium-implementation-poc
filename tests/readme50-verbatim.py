#!/usr/bin/env python3
"""every line inside a ```text block of demo 50's README must exist verbatim in output/transcript.txt (record.sh's rule)."""
import re, sys
readme = open('demos/50-eg-clusters/README.md').read()
tx = {l.rstrip() for l in open('demos/50-eg-clusters/output/transcript.txt')}
bad = [l.rstrip() for b in re.findall(r'```text\n(.*?)```', readme, re.S) for l in b.splitlines() if l.strip() and l.rstrip() not in tx]
for l in bad: print('NOT VERBATIM:', l)
sys.exit(1 if bad else 0)
