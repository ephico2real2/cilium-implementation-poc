# Draft — a review comment on cilium/cilium#48563 "hubble: Populate workloads for remote endpoints"

**Status: DRAFT, not posted.** Written 2026-09-18 after OB1 (Fable 5.1) and Codex reviewed the lab's own fix
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
> L7 HTTP Metrics by Workload* dashboard fills for the remote backend where it was "No data". Happy to run this PR's
> branch on the same lab and report, if that helps it out of draft. Details and the exact commands:
> <link to demos/39-remote-workload-fix/README.md on main>.
>
> (Written with AI assistance under the Cilium AI policy — Claude orchestrating, Cursor implementing the lab's own
> branch from briefs, Fable and Codex reviewing; every measurement above was run and read by me.)

## Before posting

- [ ] the operator has read this file and said "post"
- [ ] the lab's demo 39 is on `main` so the link resolves
- [ ] re-check #48563's state (`gh pr view 48563 -R cilium/cilium --json state,isDraft,files`) — if `register.go` has
      appeared or the PR merged, drop or rewrite point 2
- [ ] the operator posts it, or says who does
