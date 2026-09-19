#!/usr/bin/env python3
"""OB3 review of docs-guide-cilium-demos (8435c9b): one check per finding. Each fails on 8435c9b and passes
after the fix it names. usage: python3 tests/docsguide-review.py  (from the repo root; exit 0 = all pass)"""
import re, subprocess, sys, tempfile, os

R40 = "demos/40-shop-mesh-phase0"; R41 = "demos/41-shop-mesh-phase1"; R53 = "demos/53-grpc-parity"
rd = lambda p: open(p, encoding="utf-8").read()
norm = lambda s: re.sub(r"\s+", " ", s)
fails = []
def check(name, ok, why=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f" — {why}"))
    if not ok: fails.append(name)

def steps(recap):
    """[(title, body)] of the H3s under ## Steps, H3s read outside code fences."""
    m = re.search(r"^## Steps\n(.*?)(?=^## |\Z)", recap, re.M | re.S)
    body = m.group(1)
    blank = lambda mm: re.sub(r"[^\n]", " ", mm.group(0))
    outside = re.sub(r"```.*?```", blank, body, flags=re.S)
    starts = [mm.start() for mm in re.finditer(r"^### ", outside, re.M)]
    out = []
    for a, b in zip(starts, starts[1:] + [len(body)]):
        st = body[a:b]
        out.append((st.splitlines()[0][4:], st))
    return out

# C2 — demo 41: the guide must apply what it generates (observe-and-enforce.sh §6) between Generate and Enforce
s41 = steps(rd(f"{R41}/RECAP.md")); titles41 = [t for t, _ in s41]
gen = next((i for i, t in enumerate(titles41) if "Generate" in t), None)
enf = next((i for i, t in enumerate(titles41) if "Enforce" in t), None)
between = [b for t, b in s41[gen + 1:enf]] if gen is not None and enf is not None else []
check("C2 41: a step between Generate and Enforce applies policies/<cluster>/cnp-shop-intent.yaml",
      any("cnp-shop-intent.yaml" in b and "kubectl" in b for b in between), f"titles={titles41}")

# C1 — demo 41 README step 3 must not narrate an apply the transcript does not hold
tx41 = rd(f"{R41}/output/transcript.txt"); rm41 = rd(f"{R41}/README.md")
check("C1 41: README step 3 claims only what the transcript records",
      ("cnp-shop-intent.yaml" in tx41) or ("found the objects already present" not in norm(rm41) and "not in the record" in norm(rm41)))

# C1 — demo 40: Result lines carry only the step's recorded output (the review's arping/agent-log timings live in Reference)
rc40 = rd(f"{R40}/RECAP.md")
results40 = [l for l in rc40.splitlines() if l.startswith("Result:")]
# a Result may wrap: take each Result paragraph
paras40 = re.findall(r"^Result:.*?(?=\n\n)", rc40, re.M | re.S)
bad = [p[:60] for p in paras40 if "2a:41:4a:7f:cf:12" in p or "Agent logs" in p or "~40 ms" in p]
check("C1 40: no Result: paragraph cites the review's arping reply or the agent-log timing", not bad, str(bad))
check("C1 40: the ~40 ms is stated for one direction only (the record times poc1 → poc2)",
      "and back in ~40 ms" not in norm(rc40))

# C4 — demo 53: the hostname rule is the Listener ∩ route-hostnames acceptance rule, not ":authority"
for p in (f"{R53}/RECAP.md", f"{R53}/README.md"):
    t = rd(p)
    check(f"C4 53: {p} states the Listener/route hostname rule",
          "Listener and GRPCRoute have specified hostnames" in norm(t) and ":authority` to intersect" not in norm(t)
          and "that `:authority` intersect" not in norm(t))
check("C4 53: the localhost-only realized-ingress insight is on a page",
      any("allow-localhost-ingress" in rd(f"{R53}/{p}.md") for p in ("RECAP", "README", "GUIDE")))
check("C4 53: the HTTP-GET-on-the-gRPC-host 404 / 301 contrast is on a page",
      any("gRPC is not HTTP/1.1" in norm(rd(f"{R53}/{p}.md")) for p in ("RECAP", "README", "GUIDE")))
check("C4 53: the wrong-authority Expect says it is not in this demo's transcript, or the transcript holds it",
      "server does not support the reflection API" in rd(f"{R53}/output/transcript.txt")
      or "not in this demo's transcript" in norm(rd(f"{R53}/GUIDE.md")))
check("C4 40: the two-address measurement (.246/.247) is on a page",
      any("172.18.255.246" in rd(f"{R40}/{p}.md") for p in ("RECAP", "README", "GUIDE")))
check("C4 40: GUIDE has a shopctl probe exercise (the hosts block's consumer)",
      "probe --url" in rd(f"{R40}/GUIDE.md"))
check("C4 40: the regression lease-row / dying-lease note is on a page",
      any("lab-regression" in rd(f"{R40}/{p}.md") for p in ("RECAP", "README")))
for p in (f"{R41}/RECAP.md", f"{R41}/README.md"):
    check(f"C1 41: {p} quotes selectbackends.go's full condition",
          "localActiveBackends == 0 && remoteBackends > 0" in norm(rd(p)))

# C2 — step order follows the apply script's sections
t53 = [t for t, _ in steps(rd(f"{R53}/RECAP.md"))]
i_l = next((i for i, t in enumerate(t53) if "listener" in t.lower()), 99)
i_a = next((i for i, t in enumerate(t53) if "app" in t.lower()), 99)
check("C2 53: the listener/leaf step (apply.sh §1) precedes the app step (§2)", i_l < i_a, str(t53))
t40 = [t for t, _ in steps(rc40)]
check("C2 40: the builds (apply.sh §0) are steps 1–2", "Build" in t40[0] and "Build" in t40[1], str(t40))
check("C2 41: the guide names apply-both.sh's first-transition deletion of demo 35's policies",
      "remove_legacy_policies" in rd(f"{R41}/RECAP.md"))

# C3 — inline commands of tools the regex missed, and glosses
gs = rd("tests/guide-structure.py")
check("C3 test: guide-structure.py's inline-command regex names arp, cilium-dbg, hubble, crictl",
      all(w in gs for w in ("arp|", "cilium-dbg", "hubble", "crictl")))
for p, needle in ((f"{R40}/RECAP.md", "`arp -n 172.18.255.16`"), (f"{R40}/README.md", "`arp -n 172.18.255.16`"),
                  (f"{R41}/README.md", "`cilium-dbg service list`"), (f"{R41}/GUIDE.md", "`cilium-dbg service list`")):
    prose = re.sub(r"```.*?```", "", rd(p), flags=re.S)
    check(f"C3 {p}: no inline {needle}", needle not in prose)
rc41 = rd(f"{R41}/RECAP.md")
check("C3 41: cf2cnp glossed", re.search(r"cf2cnp \([^)]+\)", norm(rc41)) is not None)
check("C3 41: statedb glossed", re.search(r"statedb \([^)]+\)", norm(rc41)) is not None)
check("C3 53: h2c glossed", "h2c (HTTP/2 cleartext)" in norm(rd(f"{R53}/RECAP.md")))

# C5 — the verbatim gate must fail an unmarked ```text fence that is not declared "Not recorded"
with tempfile.TemporaryDirectory() as d:
    for demo, n in ((R40, 40), (R41, 41), (R53, 53)):
        os.makedirs(f"{d}/{demo}/output"); os.makedirs(f"{d}/tests", exist_ok=True)
        open(f"{d}/{demo}/README.md", "w").write(rd(f"{demo}/README.md") + "\n\nA stray quote.\n\n```text\nnot from any run\n```\n")
        open(f"{d}/{demo}/output/transcript.txt", "w").write(rd(f"{demo}/output/transcript.txt"))
        open(f"{d}/tests/readme{n}-verbatim.py", "w").write(rd(f"tests/readme{n}-verbatim.py"))
        r = subprocess.run([sys.executable, f"tests/readme{n}-verbatim.py"], cwd=d, capture_output=True, text=True)
        check(f"C5 readme{n}-verbatim.py fails an unmarked ```text fence", r.returncode != 0, r.stdout[-200:])
for n in (40, 41, 53):
    r = subprocess.run([sys.executable, f"tests/readme{n}-verbatim.py"], capture_output=True, text=True)
    check(f"C5 readme{n}-verbatim.py passes the committed README", r.returncode == 0, r.stdout[-300:])

# C7 — the skill's README H2 list equals the test's REQUIRED + OPTIONAL for --kind readme
skill = rd(".claude/skills/demo-guide/SKILL.md")
m = re.search(r"\*\*README\.md — the record\.\*\*(.*?)\*\*GUIDE\.md", skill, re.S)
bold = re.findall(r"\*\*([^*]+)\*\*", m.group(1))
bold = [norm(b).split(" (")[0].strip() for b in bold]
sys.path.insert(0, "tests"); import importlib
gsmod = importlib.import_module("guide-structure")
req, opt = gsmod.KINDS["readme"][0], gsmod.KINDS["readme"][1]
check("C7 skill README H2s == guide-structure.py REQUIRED ∪ OPTIONAL (readme)",
      set(bold) == set(req) | set(opt), f"skill={bold} test={sorted(set(req)|set(opt))}")
check("C7 skill: the Kubernetes row attributes 'For `steps`…' to the task page, not the tutorial",
      "task page" in skill and "lessoncontent" in skill)

print(f"\n{len(fails)} failing" if fails else "\nall checks pass")
sys.exit(1 if fails else 0)
