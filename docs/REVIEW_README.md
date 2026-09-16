# Review — the README restructured (branch `readme-restructure`, 2026-09-16)

The rewrite's promise: shorter and in reading order, **nothing factual lost**, **no number or name changed in meaning**,
and a *Cilium docs* column whose links match the feature on each row. Two reviewers read the old file
(`README.md` at `7ddc31a`, 540 lines) beside the new one, each in its own scratch copy, with the same brief: three
claims (C1 nothing lost, C2 no number changed, C3 the docs mapping), a verdict each, and quoted evidence for every
refutation. Cursor (`agent --mode ask`, cursor-grok-4.6-high-fast) and Codex (`codex exec -s read-only`, gpt-5.6-sol,
xhigh). Every verdict below was re-checked against the files or the live documentation pages before it was accepted.

## The measurement behind the rewrite

Rendered on GitHub in Chromium (Playwright, 1280 × 900): the old README was 23,764 px — 26.4 screens — 9,692 words,
0 images, the demos enumerated in four tables (the path's items 8d–8n, the 27-row status table, the 35-row Demos table
ordered 01→10 then 36→11, the 34-row Evidence table). The new one: 11,545 px — 12.8 screens — before the review's
additions, 4,532 words after them, one image, one demo table (01→36 in six groups), the *Cilium docs* column with
every URL fetched and checked for Read the Docs' 200-status redirect stubs (`security/policy/language/` is one: its
real page is `security/policy/`).

## What my own second pass found before the reviewers (fixed in `bed3c06`)

The condensing had dropped: the three CI workflows and what each proves (87/87, route B), the CoreDNS-upstream row
(gotcha #63), kube-prometheus-stack 90.1.1, the links to `clusters/`, `cilium/` and the evidence scripts, Tetragon's
4.27.2 → 4.30.0, enhancement 001's link. `docs/SETUP.md` linked the removed *Findings* anchor — repointed.

## Verdicts

| Claim | Cursor | Codex | Outcome |
|---|---|---|---|
| C1 nothing lost | REFUTED — six facts with no carrier | REFUTED — three "contradictions" | six restored; the three are deliberate corrections (below) |
| C2 no number changed | REFUTED — eight differences | REFUTED — five | three restored, the rest deliberate |
| C3 the docs column | REFUTED — five rows | REFUTED — four rows | four rows fixed; one Cursor claim refuted by the pages |

### C1 — accepted and restored (`47c8909`)

`scripts/cluster-resume.sh poc3`; external-dns from the HTTPRoutes' hostnames; the ACME/DNS-01 wildcard path and
`certificateRefs` unchanged; the one-worker spoke row (observer replicas on one node, the PDB); the Mac-workstation row
(`hubble` CLI, Playwright, `sudo`; `scripts/hubble-tls.sh`); Hubble UI behind the Gateway as `hubble.poc.local` with its
data stream — placed in demo 09's cell, not the pages table: `demos/09-routes/04-hubble-via-gateway.yaml` exists, but no
HTTPRoute with that hostname is applied by the lab scripts today (`kubectl get httproute -A`: none).

### C1 — Codex's three, kept as written (deliberate)

- "pod and service CIDRs chosen inside the `kind` docker bridge": the pod CIDRs are `10.10/16`, `10.20/16`, the bridge
  is `172.18/16` — the old sentence was loose; the new one says the bridge is the LAN and the node IPs are on it.
- "written into the MacBook's `/etc/hosts` by each demo's `hosts-entries.sh`" against "prints the block and never edits
  the file": the old README said both (its lines 83 and 56); the script prints, the operator's `sudo tee` writes.
- "the Mac trusts the root by passing `docs/root-ca.crt` to `curl` and the browser" against the System keychain: both
  true; the TLS row now names both.

### C2 — accepted

`6.6.12-linuxkit` and the `6.7` netkit needs (not "6.6"); "no flows-per-minute chart" as the old text had it (not "no
history", my inference); `kindest/node:v1.36.4` by name; 4.30.0 (already restored). Deliberate: "All ten demos" → 36
(there are 35 demo directories, 01–36 without 12; 12 is the parked BGP demo); "14 sections" → 23 (the old README also
said 23 in its status table; `grep -cE '^ [0-9]+\. [A-Z]' docs/VERIFICATION_RUN.md` = 23); cf2cnp 0.8.0 in the versions
table is today's pin (`values-hubble-observer.yaml`), demo 35's cell keeps its 0.6.3.

### C3 — accepted

The datapath row linked the policy intro and Hubble's setup: now the Introduction, the eBPF datapath page and
identity-based security. The PKI row linked Hubble TLS alone: now ClusterMesh's `#configure-tls-certificates`, Hubble
TLS and Gateway API HTTPS. ztunnel: `security/network/encryption-ztunnel/` (fetched, 38,745 B — `servicemesh/ztunnel/`
is a 404). `TCPRoute` has no page of its own; the Gateway API page describes it (4 mentions) and the cell says so.
Layer 4 rules added on the policy row (Codex).

### C3 — refuted

Cursor: "`/security/policy-creation/` is not the audit-mode page; that section lives on Policy Lifecycle." Measured:
`id="enable-policy-audit-mode-specific-endpoint"` occurs once on `security/policy-creation/` and zero times on
`security/policy/lifecycle/`. The link stands.

## Outcome

Both reviewers confirmed the shared numerals (Cilium 1.20.1, kind 0.33.0, v1.36.4/v1.37.0/1.33–1.36, v0.20.0, 1.19.4,
v1.21.1/2, v1.6.1, 0.160.0, the CIDRs, `172.18.255.240/.201/.241`, 9 min 34 s / 9 min 5 s, 113, 48 vs 11,078, 25–38 %,
−73 %, 7/7, 52/52, 44, 16-span, 6 JVMs, the gotcha numbers). The demo table is 35 rows (Cursor and Codex both counted;
the old table was 35 too), grouped, ascending. Every relative link and anchor in the new file resolves against the tree
(107 links); the image renders at 1600 px.
