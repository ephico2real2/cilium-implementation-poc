# Review — the demo-guide rewrite of demos 40, 41 and 53 (2026-09-19)

A docs-only branch (`docs-guide-cilium-demos`, from `main` `9923045`): the shop-platform demos' three pages each —
RECAP.md (the guide), README.md (the record), GUIDE.md (the exercises) — rewritten to `.claude/skills/demo-guide/SKILL.md`
from each demo's transcript and review record, with poc1/poc2 paused (nothing re-run). Three reviewers on one brief
(`scratchpad/review_brief_docsguide.md`, seven claims: fidelity to the record; the steps against the apply scripts; the
skill's rules on all nine pages; nothing lost from the previous versions; the verbatim gates' honesty; links; the skill's
cited sources): **OB3** (`.claude/agents/ob3.md`, Opus 5; 69 tool uses, 23 min; deep on C1 — a token sweep of every
number against the sources — C2, C4 and C5; every fix as one diff proven on a copy with its own 30-check test);
**Grok** (Cursor `cursor-grok-4.6-high-fast`; shell and fetches rejected — the tree and the transcripts); **Codex**
(see the last paragraph). Every accepted finding was re-verified by the orchestrator against the scripts, the
transcripts, the CRD or the cited page before it was applied.

Under review: `8435c9b` (three commits on `9923045`).

## What held

| Claim | Evidence |
|---|---|
| structure (C3) | all nine pages pass `tests/guide-structure.py` for their kind; prose 892 / 802 / 798 words without headings; no run numbering, no review narrative |
| verbatim gates (C5) | every marked fence's lines exist in that demo's transcript (40: 10 fences, 41: 11, 53: 7); the two unmarked shopctl load tables are declared in the test's docstring |
| links (C6) | every relative target and anchor resolves (GOTCHAS `#80`, `#84`, `#118`; the plan's §8.1; the sibling demos; root README rows 40/41/53) |
| the sources (C7) | GitHub Docs, Google and Diátaxis quotes verified verbatim on the live pages |

## Findings, accepted and applied

| # | Finding | From | Fix |
|---|---|---|---|
| A1 | **demo 41's guide never applied the policies it generates** — `observe-and-enforce.sh` §6 (apply the generated set, then verdicts) was missing, so "Enforce" would have disabled audit on the *old* set; `apply-both.sh` §1 (`remove_legacy_policies`) was unmentioned; and the guide's step 3 described a record that does not exist — the committed transcript (`312ca91`) predates `apply-both.sh` §6b (`c9fb1fc`; 0 hits for `cnp-shop-intent`) | OB3 C2/C1 (most important), Grok C2 | a new step "Apply the generated policies", renumbered; the README states what the transcript covers; the legacy-policy sentence; the full `selectbackends.go:87` condition (`useRemote = localActiveBackends == 0 && remoteBackends > 0`); cf2cnp and statedb glossed |
| A2 | demo 53's hostname rule came back mis-stated ("requires that `:authority` intersect the route's hostnames"); the rule that forces the third listener is the CRD's — *"If both the Listener and GRPCRoute have specified hostnames, and none match … the GRPCRoute MUST NOT be accepted"* (`crds/gateway-api/v1.6.1/…grpcroutes.yaml:112-115`) | OB3 C4 | quoted from the CRD; the localhost-only ingress, the 404/301 contrast and `NoSuchMethod` restored; h2c glossed |
| A3 | **demo 53's exercise quoted a "measured" error that this demo never recorded** — the wrong-`:authority` line is in demo 54's transcript only | Grok F1, OB3 C4 | the exercise says what apply.sh records and that this probe is not in the transcript yet; a `wrong_authority` probe for the next apply is in OB3's report |
| A4 | steps out of the scripts' order: demo 53's guide put the app before the certificate/Gateway (`apply.sh` §1 → §2 → §3); demo 40's builds (`== 0`) were steps 4–5 | OB3 C2, Grok C2/F5/F9 | reordered to the scripts; README H3s match |
| A5 | four `Result:` lines quoted review-time measurements as if the step's command had printed them (demo 40's ARP MAC and the ~40 ms lease flip — `docs/REVIEW_DEMO40.md:18`, one direction; demo 41's `audit-both.sh Disabled`) | OB3 C1, Grok F3 | moved to *What you get* / *Reference* with the citation; the takeover step's result is what `vip-takeover.sh` printed (`0s` / `27s`, `announced by: poc2`) |
| A6 | numbers with no source under rule 4: the pins and the Mac route in demo 40 (they are in `scripts/bootstrap/versions.env` and `docs/SETUP.md:684`); demo 41's resource sums `1007m` / `19395` (the review has the addends) | Grok C1/F4, OB3 C1 | rule 4 widened to the pins file and SETUP/NETWORKING_DESIGN for lab-wide facts, linked where used; the sums replaced by the addends |
| A7 | inline commands the test's regex missed (`arp -n` ×3, `cilium-dbg service list` ×3); a "read, not measured" aside in a guide; a planned file named as if it existed | Grok C3/F6/F7/F8, OB3 C3 | fenced; the regex gains `arp`, `hubble`, `cilium-dbg`, `crictl`; the aside reworded; "(not yet written)" |
| A8 | lost from the previous pages: demo 40's two-address measurement, the regression lease-row note and the `shopctl probe` exercise (the GUIDE's hosts block fed nothing) | OB3 C4 | restored; GUIDE40 has six exercises |
| A9 | the verbatim tests silently skip an unmarked fence (an injected quote passes all three) | OB3 C5 | an unmarked fence FAILS unless labelled "Not recorded"; the set-membership loophole (two runs in demo 53's transcript) noted, not closed |
| A10 | the skill: the Kubernetes row attributed *"For `steps`, use numbered lists…"* to the tutorial page — it is the task page's; the README heading list omitted the optional *Summary context* the three READMEs use | OB3 C7, Grok C7 | corrected; `tests/docsguide-review.py` checks the skill's lists against the gate's |

## Rejected / not done here

| Item | Why |
|---|---|
| re-record demo 41 (`apply-both.sh` §6b) and demo 53's wrong-authority probe | needs poc1/poc2 resumed; the pages say so |
| the verbatim tests' set-membership loophole | closing it means per-run scoping of the transcript; noted for the next demo that appends a run |

After the fixes: `guide-structure.py` ×9 PASS, `readme40/41/53-verbatim.py` PASS, `docsguide-review.py` 30/30, `mdfmt` 0
issues. Reports: `scratchpad/review_ob3_docsguide.txt` (+ `ob3_fix.diff`), `scratchpad/review_grok_docsguide.txt`.
**Codex:** its job hung after the read phase (the same shell command reported for over 30 minutes) and was cancelled;
no verdicts reached the record. **Owed:** OB1/OB2's second reading of OB3's passes (demos 50, 51, 54, this branch).
