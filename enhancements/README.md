# Enhancements

Proposals that grew out of the demos — each one names the measurement in a demo that motivates it, the
component it changes (the cf2cnp fork, the hubble-policy-verdicts chart, the hubble-observer fork, the
Cilium values, or the PoC's own workflow), and the demo that will prove it. A proposal is tracked in an
issue, designed in a plan under this folder, reviewed (the Codex + Cursor pass, record in `docs/REVIEW_*.md`)
before any of it is built, and closed by a demo with a recorded transcript and evidence.

| # | Proposal | Issue | Plan | Status |
|---|---|---|---|---|
| 001 | Policy from observed flows, enterprise-ready: the ten enhancements from demos 26–28 | [#11](https://github.com/ephico2real2/cilium-implementation-poc/issues/11) (tracking), #1–#10 per item | [001-policy-from-flows-enterprise.md](001-policy-from-flows-enterprise.md) | **released 2026-09-13** after the review ([docs/REVIEW_ENH-001.md](../docs/REVIEW_ENH-001.md)): cf2cnp [`v0.6.0`](https://github.com/ephico2real2/cf2cnp/releases/tag/v0.6.0) (E1–E6, E10 merged into `develop` in order), [`v0.6.1`](https://github.com/ephico2real2/cf2cnp/releases/tag/v0.6.1) (two demo findings: the merge keeps the file's layout, one kube-dns rule) and [`v0.6.3`](https://github.com/ephico2real2/cf2cnp/releases/tag/v0.6.3) (descriptions from the rules), hubble-policy-verdicts [0.2.0](https://github.com/ephico2real2/hubble-policy-verdicts/releases) (E7), 0.2.1 (the namespace filter's side) and 0.2.2 (generic wording, the audited tile), the observer fork `develop` `e5077dd` with both and the E8 example; deployed on poc1 (observer release rev 23). Proven by demos: E1+E9 → [demo 29](../demos/29-cross-cluster-policy/README.md); E2 → [demo 30](../demos/30-l7-rules/README.md), E3 → [demo 31](../demos/31-dns-visibility/README.md), E4+E5+E10 → [demo 32](../demos/32-operator-loop/README.md), E6 → [demo 33](../demos/33-hardening/README.md), E7+E8 → [demo 34](../demos/34-verdict-to-policy/README.md). **All ten proven; issues #1–#11 closed.** |
| 002 | The shop platform on the mesh: global services with local affinity, a gateway per cluster with pinned addresses, a database in one cluster with cluster-aware policies, egress IPs, load + HPA, failure and DR scenarios | — (issues after the plan is approved) | [002-shop-platform-clustermesh.md](002-shop-platform-clustermesh.md) | **plan, revision 2 — decisions taken**: the DB as an external database behind a TCPRoute (`toFQDNs: db-service.poc.local`), a Go backend, two external clients (Go, Python) that know only the URL, the public VIP taken over by poc2 in DR (L2 announcements), egress identity across the mesh three ways (per-namespace-per-cluster egress IPs on the mesh clusters, a VIP/node-address variant, the identity baseline — cost, risk and performance measured; cf2cnp 0.7.0 `fromCIDR`); demos 36–41 |
| 003 | cf2cnp consumes Cilium's own policy spec: `github.com/cilium/cilium` `pkg/policy/api` types (291 schema paths vs 20 hand-written fields), `Sanitize()` on a copy + the embedded CRD of the same version as two validation layers, the supported spec printed and released; `fromCIDR`, `enableDefaultDeny`, deny lists, ICMP follow | — (after review) | [003-cf2cnp-cilium-policy-api.md](003-cf2cnp-cilium-policy-api.md); forensics on the fork: [`docs/CRD-SPEC-FORENSICS.md`](https://github.com/ephico2real2/cf2cnp/blob/enh/E12-cilium-policy-api/docs/CRD-SPEC-FORENSICS.md) | **plan for review** — measured feasible (zero `replace` lines, 18 MB, Go 1.26); 002's phase 0 depends on its 0.7.0 |

## The list behind 001 (from demos 26, 27 and 28)

| # | Enhancement | Motivating measurement | Component |
|---|---|---|---|
| E1 ([#1](https://github.com/ephico2real2/cilium-implementation-poc/issues/1)) | Cluster-aware selectors for ClusterMesh flows — **released 0.6.0, proven in [demo 29](../demos/29-cross-cluster-policy/README.md)** | demo 19's mesh trap (#62): a selector without the cluster label matches the same labels in every cluster; cf2cnp drops `io.cilium.k8s.policy.cluster` | cf2cnp |
| E2 ([#2](https://github.com/ephico2real2/cilium-implementation-poc/issues/2)) | L7 rules (HTTP method/path, DNS names) from L7-visible flows — **released 0.6.0, proven in [demo 30](../demos/30-l7-rules/README.md)** | demo 16/19: flows carry `l7` once a visibility policy is on; cf2cnp writes port-only rules | cf2cnp |
| E3 ([#3](https://github.com/ephico2real2/cilium-implementation-poc/issues/3)) | A DNS-visibility companion rule when `destination_names` is absent — **released 0.6.0, proven in [demo 31](../demos/31-dns-visibility/README.md)** (finding: the kube-dns rule twice, [ephico2real2/cf2cnp#1](https://github.com/ephico2real2/cf2cnp/issues/1), fixed in 0.6.1) | demo 26 Part 3: a CDN became `toCIDR 104.20.23.154/32` | cf2cnp |
| E4 ([#4](https://github.com/ephico2real2/cilium-implementation-poc/issues/4)) | Review before generate: a peer checklist in the page, `exclude=` on the API — **released 0.6.0, proven in [demo 32](../demos/32-operator-loop/README.md) Part 1** | demo 27 Part 3: the intent filter was a `hubble observe --not --from-pod` flag | cf2cnp |
| E5 ([#5](https://github.com/ephico2real2/cilium-implementation-poc/issues/5)) | `cf2cnp merge`: fold new flows into an existing policy file, idempotently — **released 0.6.0, proven in [demo 32](../demos/32-operator-loop/README.md) Part 2; 0.6.1 keeps the file's layout** | demo 26 Part 14: merging exists per request, not against what is already applied | cf2cnp |
| E6 ([#6](https://github.com/ephico2real2/cilium-implementation-poc/issues/6)) | Hardening of a shared `/generate`: allowed origins, optional token, a policy for the pod — **released 0.6.0, proven in [demo 33](../demos/33-hardening/README.md)** (the parent chart's `ingressFromEntities` must be narrowed too: policies add) | demo 26 review: no auth, CORS `*`; body cap and timeouts done | cf2cnp, chart |
| E7 ([#7](https://github.com/ephico2real2/cilium-implementation-poc/issues/7)) | Verdict to policy in one dashboard: a Loki flow table with the cf2cnp action — **released 0.2.0, proven in [demo 34](../demos/34-verdict-to-policy/README.md) Part 3** | demo 26 Part 10 vs demo 25: two dashboards for one workflow | hubble-policy-verdicts |
| E8 ([#8](https://github.com/ephico2real2/cilium-implementation-poc/issues/8)) | Which policy allowed it: a policy-verdict stream into Loki — **proven in [demo 34](../demos/34-verdict-to-policy/README.md) Parts 1–2** (the fork gains `containerName`; the README's LogQL selected nothing without it) | demo 26 Part 9: the metric has no policy name; flows do (`ingress_allowed_by`) | hubble-observer, chart |
| E9 ([#9](https://github.com/ephico2real2/cilium-implementation-poc/issues/9)) | The `cluster` variable proven with a cross-cluster verdict — **[demo 29](../demos/29-cross-cluster-policy/README.md) Part 7** | demo 22 delivers poc2's metrics; no demo has a mesh verdict on the dashboard | PoC demo |
| E10 ([#10](https://github.com/ephico2real2/cilium-implementation-poc/issues/10)) | Policy as code: generated policies land in a branch and a PR — **proven in [demo 32](../demos/32-operator-loop/README.md) Part 3 ([PR #1](https://github.com/ephico2real2/cilium-policies-lab/pull/1)); two first-run findings in the template** | demo 27: a download is the end of the pipeline | workflow template |

## Follow-ups noted while proving 001

- **cf2cnp: the description said only the namespaces — done, 0.6.2/0.6.3.** `Allow ingress traffic from cf2cnp-lab27 to
  cf2cnp-lab27 for the shop` told a reviewer nothing (operator finding on the page). The description is now written from
  the policy's rules — subject and peers as the selector names them, namespace and cluster when they differ, ports, L7 —
  and proven across five namespaces in [demo 35](../demos/35-shop-platform/README.md).
- **hubble-policy-verdicts: PoC wording in released panels, and a tile that read 0 — done, 0.2.2.** A panel title named
  "the demo 16 metric" and the Loki row "demo 25" (operator finding); CI now refuses the word. The audited tile counts
  source → destination pairs (the same under either side of the filter) and reads `none` once everything enforces.
- **The upstream PRs track the forks.** onzack/cf2cnp#3 is fast-forwarded to the fork's `develop` (0.5.0 → 0.6.3, a
  release-by-release body); onzack/hubble-observer#13 carries the dashboard, the verdict-stream example and `containerName`
  on top of upstream's main, with the observer's other changes in their own PRs (#9, #10, #11).
- **hubble-policy-verdicts: a source-or-destination namespace variable — done, 0.2.1.** The dashboard was "by
  namespace" through the *destination* label, so an egress drop that leaves the namespace (demo 29 Part 8:
  `mesh-lab → bank`) was not on the page; 0.2.1's `namespace is the` variable (destination or source) puts it there
  ([demo 29 Part 9](../demos/29-cross-cluster-policy/README.md#part-9-added-later-the-same-day--the-dashboard-chart-021-the-namespace-filter-chooses-its-side)).
- **cf2cnp chart: the fork's default image.** The chart's `image.repository` is still upstream's
  `ghcr.io/onzack/cf2cnp`, whose registry has no 0.6.0 tag; the fork's README says which image to set, and every
  consumer here sets it. A fork-specific default would be a divergence from the upstream PR, so it is documented, not changed.
