# Review — demo 46, the BGP fabric as a lab of its own (2026-09-20)

Three reviewers on one brief (`scratchpad/review_brief_demo46.md`, seven claims: the topology; the servers' policy;
convergence and ECMP; idempotence and Linux-safety; `check.sh`; the docs; what must not have moved). **OB3**
(`.claude/agents/ob3.md`, Opus 5; 85 tool uses, 27 min; deep on C2 with FRR 10.5.3's source, a throwaway fabric with a
dynamic TTL-1 peer and `tcpdump` on the live leaf, on C3's ECMP half with the throwaway, on C5 with shims, on C1's
capabilities by removing `SYS_ADMIN`); **Codex** (sandbox without Docker or temp files; static findings measured in
memory); **Grok** (Cursor `cursor-grok-4.6-high-fast`; shell rejected — the tree and the record). Every accepted finding
was re-verified by the orchestrator on the live fabric or in the source before Cursor applied it from the reviewer's
snippet.

Under review: branch `demo-46-bgp-fabric` at `6cf6808` on `main` `ec8df44`.

## What held (OB3 and the orchestrator, live)

| Claim | Evidence |
|---|---|
| the topology (C1) | `Privileged=false`, caps `NET_ADMIN NET_RAW SYS_ADMIN` — and without `SYS_ADMIN` zebra and bgpd die at `privs_init` (the three caps are FRR's minimum); the `/29` links, wan, loopbacks as `/32` on `lo` from `interface lo`; FRR tag `10.5.3` = MetalLB 0.16.0's own pin (`helm show values`:334-335) |
| the route-maps (C2, half) | every eBGP session has an in and an out map; traced on a throwaway with a server announcing `10.98.0.5/32` and `10.97.0.1/32`: the leaf accepts one and filters one, spine path `65101 65021`, edge `65100 65101 65021`, `client0` reaches the server by traceroute; `NOTHING out` → the server receives 0 prefixes |
| convergence and ECMP (C3) | six sessions Established at the first poll; `client0 → 10.200.100.2 → 10.200.1.18 → 10.200.255.11`; leaf1 → `172.19.0.3` through the overlay; on the throwaway the same `/32` from both leaves: spine `Paths: (2 available) … multipath`, `ip route` with two nexthops, six flows spread over both |
| the scripts (C4) | repeated `up -d --wait` keeps the container ids; `down` removes only the fabric's networks; no sudo; `--apply` runs only the VM line |
| nothing else moved (C7) | 38 files in the diff; demo 54 15 PASS and demo 52 21 PASS read-only; poc1/poc2 `Exited (137)`; the `kind` network unchanged; `kind-eg` = the four eg nodes + exactly the two leaves |

## Findings, accepted and applied

| # | Finding | From | Fix |
|---|---|---|---|
| A1 | **the fabric could not be attached by the two speakers it exists for** — `neighbor SERVERS ttl-security hops 1` (GTSM) demands TTL 255 from the peer; kube-vip's gobgp (`fsm.go:935 ttl = 1`) and MetalLB's FRR-K8s (no ttl-security in its template) send TTL 1; measured: a TTL-1 peer in the listen range sat in OpenConfirm with "Hold Timer Expired" until the line was removed, then Established in 18 s | OB3 C2b (most important) | the line removed from both leaves; the sheet's row 3, the pages and the plan's diagram say the lab runs without GTSM and why; `tests/fabric-servers-policy.sh` |
| A2 | **MD5 configured but not in effect** — this Docker VM's kernel (`7.0.12-linuxkit`) refuses `TCP_MD5SIG` on every socket ("Protocol not available": leaf1 ×5, leaf2 ×5, spine ×9); `tcpdump` on a live session shows no MD5 option; all six sessions run unsigned while looking authenticated; the plan's §7 had said "kernel 6.6 — fine" | OB3 C2a | the `password` lines stay (the network team's intent; a real fabric signs); the sheet, README, RECAP and plan §7 say the lab's sessions are unsigned and why; `check.sh` row 13 WARNs with the refusal counts (PASS where no refusal is logged) |
| A3 | the VIP prefix-lists admitted any prefix in the `/24` (`le 32` → minimum length 24) from any peer, while the sheet promised exact `/32`s and per-cluster blocks | Grok F1, Codex F4 | per-cluster prefix-lists (`10.98.0.0/26 ge 32 le 32`, `.64/26`, anycast `.192/26`; the Cilium trio) matched together with `as-path` access-lists per cluster ASN (`^65021$`, `^65022$`, `^65001$`, `^65002$`) in `SERVERS-IN`; the aggregate lists kept for LEAF-OUT / FABRIC-IN; `tests/fabric-prefix-exact32.sh` — demos 56/57's wrong-block announcement is now a negative test |
| A4 | the leaves had no `maximum-paths` — two nodes on one leaf announcing the same `/32` from the same AS would give the leaf one path | Grok (not asked) | `maximum-paths 8` on both leaves; the ECMP row reads spine and leaves; `tests/fabric-max-paths.sh` |
| A5 | `check.sh` look-alike PASSes: the RFC 8212 row passed `frr defaults datacenter` (policy OFF) and an empty config; the prefix-list row passed a `deny`; the ping rows judged on rc alone; the listen row checked one range of two | Codex F1, OB3 C5, Grok C5 | exact predicates; `tests/check46-false-pass.sh`; contract cases (d)(e) |
| A6 | `tests/check46-contract.sh` masked the first command's status (`\|\| rc=$?` then `rc=${rc:-0}`); the password test accepted `$OTHER`; `fabric-status.sh` exited 0 with six FAIL states | Codex F2, F5 | `rc=0; out=$(…) \|\| rc=$?`; the exact placeholder required; `fabric-status.sh` exits non-zero; `tests/fabric-status-exit.sh` |
| A7 | the convergence poll's outcome was not in the record | Codex F3 (as reshaped) | one recorded line — `converged after 2 s (2 polls)` on the reload; `tests/fabric-up-converge.sh` |
| A8 | `fabric/.env` tracked with the lab password | OB3 fix 3, Codex C2 | ignored; `.env.example` shipped; compose default `${FABRIC_BGP_PASSWORD:-lab-bgp}`; `fabric-up.sh` copies the example when absent |
| A9 | one fabric per Docker host — a second copy's `/29` links overlap ("Pool overlaps with other one on this address space"); the brief's throwaway had to be re-addressed | OB3 (brief defect) | documented; `fabric-up.sh` refuses when another project owns `10.200.1.0/29` |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| route every convergence poll through `record.sh` | Codex F3 as written | it would flood the transcript; the outcome line and the final summaries are the record |
| bare `vtysh network` to inject a test prefix | brief C3 | `bgp network import-check` is on under `traditional` — OB3 used a RIB route on the throwaway |

After the fixes: the fabric brought down and up with the corrected configs (`converged after 2 s (2 polls)`); `check.sh`
**12 PASS, 1 WARN** (the MD5 refusal, by design), 0 FAIL; the live leaves: no `ttl-security`, `maximum-paths 8`, the
per-cluster lists; every test under `tests/*46*`, `tests/fabric-*.sh`, `tests/demo46-claims.py`, `readme46-verbatim.py`
and `guide-structure.py` ×3 PASS; `mdfmt` 0 issues. Reports: `scratchpad/review_ob3_demo46.txt`,
`scratchpad/review_grok_demo46.txt`, `scratchpad/review_codex_demo46.txt`. **Owed:** OB1/OB2's second reading of OB3's
passes (demos 46, 50, 51, 52, 54 and the tier-1 docs).
