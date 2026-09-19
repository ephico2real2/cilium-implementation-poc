# Review — demo 52, MetalLB alone on `eg-poc2` with the gRPC test matrix (2026-09-19)

Three reviewers on one brief (`scratchpad/review_brief_demo52.md`, nine claims: the lab; MetalLB class-only; its L2
announcement seen from Docker; the gRPC app and routes; the matrix; `check.sh`; `cleanup.sh`; the docs; what must not
have moved), judged against the operator's asks — *"do demo with metallb as well. same design as sample app but i would
love to see more grpc testing"*, *"use eg-poc2"*. **OB3** (`.claude/agents/ob3.md`, Opus 5; 121 tool uses, 29 min; deep
on C1 with a stub-harness path diff, C3 with MetalLB v0.16.0's source and the worker's iptables, C5 with the matrix
re-run from the Mac plus raw h2c calls for T8b/T9 and a dead-door probe, C6 under three stubs, C7 with a logging shim
and `helm get manifest`); **Codex** (sandbox without cluster, Docker or file writes; code findings measured in memory);
**Grok** (Cursor `cursor-grok-4.6-high-fast`; shell rejected — the tree and the record). Every accepted finding was
re-verified by the orchestrator live or in the sources before Cursor applied it from the reviewer's snippet.

Under review: branch `demo-52-eg-poc2-metallb` at `bbeda57` (demo + docs) on `main` `7868d97`.

## What held on the wire (OB3 and the orchestrator, live)

| Claim | Evidence |
|---|---|
| the lab (C1) | `eg-up.sh eg-poc2` mints its own root (`A3:D7:73…`); `eg-poc1 eg-poc2`, `eg2`-while-`eg-poc2` and the reverse → exit 2 after one `kind get clusters`; eg-poc1's path identical to `7868d97`, the two-cluster path differs by that one read-only call |
| MetalLB, class-only (C2) | `helm list` metallb-0.16.0; `--lb-class=metallb.io/metallb` on controller and speaker; one speaker container, no FRR; pools doors `.150–.160` autoAssign false, services `.136–.143` true; both Envoy Services class `metallb.io/metallb`, ingress `.150/.151`, `ip-allocated-from-pool: eg-poc2-doors`; both `externalTrafficPolicy: Local`; no kube-vip anywhere |
| L2 from Docker (C3) | `arping -b` 3/3 from `36:20:3a:e4:50:8d` = `eg-poc2-worker` for both doors; `ServiceL2Status` (in `metallb-system`) names the worker for both; events `IPAllocated` + `announcing from node`; nothing on any `eth0` — the mechanism in `internal/layer2/arp.go:73-118` (replies with the node MAC; no netlink AddrAdd in layer2) and delivery in the worker's iptables (`KUBE-SERVICES -d .150/32 → KUBE-EXT → KUBE-SVL → KUBE-SEP 10.80.1.10:10080`); the control-plane DROPs ("has no local endpoints") |
| the app and routes (C4) | `go vet`/`go test` clean; `gen/` regenerated with buf v1.73.0 → empty diff; image 20,298,701 B nonroot; `attachedRoutes` 1/1 on all four listeners; the precedence from the CRD (`grpcroutes.yaml:1638-1655`) and Envoy Gateway v1.9.1 (`route.go:1852-1868`, `sort.go:19-137`): reversing the file order changes nothing |
| the matrix (C5) | all 14 tests re-run from the Mac as recorded; T8b on the wire = `HTTP/2 200` + `grpc-status: 12` with no message (Envoy's trailers-only "no route"); T9 = Envoy forwards `grpc-timeout`, grpc-go resets the stream at 1.004 s (`http2_server.go:600-612`), grpcurl's `DeadlineExceeded` is its own context |
| nothing else moved (C9) | 40 files in the diff, all in scope; demo 54's check 15 PASS; poc1/poc2 `Exited (137)`; `kind` network empty |

## Findings, accepted and applied

| # | Finding | From | Fix |
|---|---|---|---|
| A1 | **`cleanup.sh` could not finish** — MetalLB's chart templates its nine CRDs (`helm show crds` = 0, `helm get manifest` = 9), `helm uninstall` removes the types, and the pool deletion after it exits 1 (`--ignore-not-found` does not cover a vanished type); under `set -e` the namespace was never deleted; never exercised in the record | OB3 F3 (most important) | pools and advertisement emptied BEFORE the uninstall, guarded by the CRD's existence; `tests/cleanup52-order.sh` (a stub answering like the server after uninstall) |
| A2 | T11 passed on ANY non-zero exit — a dead door (`.152`, "context deadline exceeded") passed "bogus CA" | OB3 F1, Grok, Codex F2 | requires `failed to verify certificate` beside rc≠0, `-max-time 10`; `tests/apply52-matrix-t11.sh` |
| A3 | T6 counted `"item"` substrings, not stream objects — a five-item `ListOrders` body passed "5 events"; a stream that failed after five events passed too | Grok C5 (its most important), Codex F2 | objects with an `order` key counted by `raw_decode`, rc=0 required — apply and check; contract stub |
| A4 | weak payload judges: T2 not exactly three orders, T3 version only, T4 and the check's v2 rows without `served_by: grpcdemo-v2-` | Codex F2, Grok | exact counts and prefixes; a `{"version":"v2"}`-only stub now FAILs |
| A5 | the ARP rows passed with `node=?` (a foreign MAC) | OB3 F2, Grok C6, Codex F3 | `[ -n "$node" ]`; contract (g) |
| A6 | the docs stated the worker as a fact with no mechanism; the `ServiceL2Status` row accepted any node | OB3 F4/C3 | the row requires the announcing node to run that door's Envoy pod (ETP Local); README §6/§7 and the RECAP carry the sourced mechanism (`speaker/layer2_controller.go:83-129` — `nodesWithEndpoint` before the sha256 ordering; the ARP responder; kube-proxy's chains; T8b's `200/12`; T9's `grpc-timeout`); contract (h) |
| A7 | nits that mislead: `50-routes.yaml`'s comment named a "method+header" rule that does not exist; the RECAP's table was not in precedence order; `nope.proto` said "404"; plan D8 named one root while three labs export three | OB3 F5/F6/F7, Codex F4 | the CRD's own precedence text; table reordered; `200 + grpc-status 12`; D8 names the three roots; rule 4 of the skill now admits the demo's own manifests/scripts as a source, linked |
| A8 | `tests/eg-up-labs.sh` had no case for `eg2` while `eg-poc2` exists (the code was right) | OB3 F8, Grok C1 | case (g) |
| A9 | a FAIL row in the matrix never affected the apply's exit | Codex F1 (volunteered) | the function counts FAIL rows and returns them; `apply.sh` exits 1 at its very END, after the whole record; `tests/apply52-matrix-fail.sh` |
| A10 | the doc claims above as a test | OB3 | `tests/demo52-claims.py` — 9 findings on `bbeda57`, 0 after |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| "the Envoy Services default to `externalTrafficPolicy: Cluster`, so both nodes were eligible" | Grok C3 | measured `Local` on both (Envoy Gateway's default); the worker was the only candidate by `nodesWithEndpoint` |
| aborting the apply on a matrix FAIL | Codex F1 as stated | the record must be complete; the exit code at the end carries the verdict |

After the fixes: the third `apply.sh` re-recorded the matrix under the stricter judges (14 PASS, `gRPC matrix: 0 FAIL`) and
`check.sh` 21 PASS; every test under `tests/*52*`, `tests/eg-up-labs.sh`, `tests/eg-up-root-home.sh`, `tests/demo52-claims.py`,
`tests/readme52-verbatim.py` and `guide-structure.py` ×3 PASS under bash; `mdfmt` 0 issues. Reports:
`scratchpad/review_ob3_demo52.txt`, `scratchpad/review_grok_demo52.txt`, `scratchpad/review_codex_demo52.txt`. **Owed:**
OB1/OB2's second reading of OB3's passes (demos 50, 51, 54, 52 and the tier-1 docs).
