---
name: demo-recap
description: (superseded for demos 54+ by demo-guide — the structured page) Write RECAP.md for a demo — a plain-English walk-through of what the demo did and proved, in the demo's own folder, keeping every technical insight and every measured number but none of the jargon. Invoke when a demo's PR is ready for review or merged, or when the operator asks "walk me through it" / "what did we achieve with demo N".
---

# Demo recap — the walk-through in plain English

The operator's ask, verbatim (2026-09-18): *"we need to skill and memory to properly redirect and format the last summary
keep the same technical insights with good english in the same demo folder as a summary recap. So start with
'What demo 40 did — the walk-through' and then next for 41."* The first two — `demos/40-shop-mesh-phase0/RECAP.md`
and `demos/41-shop-mesh-phase1/RECAP.md` — are the models.

A README is for the engineer who will run the demo. A RECAP is for the reader who wants to know **what was built,
why it is shaped that way, and what was proven** — a manager, a reviewer from another team, a junior on day one.
It is written after the review pass, from the review record and the transcript, never before: it states what was
measured, and a recap written before the measurements would be a plan.

## The file

`demos/<NN>-<slug>/RECAP.md`, linked from the demo's README in its first lines as *"For the reader in a hurry:
[RECAP.md](RECAP.md)"*, and one row in the root README's demos table is enough (no new column).

## The shape — every recap, the same headings, in this order

```markdown
# What demo NN did — the walk-through

**The goal** — one paragraph: what the enhancement wants, and which piece of it this demo is (the picture in one
sentence — "building the front doors before moving the furniture in").

**1. <A headline in plain words.>**
One or two paragraphs. Say what was done AND why it had to be that way. Numbers stay (addresses, counts, times) —
they are the evidence. A term of art gets its plain meaning in the same sentence the first time it appears
("ARP conflict — a coin toss on every packet").

**2. …** (as many numbered steps as the demo has real steps; five to eight is typical)

**The reference card — names, addresses, certificates, doors.** (Only when the demo creates names, addresses,
certificates or Gateways — the operator, 2026-09-18: *"include the dns record… the ip address and dns record and how
the cert manager certificate request was spec… did you cn and alt dns name… how many… mini reference diagram for the
additional gateways".*) Read from the LIVE objects, not the manifests: a table name → address → what it is → who
answers; the Certificate spec as applied (CN, every SAN, issuer → CA secret, secretName) with one paragraph on *why*
that shape (one per cluster or per service? why the CN is the product name? what was rejected and measured); the
issued leaves' subject, issuer, SANs, validity and per-cluster fingerprints; and an ASCII diagram of the Gateways
with their listeners, hostnames, certificate and pool. Demo 40's is the model.

**What the review caught.** One line per finding that changed the demo, plain words — what was wrong and what it
would have meant ("the check called an unreachable door a PASS"). Name the reviewers once. Findings rejected are
not listed here (they are in docs/REVIEW_*.md).

**What you can do with it right now.** Two to four commands a reader can run, with what they will see.

**Where the next demo starts.** One paragraph.
```

## The rules of the prose

1. **Plain English, complete sentences, present tense for what exists, past tense for what was done.** No bullet
   fragments in the numbered steps; bullets are allowed only in the "review" and "run it" sections.
2. **Every technical insight from the README survives** — the mechanism (which Cilium object does what, which file
   in Cilium's source says so), the measured numbers, the failure that shaped the design. Nothing is dumbed down;
   it is *explained*. Test: an engineer who reads only the RECAP could explain the design decision to another engineer.
3. **Every number is a measurement from the transcript or the review record**, never rounded or remembered. If a
   number is not in `output/transcript.txt`, `evidence.json`, `docs/REVIEW_<demo>.md` or the plan, it does not go
   in the recap.
4. **Jargon gets one gloss, once**, in the sentence where it first appears: *"a Gateway (Cilium's front door object,
   a Service plus listeners in the node's shared Envoy proxy)"*. After that, the term is used plainly.
5. **Say what is deliberately unfinished** ("the doors answer 404 on purpose — no routes yet") and what the next demo
   will show, so a reader does not mistake a phase for a gap.
6. **No praise, no adjectives of quality** ("robust", "elegant", "solid") — the numbers and the review section carry
   the judgement.
7. **Length:** 600–1,200 words of prose; the reference card's tables, YAML and diagram are not counted (demo 40 is 1,035 without it, demo 41 1,209 — it carries a review correction as a step). Longer means the README's job is being done twice; shorter means an insight was dropped.
8. **`scripts/mdfmt fix` after writing**, like every .md here.

## The process

1. Read, in full: the demo's README, `docs/REVIEW_<demo>.md`, the last `check.sh` summary in `output/transcript.txt`,
   the plan's row for the phase. Write nothing before all four are read.
2. List the insights first (a scratch list: each mechanism, each measured number, each design decision and the
   measurement that forced it). The recap must contain every item on the list.
3. Write the recap in the shape above. Read it back once as the junior on day one: every sentence that needs a
   second reading gets rewritten.
4. Add the README link and the root-table mention; `scripts/mdfmt fix`; the recap goes in the demo's PR (or its own
   small PR when the demo is already merged). The operator merges.

## Memory

[[demo-recap-skill]] in the project memory records the ask and points here.
