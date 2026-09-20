#!/usr/bin/env python3
"""demo 46 claims after the adversarial-review fixes (A1–A4, A8, A9).

  - no ttl-security on the SERVERS group in the leaf configs or the pages
  - the MD5 sentence (TCP_MD5SIG refused) present in the sheet, README and plan §7
  - the per-cluster lists present
  - maximum-paths 8 on the leaves
  - .env ignored and .env.example present
usage: python3 tests/demo46-claims.py   (exit 0 = pass)
"""
from pathlib import Path
import sys

root = Path("demos/46-bgp-fabric")
bad = []

# A1 — no GTSM on SERVERS in leaf configs; no page promises hops 1
for p in (
    root / "fabric/frr/leaf1/frr.conf",
    root / "fabric/frr/leaf2/frr.conf",
):
    text = p.read_text()
    if "neighbor SERVERS ttl-security" in text:
        bad.append("%s SERVERS still has ttl-security" % p)
for p in (
    root / "RECAP.md",
    root / "NETWORK-TEAM-SHEET.md",
    root / "README.md",
    root / "GUIDE.md",
):
    text = p.read_text()
    if "ttl-security hops 1" in text:
        bad.append("%s still promises ttl-security hops 1" % p)

# A2 — MD5 sentence in the sheet, README and plan §7
for p in (
    root / "NETWORK-TEAM-SHEET.md",
    root / "README.md",
    Path("enhancements/006-bgp-tutorial.md"),
):
    text = p.read_text()
    if "TCP_MD5SIG" not in text:
        bad.append("%s lacks the TCP_MD5SIG sentence" % p)

# A3 — per-cluster lists on both leaves
for leaf in ("leaf1", "leaf2"):
    config = (root / "fabric/frr" / leaf / "frr.conf").read_text()
    for line in (
        "ip prefix-list EG-POC1-VIPS seq 10 permit 10.98.0.0/26 ge 32 le 32",
        "ip prefix-list EG-POC2-VIPS seq 10 permit 10.98.0.64/26 ge 32 le 32",
        "ip prefix-list EG-ANYCAST-VIPS seq 10 permit 10.98.0.192/26 ge 32 le 32",
        "ip prefix-list CILIUM-POC1-VIPS seq 10 permit 10.99.0.0/26 ge 32 le 32",
        "ip prefix-list CILIUM-POC2-VIPS seq 10 permit 10.99.0.64/26 ge 32 le 32",
        "ip prefix-list CILIUM-ANYCAST-VIPS seq 10 permit 10.99.0.192/26 ge 32 le 32",
    ):
        if line not in config:
            bad.append("%s/%s lacks %s" % (leaf, "frr.conf", line))

# A4 — maximum-paths 8 on the leaves
for leaf in ("leaf1", "leaf2"):
    config = (root / "fabric/frr" / leaf / "frr.conf").read_text()
    if "\n maximum-paths 8\n" not in config:
        bad.append("%s lacks ' maximum-paths 8'" % leaf)

# A8 — .env ignored, .env.example present
gitignore = Path(".gitignore").read_text()
if "demos/46-bgp-fabric/fabric/.env" not in gitignore:
    bad.append(".gitignore does not ignore fabric/.env")
if not (root / "fabric/.env.example").is_file():
    bad.append("fabric/.env.example missing")

for b in bad:
    print("CLAIM FAIL:", b)
sys.exit(1 if bad else 0)
