#!/usr/bin/env python3
"""demo 46-colima claims: TCP MD5 is enforced on the Colima VM.

  - no ttl-security on the SERVERS group in the leaf configs or the pages
  - MD5 is signed: wire count AND mismatch on every page that claims it
  - the per-cluster lists present
  - maximum-paths 8 on the leaves
  - .env ignored and .env.example present
  - last apply timestamp and this-run numbers on the pages
usage: python3 tests/demo46-colima-claims.py   (exit 0 = pass)
"""
from pathlib import Path
import sys

root = Path("demos/46-bgp-fabric-colima")
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

# A2 — MD5 enforcement: TCP_MD5SIG + wire + mismatch on sheet, README, RECAP
for p in (
    root / "NETWORK-TEAM-SHEET.md",
    root / "README.md",
    root / "RECAP.md",
):
    text = p.read_text()
    if "TCP_MD5SIG" not in text:
        bad.append("%s lacks the TCP_MD5SIG sentence" % p)
    if "md5-option packets=18" not in text and "18 packets" not in text:
        if "md5-option packets=18" not in text:
            bad.append("%s lacks the wire count (md5-option packets=18)" % p)
    if "Established→Idle" not in text:
        bad.append("%s lacks the mismatch (Established→Idle)" % p)

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
if "demos/46-bgp-fabric-colima/fabric/.env" not in gitignore:
    bad.append(".gitignore does not ignore fabric/.env")
if not (root / "fabric/.env.example").is_file():
    bad.append("fabric/.env.example missing")

# no Desktop overlay in this directory
if (root / "fabric/compose.lan-eg.yaml").exists():
    bad.append("compose.lan-eg.yaml present — this phase is the fabric alone")
if (root / "fabric/compose.lan-cilium.yaml").exists():
    bad.append("compose.lan-cilium.yaml present — this phase is the fabric alone")

dash = (root / "dashboard/README.md").read_text()
if "gergovadasz.hu/make-bgp-visible" not in dash:
    bad.append("dashboard/README.md does not credit the blog")
if "No auth" not in dash and "no auth" not in dash:
    bad.append("dashboard/README.md does not say no auth")
if "fabric networks are the boundary" not in dash:
    bad.append("dashboard/README.md does not say the fabric networks are the boundary")
if "8098" not in dash:
    bad.append("dashboard/README.md does not publish 8098")

sheet = (root / "NETWORK-TEAM-SHEET.md").read_text()
if "10.200.200.0/24" not in sheet or "10.200.200.100" not in sheet:
    bad.append("NETWORK-TEAM-SHEET.md lacks the management LAN")
if "sessions run unsigned" in sheet:
    bad.append("NETWORK-TEAM-SHEET.md still says sessions run unsigned")

tx = Path("demos/46-bgp-fabric-colima/output/transcript.txt").read_text()
tx_lines = tx.split("\n")
apply_starts = [i for i, l in enumerate(tx_lines) if l.endswith("— demo 46-colima apply")]
if not apply_starts:
    bad.append("no '— demo 46-colima apply' header in the transcript")
final = "\n".join(tx_lines[apply_starts[-1]:]) if apply_starts else tx
last_apply_ts = tx_lines[apply_starts[-1]].split()[1] if apply_starts else ""
for page in ("README.md", "RECAP.md"):
    page_text = (root / page).read_text()
    if last_apply_ts and last_apply_ts not in page_text:
        bad.append("%s does not cite the last apply %s" % (page, last_apply_ts))
for needle in (
    "dashboard showed the drop after 2.04 s",
    "dashboard confirmed recovery after 0.67 s (polled after the screenshots)",
    "recovered=yes window=2.002 s",
    "client0_rc=28,28,28,28",
    "10.200.200.1",
    "10.200.200.11",
    "CONFIG_TCP_MD5SIG=y",
    "kernel=6.8.0-117-generic",
    "md5-option packets=18",
):
    if needle not in final:
        bad.append("final apply transcript lacks %r" % needle)
if "demo 46-colima check: 0 FAIL" not in final:
    bad.append("final apply transcript lacks the check footer")
final_lines = final.splitlines()
check_starts = [i for i, l in enumerate(final_lines) if l.startswith("$ demos/46-bgp-fabric-colima/check.sh")]
last_check = final_lines[check_starts[-1]:] if check_starts else final_lines
check_rows = [
    l for l in last_check
    if l.startswith("  PASS   ") or l.startswith("  WARN   ") or l.startswith("  FAIL   ")
]
if len(check_rows) != 17:
    bad.append("final check is %d rows, not 17" % len(check_rows))
if sum(1 for l in check_rows if l.startswith("  PASS   ")) != 17:
    bad.append("final check is not 17 PASS")
if any(l.startswith("  WARN   ") for l in check_rows):
    bad.append("final check still has a WARN row")
if "FRR_IMAGE=quay.io/frrouting/frr:10.7.1" not in Path("scripts/bootstrap/versions-eg.env").read_text():
    bad.append("versions-eg.env is not FRR 10.7.1")
if "gateway: 10.200.200.254" not in (root / "fabric/compose.yaml").read_text():
    bad.append("compose.yaml does not pin mgmt gateway 10.200.200.254")
if "name: bgp-fabric-colima" not in (root / "fabric/compose.yaml").read_text():
    bad.append("compose.yaml name is not bgp-fabric-colima")

for p in (root / "RECAP.md", root / "README.md"):
    text = p.read_text()
    if "10.5.3" in text:
        bad.append("%s still has 10.5.3" % p)
    for needle in (
        "2.04 s",
        "0.67 s",
        "window=2.002",
        "client0_rc=28,28,28,28",
        "17 rows",
        "17 PASS",
        "10.7.1",
        "10.200.200.1",
        "10.200.200.2",
        "10.200.200.11",
        "10.200.200.12",
        "10.200.200.100",
        "10.200.200.254",
        "8098",
        "CONFIG_TCP_MD5SIG=y",
        "6.8.0-117-generic",
        "md5-option packets=18",
        "Established→Idle",
        "external=0",
    ):
        if needle not in text:
            bad.append("%s lacks %r" % (p, needle))
    for stale in (
        "1.49 s",
        "recovered after 0.68 s",
        "15 PASS",
        "16 rows",
        "client0_rc=28     ",
        "sessions run unsigned on this VM",
    ):
        if stale in text:
            bad.append("%s still quotes a superseded run: %r" % (p, stale))
    if "next phase" not in text.lower() and "next phase" not in text:
        if "next phase" not in text:
            bad.append("%s does not say attaching a cluster is the next phase" % p)

guide = (root / "GUIDE.md").read_text()
if "10.5.3" in guide:
    bad.append("GUIDE.md still has 10.5.3")
if "Print the status table" not in guide:
    bad.append("GUIDE.md did not name exercise 1")
if "2.04 s" not in guide or "window=2.002" not in guide:
    bad.append("GUIDE.md lacks the drop/recovery timings")
if "client0_rc=28,28,28,28" not in guide:
    bad.append("GUIDE.md lacks the four-address client0_rc row")
if "md5-option packets=18" not in guide or "Established→Idle" not in guide:
    bad.append("GUIDE.md lacks the MD5 wire count or the mismatch")
if "1.49 s" in guide or "recovered after 0.68 s" in guide:
    bad.append("GUIDE.md still quotes a superseded drop/recovery clock")

for b in bad:
    print("CLAIM FAIL:", b)
sys.exit(1 if bad else 0)
