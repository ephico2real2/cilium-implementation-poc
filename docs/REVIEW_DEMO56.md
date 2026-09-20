# Review — demo 56, eg-poc1 moves from L2 to BGP with kube-vip (2026-09-20)

Three reviewers on one brief (`scratchpad/review_brief_demo56.md`, eight claims: the four facts the demo rests on, the
manifests, the sessions and paths, the outside-world calls, the two failure scenarios, `check.sh`, the docs, what must
not have moved). **OB3** (`.claude/agents/ob3.md`, Opus 5; 112 tool uses, 38 min; deep on C1 — kube-vip v1.2.4 and
gobgp v4.9.0 read at their tags — C5 with the cluster's own events captured after the ninth run and the
controller-manager's defaults from the binary, C6 under stubs, every fix built and tested in a scratch copy); **Codex**
(sandbox without Docker or temp files; predicates measured in memory); **Grok** (Cursor `cursor-grok-4.6-high-fast`;
shell rejected — the record, read closely). Every accepted finding was re-verified by the orchestrator live or in the
source before it was applied.

Under review: branch `demo-56-kube-vip-bgp` at `b6d7bc2` (nine applies; the ninth the record) on `demo-46-bgp-fabric`
`edae9cc` (PR #68).

## What held (OB3 and the orchestrator, live)

| Claim | Evidence |
|---|---|
| the facts, in the source (C1) | `cmd/kube-vip.go:363-392` counts ARP/BGP/Wireguard/RoutingTable, >1 → *"multiple kube-vip modes detected"*; `pkg/services/services.go:203-205` the `configureService` gate; the election warning at `pkg/manager/worker/bgp.go:116-118`, reached only with `svc_election=false` and `vip_leaderelection=true`; the Local rule at `pkg/endpoints/endpoints_generic.go:88-95` (`GetLocalEndpoints` for Local); gobgp v4.9.0 `internal/pkg/netutils/sockopt_linux.go:191-211` returns the `TCP_MD5SIG` setsockopt error from the dialer's `Control` — with a password no SYN is ever sent on this kernel |
| the manifests (C2) | 10a differs from the base DaemonSet by `vip_arp` and the BGP env only; 10b by the two election flags; the doors: class, pins, `replicas: 2`, required anti-affinity, ETP Cluster/Local; the routes on the right doors; live: both door Services `Cluster` at `.10/.11`, Envoy pods one per node |
| sessions and paths (C3) | 4/4 Established (`pfxRcd 2` each); leaf1 two node paths for `.10`, `multipath`, best by *Older Path*; the spine two nexthops; `SERVERS-IN` seq 10 (`EG-POC1-VIPS` + `as-path EG-POC1`) invoked 72, seqs 20–61 invoked 0 |
| from the outside world (C4) | `client0` 200 + `x-served-by: eg-poc1`; `tcptraceroute … 80` → edge → spine → leaf2 → `10.98.0.10 [open]`; T2/T4/T5/T8b re-run as recorded; `arping` 0 replies on `.10`, `.100`, `.101` |
| nothing else moved (C8) | 21 files in the diff; the fabric's configs identical to `edae9cc`; demo 52's check 21 PASS; poc1/poc2 `Exited (137)`; `kind-eg` = four nodes + two leaves |

## Findings, accepted and applied

| # | Finding | From | Fix |
|---|---|---|---|
| A1 | **the HA half of the demo never ran** — `41-shopapi-ha.yaml`'s rollout deadlocked in runs 7–9 (`Progressing=False ProgressDeadlineExceeded`, a Pending pod each time: the anti-affinity also matches demo 54's running pod, and the default 25 %/25 % strategy on two replicas is one surge, zero unavailable — the new pod can never be placed); the two shopapi pods behind every measurement were demo 54's, spread by the scheduler's default; `apply.sh` waited for `Available` (the old ReplicaSet keeps it True) and `check.sh` read only ready pods and nodes | OB3 C2 (most important) | `strategy: maxSurge 0 / maxUnavailable 1`; `rollout status` instead of `wait --for=condition=Available`; the check row requires `updated == replicas == spec`; contract case (f) |
| A2 | scenario B's sentence overreached the ticks: after the node's endpoints were pruned (t+43) 2 of 4 probes still timed out (t+56, t+63). The events say why — the Envoy Gateway **controller** (one replica) sat on the paused node, so the surviving Envoy never received the pruned shopapi endpoint (EG v1.9.1 marks an endpoint draining only when it re-translates, `route.go:3363-3390`). And the grace period is **50 s** on v1.36 (`--node-monitor-grace-period` default; no flag on this cluster), not the "≈ 40 s" written | OB3 C5, Codex F2, Grok | the loop records the door's EndpointSlice and the controller's node per tick and counts post-not-ready probes; the summary names all of it; the pages say a silent node needs BGP, the grace period **and** a live control plane for the door |
| A3 | the ARP-absence judge passed on a broken probe: `Timeout connecting to Docker daemon` and `arping: socket error` both read as "0 replies" (the PASS branch matched `ARPING\|Timeout` case-insensitively) | Codex C6 (its most important), OB3 C6 | the PASS branch requires busybox's own `Received 0 response(s)`; contract case (g) |
| A4 | the TCP traceroute never ran — BusyBox `traceroute` has no `-T`; `\|\| true` swallowed *"unrecognized option: T"* in runs 5–9, so the record has no hop list | Grok C4, Codex F1, OB3 C4 | `tcptraceroute -n -m 8 -w 2 10.98.0.10 80` (in netshoot), no `\|\| true`; one sentence on why the UDP form escapes past the node (probes to 33434+ match no kube-proxy rule; the VIP is not a local address in BGP mode) |
| A5 | the "three paths on leaf1" sentence was inferred: the ninth run's leaf1 has two; the bounce (`65100 65101 65021`) lands on whichever leaf the spine did **not** pick as best — leaf2 now, leaf1 in run 7 | OB3 C3, Grok C3 | the pages say exactly that; the judges count node paths (nexthops in `172.19.0.0/17`) |
| A6 | a dead `kubectl` was judged as "node not ready" (`Ready=?` matched "not True"); the node-path counter also read `peer` IPs; the `SERVERS-IN` row summed every counter (any sequence would carry it); the summary table leaked into the check's output | OB3 C5/C6, Grok C5 | only `Ready=(False\|Unknown)` counts; nexthops only; seq 10 with both matches must be the one invoked; stdout silenced; `tests/apply56-judges.sh` |
| A7 | text the record refutes: "Established in 25 s" (every run says 3 s), "t+47", "no SYN on the leaf" (no tcpdump), the plan's §4/§9.2 still shipping `:lab-bgp:` inline, the 10a/10b headers teaching a password, a README link to the untracked `.env`, the election-mode log lines presented as observed (they are in the pod logs, not the transcript) | OB3 C1/C7, Grok C7, Codex F5 | corrected everywhere; the log grep now keeps kube-vip's mode/election lines so future runs record them; `tests/demo56-claims.py` (22 failures before, 0 after) |
| A8 | the verbatim test matched fences against all nine runs; the contract test's `mktemp` failure fell through | Codex F4, F6 | scoped to the last apply; guarded |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| "spine 2 paths" as the ECMP judge | brief C3 | the spine's two paths are the two leaves whatever the nodes do — measured with the leader alone; the leaf is where nodes show |
| pin or scale the Envoy Gateway controller in this demo | OB3 (volunteered) | a lab decision; recorded here and in demo 57's brief so its failure scenario does not inherit the blind spot |

After the fixes: the tenth `apply.sh` — the first with the anti-affinity actually running — re-recorded the migration, the
TCP hop list, the matrix and both failure scenarios with the post-grace counts and the controller's node; `check.sh`
recorded; every test under `tests/*56*` and `guide-structure.py` ×3 PASS under bash; `mdfmt` 0 issues. Reports:
`scratchpad/review_ob3_demo56.txt` (+ `fix/`), `scratchpad/review_grok_demo56.txt`, `scratchpad/review_codex_demo56.txt`.
**Owed:** OB1/OB2's second reading of OB3's passes (demos 46, 50, 51, 52, 54, 56 and the tier-1 docs).
