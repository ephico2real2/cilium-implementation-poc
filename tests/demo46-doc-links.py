#!/usr/bin/env python3
"""test: every relative link on demo 46's pages resolves.

The fabric's dashboard and router agent moved to ephico2real2/bgp-fabric and
their directories were deleted here. A row that still links `dashboard/` is
two failures at once: a dead link, and a page telling a reader the code is in
a place it is not. Grepping for the old paths finds the ones spelled in full;
this resolves every link, so a path built as `[x](y/)` or reached by `../`
cannot hide.

A target git ignores is skipped: `fabric/.env` is a file the reader creates
from `.env.example`, and the page is right to name it.

usage: python3 tests/demo46-doc-links.py   (exit 0 = pass)
"""
import re
import subprocess
import sys
from pathlib import Path

DEMOS = ("demos/46-bgp-fabric", "demos/46-bgp-fabric-colima")
bad = []


def ignored(path):
    return subprocess.run(
        ["git", "check-ignore", "-q", str(path)],
        stderr=subprocess.DEVNULL,
    ).returncode == 0


for demo in DEMOS:
    root = Path(demo)
    if not root.is_dir():
        bad.append("%s does not exist" % demo)
        continue
    for page in sorted(root.glob("*.md")):
        for target in re.findall(r"\]\(([^()\s]+)\)", page.read_text(encoding="utf-8")):
            t = target.split("#", 1)[0]
            if not t or "://" in t or t.startswith(("mailto:", "/")):
                continue
            dest = page.parent / t
            if dest.exists() or ignored(dest):
                continue
            bad.append("%s links %s — it does not exist" % (page, target))

if bad:
    print("TEST FAIL: demo 46 pages link to things that are not there")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print("TEST PASS: every relative link on demo 46's pages resolves")
