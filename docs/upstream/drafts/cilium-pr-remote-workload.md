# Draft — a pull request to cilium/cilium: "hubble: name the workload of a remote endpoint"

**Status: REVIEWED (OB1 + Codex + Grok, `docs/REVIEW_CILIUM_UPSTREAM_PR.md`), waiting for the operator (2026-09-18).**
The operator's word: *"I sign off after ob1"*. Nothing has been opened. **Two things the review changed about how this
gets posted:** (1) cilium/community `AI-POLICY.md`, *Unacceptable Use*, first bullet — "Communicate in any Cilium community
space with content that is substantially written using Generative AI tools … it is not acceptable to send such text on
Slack or GitHub" — so the PR body below is a **fact sheet for the operator to write from in their own words**, not text to
paste (and it means our three earlier posts were on the wrong side of that line — see `docs/upstream/README.md` §2a);
(2) #48563 already has the L7 parser half (since 2026-09-08 — our own comment there says "you have this covered");
what it lacks is only the schema-version bump and a cross-node measurement, which makes the case for a separate PR
thinner — the operator decides between the two routes in §"The decision". Existing-work check redone today: cilium/cilium#25676 open (the bug); #48563
open **draft** by devodev, last updated 2026-09-18T05:05Z — that update is our own follow-up comment; no reply from the
author since 2026-09-08; no PR by ephico2real2 exists (`gh pr list --repo cilium/cilium --author ephico2real2` → empty).

## What is being submitted

The branch `ephico2real2/cilium@hubble/remote-workload-main` (head `63650a0445`) — the lab's three commits **ported from
v1.20.2 to `main`** (`cccadb0e70`, 2026-09-18), squashed to two, with the review's fixes folded in:

| Commit | Subject | Files |
|---|---|---|
| `2fb374ce3a` | hubble: name the workload of a remote endpoint via CiliumEndpoint status | 20 files, +422 −2 (the review added `TestUpsertWorkloadOnlyChangeReachesMetadata`, the upgrade note in `Documentation/operations/upgrade-next.inc`, and the doc's schema version corrected 1.33.13 → 1.34.5): `pkg/k8s/apis/cilium.io/v2/types.go` (`EndpointStatus.Workloads []EndpointWorkload{Kind,Name}`), the regenerated deepcopy/deepequal and CRD yaml, `register.go` **1.34.4 → 1.34.5**, `pkg/endpoint/endpoint_status.go` (the owning agent writes it), `pkg/k8s/types` slim + `factory_functions.go`, `pkg/k8s/watchers/cilium_endpoint.go` (→ `ipcache.K8sMetadata.Workloads`, `Equal` compares it), `pkg/hubble/parser/common/endpoint.go` (remote branch + the `WorkloadsFromMetadata` helper), `Documentation/observability/metrics.rst`, tests |
| `63650a0445` | hubble/parser/seven: name a remote endpoint's workload on L7 flows too | `pkg/hubble/parser/seven/parser.go` (+14 −4), `parser_test.go` (+192, incl. the review's `TestDecodeL7WorkloadsReplacementEndpointKeepsIPCacheWorkload`) |

What the port had to change against v1.20.2 (main moved under it):

- `main` already carries **pod UID** through the same path (`K8sMetadata.PodUID`, `updateEndpointFromLocal` with an
  **ID-match guard** — "the IP may now belong to a replacement endpoint"). Our workload override now sits *after* that
  guard: a replacement endpoint with a different ID keeps the ipcache's answer, an ID-matched local endpoint replaces it
  (and clears it when the pod has no owner).
- `TransformToCiliumEndpoint` on main takes `*cilium_v2.CiliumEndpoint` directly (no `DeletedFinalStateUnknown` arm);
  one `Workloads:` line instead of two.
- `DeleteOnMetadataMatch` gained a `uid` parameter; our watcher test's fake follows.
- `CustomResourceDefinitionSchemaVersion` is 1.34.4 on main → **1.34.5** (was 1.33.12 → 1.33.13 on v1.20.2).
- Both test files that conflicted (`common/endpoint_test.go`, `seven/parser_test.go`) now hold main's pod-UID tests
  **and** ours.

Verified on the ported branch, 2026-09-18 (the Cilium builder image, `contrib/scripts/builder.sh`, linux/arm64):

- `go test -count=1` over `pkg/hubble/parser/...`, `pkg/ipcache`, `pkg/k8s`, `pkg/k8s/types`, `pkg/k8s/watchers`,
  `pkg/k8s/apis/cilium.io/...` — **all ok** (`scratchpad/gotest-main.log`; the one build failure on the first run was
  the fake's old `DeleteOnMetadataMatch` signature, fixed and re-run: `ok pkg/k8s/watchers 0.025s`). **`pkg/endpoint`'s
  status tests are gated** on `INTEGRATION_TESTS` and an etcd (Cilium's `make integration-tests`): my run reported `ok`
  on three SKIPs; OB1 ran `TestGetCiliumEndpointStatusWithWorkloads` with `INTEGRATION_TESTS=1` against an etcd
  container — PASS on the branch, FAIL with `endpoint_status.go` reverted.
- Fail-before / pass-after, measured (not inferred): `TestResolveEndpointRemoteWorkloads` and `TestDecodeL7Workloads`
  by me (both FAIL with their parser change reverted); the replacement-endpoint test, the Upsert test, the watcher
  test, the transform case and the Equal test by OB1 (each FAIL on main's code, PASS on the branch — quoted in
  `docs/REVIEW_CILIUM_UPSTREAM_PR.md`).
- `make manifests` and `make generate-k8s-api` reproduce the committed CRD yaml and `zz_generated.*` byte for byte
  (clean tree after both).
- `go vet` over the same packages: clean. `GOOS=linux go build ./pkg/... ./daemon/...`: ok.
- Not run on the ported branch: a cluster. The cluster measurements below are from the v1.20.2 build of the same
  change (`1d3a02ab`), which both lab clusters run.

## The decision — a PR of our own, or #48563

What #48563 (draft, devodev) has, read from its diff by all three reviewers: the workload on the CEP **and** the CES
**and** the kvstore/Cluster Mesh path (singular `workload`), **both parsers including the L7 access-log parser and the
ownerless-pod clear** (its `seven/parser.go` hunk is in commit `748fc29714`, 2026-09-08 — ten days before our comment,
which says so: "Your diff touches `seven/parser.go`, so you have this covered"), the replacement-endpoint test case,
and a cilium-cli connectivity test. What it does **not** have: the `register.go` schema-version bump (grep: 0 matches),
and a cross-node measurement. No author activity since 2026-09-08; no reply to our comment (posted 04:22 UTC today).

So the honest position: **our branch is a smaller, independently tested, measured subset of #48563 plus the one
thing that PR is missing.** Two routes, the operator's call:

| | Route A — open our PR | Route B — feed #48563 |
|---|---|---|
| What goes up | the two commits (CEP path only, both parsers, the bump, tests, the measurement), described as an alternative to #48563 that can be closed in its favour | nothing new: our comment already names the bump; optionally a follow-up asking whether devodev wants the bump and the pruning caveat folded in, or a review approval once they are |
| Upside | a complete, reviewable, tested change exists on `main` now; the plural `workloads` shape gets a hearing; the bump cannot be forgotten | no duplicate work on the maintainers' desk; no competing PR against an author we already engaged |
| Downside | maintainers may close it as a duplicate (#36011, CEP-only, was closed in 2025 in favour of the broader approach; #48563 covers more) | depends on devodev returning; the bump stays missing until they do |
| The policy | the PR body must be **the operator's own words** (Unacceptable Use) — the fact sheet below is what they write from | the follow-up comment too |

My recommendation: **Route B first, Route A only if #48563 stays silent** — say, two weeks — because the L7 half we
thought was our contribution is already there and the maintainers will see that at once. If the operator wants Route A
anyway ("we are engineers"), everything below is ready for it.

## The PR, as it would be opened

**Title:** `hubble: name the workload of a remote endpoint (CiliumEndpoint status)`

**Body:**

> Hubble's `Endpoint.Workloads` is set only for endpoints local to the reporting agent (from the pod object); the
> remote branch of the endpoint resolver builds the endpoint from the ipcache's `K8sMetadata`, which has no workload.
> So `source_workload` / `destination_workload` on the Hubble metrics — and the `workload-name` context option — are
> empty for any pod on another node. Gateway traffic is the common case: the Envoy on the client's node reports it,
> and the backend is remote whenever the scheduler puts client and backend apart. #25676, open since 2023.
>
> **What this does.** The owning agent writes the pod's workload (kind, name — from the owner references, the helper
> Hubble already uses locally) onto `CiliumEndpoint.status.workloads`; the CiliumEndpoint watcher copies it into
> `K8sMetadata.Workloads`; the common resolver (L3/L4) and the L7 access-log parser set `Endpoint.Workloads` from it,
> and an ID-matched local endpoint still overrides it (a local pod without an owner clears it). Two commits: the data
> path and the L3/L4 resolver; then the L7 parser, which resolves endpoints on its own and is the one that reports
> Gateway traffic.
>
> **Why the CRD schema version bumps** (`CustomResourceDefinitionSchemaVersion` 1.34.4 → 1.34.5): the operator only
> rewrites an existing CEP CRD when the cluster's `io.cilium.k8s.crd.schema.version` label is behind, and the CEP status
> schema has no `x-kubernetes-preserve-unknown-fields` — without the bump an upgraded cluster keeps the old schema and the
> agent's `status.workloads` is pruned silently (the patch succeeds, nothing is logged, Hubble sees nothing). We hit
> exactly that on our first deploy.
>
> **Scope.** CEP path only. `CoreCiliumEndpoint` (CiliumEndpointSlices) does not carry the field, so the CES path keeps
> today's behaviour; pods in another cluster of a Cluster Mesh (the kvstore path) too. A mixed-version cluster degrades
> to today's empty label. The metrics documentation says where the label stays empty.
>
> **Relation to #48563.** That draft (devodev) does the same for the CEP, the CES and the kvstore path, with a
> singular `workload`, and already covers both parsers, including the L7 access-log parser and the ownerless-pod
> case. What it does not have today is the `CustomResourceDefinitionSchemaVersion` bump, without which an upgraded
> cluster prunes the new status field silently (noted on that PR in
> https://github.com/cilium/cilium/pull/48563#issuecomment-5725111947), and a cross-node measurement. This PR is the
> smaller, measured subset — CEP path only — with the bump and our lab's test cases. Happy to rebase onto #48563 or
> close this in its favour once that lands with the bump — whichever the maintainers prefer.
>
> **A limitation shared with every status field added so far** (the maintainers may want a view): after a successful
> patch the endpoint synchronizer remembers the *desired* status (`endpointsynchronizer.go`, `lastMdl = mdl`), so an
> agent whose first patch landed before the operator rewrote the CRD has `workloads` pruned and does not resend it until
> the status next changes or the agent restarts. `serviceAccount` (d7ac791188) shipped the same way; this PR follows
> that precedent and documents it in the upgrade notes rather than changing the synchronizer.
>
> **Measured** (two kind clusters, Cilium v1.20.2 with this change, Gateway API, `enable-cilium-endpoint-slice` off;
> backends of two namespaces on the control-plane node, the client pod on the worker, 40 HTTPS requests per Gateway):
> the worker's agent reports `hubble_http_requests_total{…, destination_workload="shop"}` for both — it was `""`
> before; and the chart's *Hubble L7 HTTP Metrics by Workload* dashboard fills for the remote backend where it showed
> "No data" on every panel, same selection (before / after):
>
> ![before: No data on every panel for a backend on the other node](https://raw.githubusercontent.com/ephico2real2/cilium-implementation-poc/main/docs/upstream/images/l7-by-workload-team-a-no-data.png)
>
> ![after: the same dashboard filled](https://raw.githubusercontent.com/ephico2real2/cilium-implementation-poc/4ef5d94952c19566bb2385140cad31e25b720ef9/demos/39-remote-workload-fix/output/l7-by-workload-shop-team-a-highlighted.png)
>
> **How it was tested.** Unit tests: `TestResolveEndpointRemoteWorkloads` (common resolver, remote branch),
> `TestDecodeL7Workloads` (remote from the ipcache; a local pod overriding; a local ownerless pod clearing a stale
> value) and `TestDecodeL7WorkloadsReplacementEndpointKeepsIPCacheWorkload` (a replacement endpoint with another ID
> keeps the ipcache's tuple and workload), the CEP status writer (`INTEGRATION_TESTS`), the CEP watcher (`Workloads`
> reaching `K8sMetadata`), `K8sMetadata.Equal` and `Upsert` honouring it, `TransformToCiliumEndpoint` — all pass; each
> fails with its change reverted. `make manifests` and `make generate-k8s-api` are clean. On the clusters: the same image on both nodes of both clusters, the regenerated CRD
> applied and labelled before the agents rolled, then the measurement above; and a GitHub Actions run of our lab's
> regression check on a fresh amd64 runner — client on one node, backend on the other, `destination_workload="shop"`:
> https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/35307892865 (the `demo 39` step).
>
> **Generative AI use** (per `cilium/community/AI-POLICY.md`) — *facts for the operator's own paragraph, not text to
> paste:* prepared with an AI coding assistant (Claude Code) under the operator's direction; the operator chose the
> mechanism (CEP status → ipcache → both parsers), designed the test cases and the cross-node measurement, and ran the
> measurements; the diff read line by line by the operator before signing off (pending — item 2 below); reviewed by
> three independent model reviewers (Anthropic Claude, OpenAI Codex, xAI Grok — read-only, adversarial briefs), whose
> findings produced the L7-parser commit, the ownerless-pod case, the replacement-endpoint test and the doc's schema
> version; no human reviewer other than the operator. Signed off under the DCO by the operator.
>
> Fixes: #25676
>
> ```release-note
> Hubble now reports the Kubernetes workload (Deployment, StatefulSet, …) of pods running on other nodes, so the source_workload and destination_workload labels of Hubble metrics are no longer empty for cross-node and Gateway traffic. The CiliumEndpoint CRD schema version is bumped to 1.34.5; the operator rewrites the CRD on start, and an endpoint whose CiliumEndpoint status was written before that rewrite reports no workload until its status next changes or the agent restarts.
> ```

**Labels to ask for:** `release-note/minor` (the maintainers may relabel `release-note/bug` — #25676 is filed as a bug), `area/hubble`; reviews are auto-requested from `sig-hubble`, `sig-k8s`, `ipcache`, `endpoint`, `hubble-metrics` + `docs-structure` (CODEOWNERS). Not `sig/hubble-api` — that owns `api/v1/flow/`, untouched.

## Before the operator opens it (Route A) — the four things only they can do

1. **DCO.** Both commits need `Signed-off-by: <real name> <email>` (Cilium's guide: real name, `git commit -s`). The
   commits on the branch are unsigned on purpose; the command, once the name is given:
   `git rebase --signoff origin/main` on `hubble/remote-workload-main` with `user.name` set to the name, then
   `git push -f fork hubble/remote-workload-main`.
2. **Read the diff** — `git diff origin/main..hubble/remote-workload-main` in `~/gitRepos/cilium` (the worktree is in
   the scratchpad, the branch is on the fork) — the policy says the contributor "personally reviews" it.
3. **Write the body in your own words** from the fact sheet above — the policy's Unacceptable Use forbids posting text
   "substantially written using Generative AI tools"; the measurements, links and the release-note block are facts you
   can reuse verbatim, the prose must be yours.
4. **Open it** — `gh pr create --repo cilium/cilium --base main --head ephico2real2:hubble/remote-workload-main` with
   the title and your body, then post `/test` when a maintainer asks (CI on Cilium's side is maintainer-triggered
   for first-time contributors).
