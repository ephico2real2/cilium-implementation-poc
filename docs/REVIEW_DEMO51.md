# Review — demo 51, Envoy Gateway with kube-vip alone (2026-09-18/19)

Three reviewers on one brief (`scratchpad/review_brief_demo51.md`, nine claims: the class contract and the two flags;
the three addresses; one ARP responder per address; the move script and the measured gap; the R7 experiment; gRPC and
the six-name certificate; `check.sh`; the docs; what must not have moved): **OB3** (`.claude/agents/ob3.md`, Opus 5 —
the Fable quota still out; 90 tool uses, 27 min; deep on C3 with `tcpdump` on the bridge, C4 with kube-vip's logs on
all four nodes and its v1.2.4 source, C7 with three `kubectl` shims, C1's flag semantics from the pinned sources;
medium on C1 live, C2, C5, C6 — every `grpcurl` and `openssl` call re-run; grep on C9); **Codex** (sandbox without
cluster or Docker: live verdicts PLAUSIBLE from the transcript, code findings measured; its report saved by the
orchestrator from the hand-back); **Grok** (Cursor `cursor-grok-4.6-high-fast`; every shell call rejected by its sandbox,
so its verdicts read the code and the transcript). Every accepted finding was re-verified by the orchestrator against the
live clusters or the code before Cursor applied it from the reviewer's snippet; the tests are under `tests/`.

Under review: branch `demo-51-eg-kube-vip` at `a05312a` (demo 51 + the README count) on `main` `018fc6b`.

## What held on the wire (re-measured by OB3 and the orchestrator)

| Claim | Evidence |
|---|---|
| the class contract (C1, D11) | three Envoy Services `loadBalancerClass=kube-vip.io/kube-vip-class`, `probe-noclass` `<pending>` with no `implementation` label and no `loadbalancerIPs` annotation; DS env `lb_class_only=true svc_election=true`, cloud-provider `KUBEVIP_ENABLE_LOADBALANCERCLASS=true`; the semantics from kube-vip v1.2.4 `pkg/services/watch_services.go:155-158` ("…didn't specify any loadBalancer class, ignoring" — that line is in both DS logs for `probe-noclass`) and cloud-provider v0.0.12 `main.go:60-63` (the default service controller is not started at all) |
| the addresses (C2) | Gateway `status.addresses` = Service `status.loadBalancer.ingress` = `.240 / .16 / .176`; `.16` outside all four ConfigMap ranges, allocated by annotation (cloud-provider `pkg/provider/loadBalancer.go:215-219`, no range check) |
| one responder (C3) | `arping` 3 of 3 from one MAC on each address, `-b` the same; `tcpdump -e arp` on the bridge: the only gratuitous ARPs for `.16` come from `eg1-worker`, never an eg2 MAC — a second responder refuted |
| the move (C4) | delete-other-first confirmed by a logging `kubectl` shim; `--status` correct; bad arguments exit 2; the arithmetic of both gaps re-done |
| R7 (C5) | `externalIPs=['.245'/'.181']`, `status.loadBalancer={}`, 0 ARP replies, `probe-noproxy` NotFound on both |
| gRPC + TLS (C6) | nine `grpcurl` calls SERVING/`list` re-run; `openssl s_client` for the six names: leaf CN `api.eg.poc.local`, issuer `eg-root-ca`, six SANs, `Verify return code: 0 (ok)` against `.tmp/eg-root-ca.crt` |
| nothing else moved (C9) | demo 50 `check.sh` 27 PASS; the poc nodes `Exited (137)`; the `kind` network unchanged; `lab-up.sh`, `versions.env`, `lab-regression.sh` empty diff |

## Findings, accepted and applied

| # | Finding | From | Fix, measured |
|---|---|---|---|
| A1 | **`eg-vip-move.sh` deleted the other cluster's Gateway but never waited for its Envoy Service** — the object kube-vip announces, owned by the GatewayClass (no GC), held by `service.kubernetes.io/load-balancer-cleanup`; it went 66 ms after the Gateway in the first run, unbounded with the cloud-provider down (OB3's most important finding) | OB3 F5 | `kubectl wait svc -l gateway.envoyproxy.io/owning-gateway-name=eg-vip-gw --for=delete --timeout=60s` after the deletes (no match → exit 0 in 36 ms, so a same-target rerun is unaffected). `tests/eg-vip-move-waits-for-service.sh`. Re-run: `condition met` on the source's Service before the target apply; the target saw the new Service 217 ms / 104 ms after the source's `Deleting VIP` |
| A2 | the "no metallb-system" row **PASSed on any failed `kubectl`** — demo 50's defect again | Codex F3, OB3 F1, Grok's shim | rc captured; 0 → FAIL; `NotFound` in the output → PASS; anything else → FAIL "kubectl failed: …". `tests/check51-metallb-row.sh` |
| A3 | "probe-noclass stays pending" read the Service once (no elapsed time) and never looked for kube-vip's claim marks — phase 0's claimed-but-pending state (`implementation=kube-vip` + `loadbalancerIPs`) would PASS | OB3 F2, Grok F1, Codex F3 | age from `creationTimestamp` ≥ 30 s, and `implementation` label and `kube-vip.io/loadbalancerIPs` annotation both empty; no sleep loop. `tests/check51-noclass-age.sh` (fresh → FAIL, 120 s pending → PASS, 120 s claimed → FAIL) |
| A4 | `\|\| echo 000` at three sites — curl prints `000` itself; measured `http_code=000000` | OB3 F3, Grok F2, Codex | `\|\| true`; the fail row prints `${code:-000}`. `tests/check51-curl-000.sh` |
| A5 | **every HTTPS probe passed `-k`, so `--cacert` verified nothing** — the orchestrator measured `curl -sk --cacert /dev/null` → 200, `-s --cacert /dev/null` → 000, `-s --cacert .tmp/eg-root-ca.crt` → 200 (four sites) | Codex F2 | the `k` removed everywhere; `tls_leaf_probe` (`openssl s_client -servername -verify_hostname -CAfile -verify_return_error`) recorded for the six names. `tests/apply51-tls-leaf.sh` — six `TLS leaf … verify=ok` lines in the transcript |
| A6 | `grep -q SERVING` accepted `NOT_SERVING` (two check rows, `final_table`'s python) | Codex F3; `final_table` seen by Cursor | exact `"status": "SERVING"` match. `tests/check51-grpc-serving.sh` |
| A7 | the Gateway rows read only `status.addresses` — R7 proved that field can be filled from `externalIPs` with `status.loadBalancer={}` | Codex F3 | the row also requires the generated Service's `ingress[0].ip` = the wanted address (`svcIngress=` in MEASURED) |
| A8 | the R7 clean-up was an echo, not a recorded NotFound | Codex F1 | `r7_assert_deleted` — a `get` that must fail with `(NotFound)`; recorded on both. `tests/apply51-r7-deleted.sh` |
| A9 | the probe loop could not say why a probe failed; the docs explained the gap by the wrong step ("delete + roll a Deployment") | OB3 F7, C4 | each sample records curl's exit; the parser prints `fail_kinds`. Re-run: `000/curl28 ×6, 000/curl7 ×2, 404/curl0 ×1` (to eg2) and `curl28 ×6, curl7 ×3` (back). kube-vip's logs: **10.837 s / 10.909 s with no announcer** = the new Envoy pod turning Ready (created 00:41:20Z, Ready 00:41:31Z); kube-vip elects only among nodes with a ready LOCAL endpoint (`pkg/services/leader.go:98-102`, `pkg/endpoints/endpoints_generic.go:93-95`; the Service is `externalTrafficPolicy: Local`) — which is why `eg2-control-plane` answered after the move. `tests/apply51-move-probe-kinds.sh` |
| A10 | `arping -c 3` was one broadcast and two unicasts to the first responder (busybox goes unicast after the first reply — `tcpdump`); the RULE said R7 for the reader's test | OB3 F4, Grok/OB3 unasked | `-b`; `R4 / R8`. `tests/check51-arping-broadcast.sh` |
| A11 | the RECAP's review line said "not run"; GUIDE exercise 3 promised a routing error where the reader sees a reflection error (the reflection call carries the same `:authority`) | OB3 C8/F6e, Codex F4, Grok F3 | RECAP review section from this record; GUIDE quotes the measured error; README/RECAP carry the gap's composition. `tests/docs51-review-and-gap.sh` |
| A12 | **the orchestrator's own catch on Cursor's fix for A9:** `apply.sh` runs under `set -euo pipefail`, and the bare `code=$(curl …)` in the background probe loop kills the subshell on the first failed probe — the old `\|\| echo 000` had been load-bearing. OB3's and Cursor's tests sourced the function without `set -e` and passed | orchestrator | measured: 0 samples with the bare assignment, 3 with `\|\| rc=$?`; the guard added, and the test now runs `measure_move` under `set -euo pipefail` (FAIL "no summary" on the unguarded copy, PASS after) |

## Rejected, with the reason

| Finding | From | Why not |
|---|---|---|
| a 12 × 5 s polling loop / a `PROBE_NOCLASS_SETTLE_SECONDS` sleep before the class-less row | Grok F1, Codex F3 | the Service's age already carries the elapsed time; a check that sleeps a minute measures nothing more |
| rewrite the whole of `r7_one` | Codex F1 | only the post-delete assertion was missing |
| `curl -sS` | Codex F2 | stderr is discarded on every site; `-s` with `--cacert` is the whole fix |
| change the Envoy pod's probes to shrink the gap | OB3 (not proposed) | a design change; demo 52's comparison must run the same probes on both LBs or it compares Envoy, not the LB |

After the fixes: `apply.sh` re-run end to end (idempotent — every object `unchanged`/`configured`, R7 repeated and
cleaned with a recorded NotFound, both moves re-measured, six leaves verified, `check.sh` 39 PASS recorded
2026-09-19T00:42:08Z); `check.sh` 39 PASS and demo 50's 27 PASS again live; the VIP back in eg1, `eg1-worker`
answering; every test under `tests/*51*` and `tests/eg-vip-move-waits-for-service.sh` PASS under bash; every `.md`
0 issues. Reports: `scratchpad/review_ob3_demo51.txt`, `scratchpad/review_codex_demo51.txt`,
`scratchpad/review_grok_demo51.txt`. **Owed: OB1/OB2's second reading of OB3's passes on demos 50 and 51** (the
skill's rule), and OB1's passes on demos 41 and 53.
