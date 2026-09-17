# Cilium 1.20.2 — what is new, and what it means for this lab

Source: the GitHub release [cilium/cilium v1.20.2](https://github.com/cilium/cilium/releases/tag/v1.20.2), published
2026-09-16T01:53Z, fetched 2026-09-17 with `gh release view v1.20.2 -R cilium/cilium --json publishedAt,body`. Counted
from the body's headings: **1 minor change, 39 bugfixes, 28 CI changes, 68 misc, 2 other — 138 bullets**, every one a
backport (each line names its `v1.20` backport PR and the `main` PR). The lab runs **1.20.1** — `CILIUM_VERSION` at
`scripts/lab-stack.sh:43` and `scripts/lab-preflight.sh:18`, the README's versions row, and the observer's `hubble`
CLI image `quay.io/cilium/cilium:v1.20.1@sha256:ae9ea21f…` at `demos/25-hubble-observer-loki/values-hubble-observer.yaml:14`.
Every "the lab meets it here" below was found by reading the lab's files, and every "not for us" names the value that
proves it.

## In one paragraph

A patch release: no feature the lab does not already have, one minor change it does not need (a node-label selector
for host-network Gateways), and a long list of fixes, of which five touch mechanisms this lab runs and measures — the
L2-announced VIPs, policy realisation for new pods (the connectivity test's setup), the agent under named-port policies
with pod churn, Gateway listener status, and Hubble's drop-event rate limit. One of them retires a constraint written
into enhancement 005 (`externalTrafficPolicy: Local` with L2 announcements). The image is built with Go 1.26.8, which
takes the agent image from 128 HIGH findings to 13 ([`../cilium-image-scan.md`](../cilium-image-scan.md)). **Verdict:
move**, at the cost of one agent rollout per cluster.

## What touches this lab

| Fix or change (upstream PR) | Where the lab meets it | Outcome |
|---|---|---|
| **L2 announcements dropped traffic when a Service had `externalTrafficPolicy: Local`** (#46399, `Fixes: #27800` — the lease now follows the node with a backend) | Enhancement 005 §2 and §5 rule it out: "`externalTrafficPolicy: Local` is incompatible with L2 announcements — not a knob here" (`enhancements/005-namespaced-gateway.md:160`, and `docs/REVIEW_ENH-005.md:12`). `l2announcements.enabled: true` at `cilium/values-poc1.yaml:130`. | **Changes a written constraint.** On 1.20.2 it is a knob for an ordinary LoadBalancer Service. For a Gateway it still changes nothing: Cilium's Envoy runs on every node, so every node has a "backend" and the lease can land anywhere — 005's finding stands for the reason it gave (the shared per-node Envoy), not for this one. Line 160 rewritten below. |
| **A pod created right after a policy change reported a stale policy revision for up to two minutes** (#47642: the endpoints a new rule does not select get their revision bumped without regeneration) | The symptom is `cilium connectivity test`'s "N endpoints have not yet realized policy revision R" during setup — the test the CI runs (`.github/workflows/lab-observability.yaml:222`, `--multi-cluster`). Demo 26/35's loop (apply a cf2cnp policy, then probe) has the same shape. | **Fixes something we run.** Fewer flaky setups; no lab file to change. |
| **Agent crash `fatal error: concurrent map iteration and map write`** when an endpoint's policy was recomputed while incremental map changes applied — "most commonly triggered by named-port policies under pod churn" (#48098) | The common trigger is not ours: every CiliumNetworkPolicy in the demos names ports by number (`grep -rn 'port: "[a-z]' demos/*/policies demos/15-bank` → none). The race itself is generic — a policy recompute during incremental map changes — and demos 15/26 do churn pods while policies apply. Not seen on this lab. | **Could hit us, has not.** A crash class removed. |
| **Identities lingered for twice the expected time** (#48032: an Upsert is not evidence of use) | Every demo's cleanup leaves identities to be garbage-collected; `cilium identity list` after a teardown. | Neutral; cleaner identity GC. |
| **Gateway listeners never persisted `Programmed=True`** (#48013: the loop mutated a range copy) | Demo 37's transcript shows `Programmed=True` at the **Gateway** level for both doors (`demos/37-two-gateways/README.md:84-85`); the per-listener condition is what this fixes. | **Fixes a status we read.** After the upgrade `check.sh` can assert `status.listeners[*].conditions[Programmed]`. |
| **Hubble: the drop-event rate limit was charged for suppressed events too**, plus three knobs that never reached their sink (#47637: `hubble.export.static.aggregationInterval`, operator `enable-metrics`, `hubble.metrics.tls.server.mtls.name`) | The lab uses the **dynamic** exporter (`cilium/values-hubble-export.yaml:20`), not static — the aggregation knob is not ours; the other two values are not set. The drop rate limit is: demos 26 and 35 feed cf2cnp from dropped flows. | **Fixes something we run**: fewer legitimate drop flows lost under a drop storm. |
| **Hubble Relay kept running on termination** (#47942: the gRPC health server was never stopped) | Every `helm upgrade` of Cilium rolls the relay (demo 16's stack, demo 25's observer talks to it). | Neutral; cleaner rollouts. |
| **`policy-deny-response: icmp` zeroed the egress `policy_denied` drop metrics** (#48407) | Not set: `grep -rn policy-deny-response cilium/ demos/` → nothing. Demo 26's verdict dashboards read exactly those metrics. | **Not for us today** — worth knowing if ICMP replies are ever turned on for the deny demos. |
| **Cluster Mesh: a removed remote cluster could fail to disconnect** (rare race, #48262); **stronger validation of backends ingested from the mesh** (#48015) | Demos 21–24 and the poc3 add-then-remove exercise (gotchas #92–#94, #96: the mesh declared before the peer exists, one pool file for two clusters, `useAPIServer` without the mesh). | **Could hit us** — the remove path is the one the lab exercises least; nothing recorded. |
| **Envoy image bumped three times** to `v1.37.6-1789133542` (#48674) | The shared per-node Envoy demo 37 measured (11.5k / 11.5k qps split through two doors). | Neutral; re-run one `load-both` phase after upgrading to see whether the split moves. |
| **Five accepted-but-ignored options** (#47635: `vtep-sync-interval`, `enable-xt-socket-fallback`, `eni-delete-on-termination`, `enableIdentityMark` outside chaining, `lb-retry-backoff-max`) | None in `cilium/values-*.yaml`. | Not for us; the class (a value Helm accepts and the agent drops) is what gotcha #116 is about for Hubble metrics. |
| **LocalRedirectPolicy regressions** (#46638, `Fixes: #43944 #43929`) | `localRedirectPolicy: true` at `cilium/values-ci.yaml:15`, but no `CiliumLocalRedirectPolicy` object anywhere in the repository. | Enabled, unused. Nothing to do. |
| **Gateway API: node label selector for `hostNetwork` Gateways** (the one minor change, #47463) | Our Gateways are LoadBalancer Services on LB IPAM + L2 (`cilium/lb-ippool-*.yaml`). | Not for us. |

## Not for us

Skipped with the value that proves it: the ENI / AWS / GKE / Azure IPAM items (`ipam.mode: kubernetes`,
`cilium/values-poc1.yaml:24`); DSR and Geneve dispatch (SNAT mode, no `loadBalancer.mode`); IPv6 Router
Solicitations and ENI IPv6 (single-stack v4 — no `ipv6` key in the values); BGP `defaultGateway` auto-discovery
(`docs/summary/BGP_FRR_PLAN.md` is a plan, BGP is not running); the `CiliumNodeConfig v2alpha1` upgrade path (clusters
created on 1.20); WireGuard fragment misclassification (#48139 — `encryption.enabled: false` at baseline,
`cilium/values-poc1.yaml:160`; demo 04 turns it on and off, so it is the one "not for us" that becomes "for us" for the
length of a demo); nodeport egress tuple reuse for closed connections (#48306 — the lab's one NodePort Service is the clustermesh-apiserver of demo 24, `demos/24-clustermesh-enterprise/poc1.yaml:15`, reached by the peer's agents over long-lived etcd connections; the fix is about closed connections' tuples, so neutral here).

## Security

Same release, scanned the day after ([`../cilium-image-scan.md`](../cilium-image-scan.md)): trivy 0 CRITICAL /
**13 HIGH** against 1.20.1's 0 / **128**; grype 7 High against 55. The 13 are the Ubuntu base image's `pebble` binary
(8, never started) and grpc/x/crypto module versions whose vulnerable packages are not linked into Cilium's binaries.

## Cost of moving

- Pins: `CILIUM_VERSION` `scripts/lab-stack.sh:43`, `scripts/lab-preflight.sh:18`; the observer's CLI image tag
  `demos/25-hubble-observer-loki/values-hubble-observer.yaml:14` → `v1.20.2@sha256:2939231d0d3e3ebddcd80fffa168b7ddcc78fdf0dc864d1c8c126ff523c54f01`
  (from the release's *Docker Manifests*); the README's versions row and its line 3.
- Operation: `helm upgrade cilium cilium/cilium --version 1.20.2 -n kube-system --kube-context kind-poc1 --reuse-values`,
  `kubectl rollout status ds/cilium`, then the same on poc2. One agent rollout per cluster = the Gateway off the air
  (gotcha #42; ~45 s measured under #116), the L2 leases re-elected, the relay and the observer restarted.
- Verification: demo 37 `check.sh` (both doors, the routes, the leases), `https://grafana.poc.local` and the three lab
  dashboards, the observer's flow table, `cilium status` on both clusters; then a green `lab-observability` run on the
  branch — the CI builds the whole lab from the pins.
- The operator decides when; the clusters are theirs to interrupt.

## Documentation this changes

- `enhancements/005-namespaced-gateway.md:160` — from "incompatible with L2 announcements — not a knob here" to: a knob
  since 1.20.2 (#46399), and why it still does not isolate a Gateway (Envoy on every node).
- `README.md` versions row: 1.20.1 → 1.20.2 when the pin moves; line 3 likewise.
- `docs/upstream/README.md` §5 — this report's row.

## Actions

Done, 2026-09-17 on the operator's word ("then proceed"): **both clusters on 1.20.2** (`cilium status`: `v1.20.2@sha256:2939231d…`
on 2/2 agents each; ClusterMesh connected both ways; Hubble metrics from both clusters in Grafana — poc1 214.5, poc2
39.6 flows/s two minutes after). The first attempt with `--reuse-values` changed the chart and not the image —
**gotcha #117**; the second, with `--reset-then-reuse-values`, rolled poc1 in 100 s (agents at +29 s) with the user
values byte-identical before and after, and poc2 in 35 s. Measured cost on poc1: the Gateway answered nothing for
**121 of the seconds between +6 s and +138 s** (the Envoy DaemonSet rolls too when the release bumps its image; #116's
~45 s was an agent-only restart), the four L2 leases re-elected onto the worker. Demo 37's `check.sh` before/after:
identical apart from pod names and lease holders; all six listeners `Programmed=True` (no 1.20.1 record of the
per-listener condition exists, so #48013 is not *measured* here — `check.sh` now prints the line so the next release
can be). Pins moved: `lab-stack.sh`, `lab-preflight.sh`, `lab-up.sh`, `scripts/bootstrap/versions.env` (the bootstrap
refuses a disagreement with `lab-up.sh`), the observer's CLI image digest, `apply-poc2.sh`, `mtls-check.sh`, the README.
Left: demo 37's `load-both` on the new Envoy — a separate run when the host is quiet. Watch: the next patch (Cilium's cadence is three to four weeks — 1.20.1 on 08-18, 1.20.2
on 09-16) should carry the `v1.20` grpc/x/crypto bumps the scan report's §5 describes.
