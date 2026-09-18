# Draft — a review comment on cilium/cilium#48563 "hubble: Populate workloads for remote endpoints"

**Status: POSTED 2026-09-18 on the operator's word ("Post it") — https://github.com/cilium/cilium/pull/48563#issuecomment-5725111947.** The text below is what went out (the links pinned to commit `4ef5d94`, so they outlive the branch). Written 2026-09-18 after OB1 (Fable 5.1) and Codex reviewed the lab's own fix
(`docs/REVIEW_CILIUM_FIX.md`) and both pointed at #48563 as the upstream work this should join rather than compete
with. Per the operator's rule: OB1 has reviewed the work; this text waits for the operator's reading and word.

Existing-issue / existing-PR check (done this time): cilium/cilium#25676 (the bug, open since 2023; our measurement
is comment 5723156870 there); #36011 (closed 2025-04-29, CEP-only); **#48563 (open draft, devodev, 2026-09-08, 46
files, `release-note/minor`, `ail:4`)** — carries `Workload` on the CEP and the CES, `IPIdentityPair` for the kvstore,
all three parsers, a cilium-cli connectivity test. Its files do not include `pkg/k8s/apis/cilium.io/register.go`
(checked: 0 matches), i.e. no `CustomResourceDefinitionSchemaVersion` bump.

## The comment, as it would be posted

> Tested the idea of this PR on a two-node kind cluster (Cilium v1.20.2, Gateway API, `enable-cilium-endpoint-slice`
> off), where it reproduces the case from #25676 that hurts most: HTTP through a Cilium Gateway is reported by the
> Envoy on the **client's** node, so the backend is remote whenever client and backend are on different nodes, and
> `destination_workload` is empty for most Gateway traffic. Two things from that test that may be useful here:
>
> **1. The L7 parser needs the change too — and it is the parser that reports Gateway traffic.** With the workload
> carried on the CEP and read into the ipcache, and only `pkg/hubble/parser/common` (the L3/L4 path) reading it, the
> worker's agent named the remote workload on `hubble observe` (L3/L4: `destination.workloads=[{Deployment shop}]`) and
> still not on the Envoy-reported flow (`hubble_http_requests_total{…destination_workload=""}`), because
> `pkg/hubble/parser/seven/parser.go` resolves endpoints on its own (`GetK8sMetadata` for namespace/pod, then
> `updateEndpointWorkloads` from the local endpoint getter). Your diff touches `seven/parser.go`, so you have this
> covered — I mention it because it is the half a test on a single node cannot see, and the connectivity test in this
> PR runs the client and the echo on different nodes only if the scheduler happens to place them so. One more edge we
> hit in the seven parser once the metadata was consulted first: a **local** pod with no owner (a bare Pod) must clear
> the metadata's value, or a stale workload survives where it used to be nil.
>
> **2. `CustomResourceDefinitionSchemaVersion`.** `pkg/k8s/apis/cilium.io/register.go` says "Developers: Bump patch
> for each change in the CRD schema", and the operator updates an existing CRD only when the cluster's
> `io.cilium.k8s.crd.schema.version` label is lower than the compiled constant. Without the bump, a cluster that
> already has the CEP CRD keeps the old schema, and because the CEP status has no `x-kubernetes-preserve-unknown-fields`
> the agent's `status.workload` is **pruned silently** — the JSON patch succeeds, nothing is logged, Hubble sees nothing.
> We hit exactly that on the first deploy (the fix was applying the regenerated CRD by hand and setting the label). The
> PR's file list does not seem to include `register.go`; if that is right, the bump (and a line in the upgrade notes
> that the operator must run the new image before the agents) would make the upgrade path work for existing clusters.
>
> Measured after both halves on the two-node lab (backends on the control plane, client on the worker, 40 requests
> per team): the worker's agent reports `destination_workload="shop"` for both teams' Gateways, and the chart's *Hubble
> L7 HTTP Metrics by Workload* dashboard fills for the remote backend where it was "No data" — the same selection
> (cluster `poc1`, destination namespace `team-a`, destination workload `shop`, reporter `client`), before and after:
>
> ![before: Cilium's L7-by-Workload dashboard, No data on every panel for a backend on the other node](https://raw.githubusercontent.com/ephico2real2/cilium-implementation-poc/main/docs/upstream/images/l7-by-workload-team-a-no-data.png)
>
> ![after: the same dashboard filled — red the Destination Workload selector, orange requests/s, yellow success rate, blue latency](https://raw.githubusercontent.com/ephico2real2/cilium-implementation-poc/4ef5d94952c19566bb2385140cad31e25b720ef9/demos/39-remote-workload-fix/output/l7-by-workload-shop-team-a-highlighted.png)
>
> **How it was tested** (two kind clusters on one machine, Cilium v1.20.2 + the three commits of
> `ephico2real2/cilium@hubble/remote-workload-via-cep`; the image built with `make dev-docker-image`, loaded into all
> four nodes; the regenerated CEP CRD applied and labelled `io.cilium.k8s.crd.schema.version=1.33.13` on both clusters
> before the agents rolled; the same image on both clusters):
>
> 1. Unit tests, run as `linux/arm64` test binaries in a container (Darwin cannot run them): the new
>    `TestResolveEndpointRemoteWorkloads` (common resolver, remote branch), `TestDecodeL7Workloads` with three cases —
>    remote from the ipcache, a local pod overriding, a local *ownerless* pod clearing a stale value — and the CEP
>    watcher / status-writer tests. All pass; each fails with its change reverted.
> 2. The cluster measurement, before and after — the `shop` backends of `team-a` and `team-b` on the control-plane
>    node, the client pod on the worker calling the two Gateways (`curl --resolve … https://shop-a.poc.local/`, 40
>    requests each), then the **worker's** agent's `hubble_http_requests_total` read directly
>    (`curl http://<node-ip>:9965/metrics`):
>    - release v1.20.2: `destination_namespace="team-a" … destination_workload="" source="reserved:ingress"` (and the
>      same for team-b) — the bug;
>    - commit 1 only (CEP + ipcache + the common resolver): `hubble observe` on an L3/L4 flow to the same pod shows
>      `destination.workloads=[{Deployment shop}]`, the Envoy-reported series still `destination_workload=""`;
>    - all three commits: `destination_workload="shop"` on both teams' series, 40/40, reporter `client`,
>      `source="reserved:ingress"`.
> 3. The chart's *Hubble L7 HTTP Metrics by Workload* dashboard for that selection: the two pictures above.
> 4. The lab's regression check on the patched clusters (14 rows — versions, agent health, mesh, the Gateway's names,
>    listeners, L2 leases, Hubble metrics from both clusters, drops and forwards, the flow observer, dashboards):
>    14 PASS on both clusters running the build (the version row pinned to it); `cilium status` OK and ClusterMesh
>    OK on both.
>
> What is NOT tested here: CiliumEndpointSlices (the branch does not carry the field on the slice) and a backend in
> the *other* cluster of the mesh (the kvstore path) — the two things this PR covers and ours does not, which is why
> this is a comment and not a competing PR. Happy to run this PR's branch on the same lab and report, if that helps it
> out of draft. Details, the exact commands and the capture scripts:
> https://github.com/ephico2real2/cilium-implementation-poc/blob/4ef5d94952c19566bb2385140cad31e25b720ef9/demos/39-remote-workload-fix/README.md
>
> (AI assistance, declared under the Cilium AI policy: I directed the work and designed the test cases — the remote
> placement of the backend, the client on the other node, the same image on both clusters, the before/after
> captures; Claude Code carried out the code reading, the fork's branch and the measurements under that direction,
> with Cursor implementing from briefs and Fable and Codex as adversarial reviewers. Every number above was run and
> read by me before posting.)

## Before posting (done)

- [x] the operator has read this file and said "post" ("Post it.", 2026-09-18)
- [x] the after-image and README links pinned to commit `4ef5d94` instead of a branch (#40 not yet merged; a pinned
      URL survives the branch's deletion)
- [x] #48563 re-checked before posting: OPEN, draft, last updated 2026-09-16, `register.go` still not among its files
- [ ] a CI run on the patched image (the lab's pins now name it; the `lab-regression` Action's next run) — to be added
      as a follow-up comment once green
- [x] posted through the operator's `gh` account
