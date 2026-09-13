# Enhancements

Proposals that grew out of the demos — each one names the measurement in a demo that motivates it, the
component it changes (the cf2cnp fork, the hubble-policy-verdicts chart, the hubble-observer fork, the
Cilium values, or the PoC's own workflow), and the demo that will prove it. A proposal is tracked in an
issue, designed in a plan under this folder, reviewed (the Codex + Cursor pass, record in `docs/REVIEW_*.md`)
before any of it is built, and closed by a demo with a recorded transcript and evidence.

| # | Proposal | Issue | Plan | Status |
|---|---|---|---|---|
| 001 | Policy from observed flows, enterprise-ready: the ten enhancements from demos 26–28 | [#11](https://github.com/ephico2real2/cilium-implementation-poc/issues/11) (tracking), #1–#10 per item | [001-policy-from-flows-enterprise.md](001-policy-from-flows-enterprise.md) | **released 2026-09-13** after the review ([docs/REVIEW_ENH-001.md](../docs/REVIEW_ENH-001.md)): cf2cnp [`v0.6.0`](https://github.com/ephico2real2/cf2cnp/releases/tag/v0.6.0) (E1–E6, E10 merged into `develop` in order), hubble-policy-verdicts [0.2.0](https://github.com/ephico2real2/hubble-policy-verdicts/releases) (E7), the observer fork `develop` `e5077dd` with both and the E8 example; deployed on poc1 (observer release rev 23). Proven by demos: E1+E9 → [demo 29](../demos/29-cross-cluster-policy/README.md); E2 → [demo 30](../demos/30-l7-rules/README.md), E3 → [demo 31](../demos/31-dns-visibility/README.md), E4+E5+E10 → 32, E6 → 33, E7+E8 → 34 (in progress) |

## The list behind 001 (from demos 26, 27 and 28)

| # | Enhancement | Motivating measurement | Component |
|---|---|---|---|
| E1 ([#1](https://github.com/ephico2real2/cilium-implementation-poc/issues/1)) | Cluster-aware selectors for ClusterMesh flows — **released 0.6.0, proven in [demo 29](../demos/29-cross-cluster-policy/README.md)** | demo 19's mesh trap (#62): a selector without the cluster label matches the same labels in every cluster; cf2cnp drops `io.cilium.k8s.policy.cluster` | cf2cnp |
| E2 ([#2](https://github.com/ephico2real2/cilium-implementation-poc/issues/2)) | L7 rules (HTTP method/path, DNS names) from L7-visible flows — **released 0.6.0, proven in [demo 30](../demos/30-l7-rules/README.md)** | demo 16/19: flows carry `l7` once a visibility policy is on; cf2cnp writes port-only rules | cf2cnp |
| E3 ([#3](https://github.com/ephico2real2/cilium-implementation-poc/issues/3)) | A DNS-visibility companion rule when `destination_names` is absent — **released 0.6.0, proven in [demo 31](../demos/31-dns-visibility/README.md)** (finding: the kube-dns rule twice, [ephico2real2/cf2cnp#1](https://github.com/ephico2real2/cf2cnp/issues/1)) | demo 26 Part 3: a CDN became `toCIDR 104.20.23.154/32` | cf2cnp |
| E4 ([#4](https://github.com/ephico2real2/cilium-implementation-poc/issues/4)) | Review before generate: a peer checklist in the page, `exclude=` on the API | demo 27 Part 3: the intent filter was a `hubble observe --not --from-pod` flag | cf2cnp |
| E5 ([#5](https://github.com/ephico2real2/cilium-implementation-poc/issues/5)) | `cf2cnp merge`: fold new flows into an existing policy file, idempotently | demo 26 Part 14: merging exists per request, not against what is already applied | cf2cnp |
| E6 ([#6](https://github.com/ephico2real2/cilium-implementation-poc/issues/6)) | Hardening of a shared `/generate`: allowed origins, optional token, a policy for the pod | demo 26 review: no auth, CORS `*`; body cap and timeouts done | cf2cnp, chart |
| E7 ([#7](https://github.com/ephico2real2/cilium-implementation-poc/issues/7)) | Verdict to policy in one dashboard: a Loki flow table with the cf2cnp action | demo 26 Part 10 vs demo 25: two dashboards for one workflow | hubble-policy-verdicts |
| E8 ([#8](https://github.com/ephico2real2/cilium-implementation-poc/issues/8)) | Which policy allowed it: a policy-verdict stream into Loki | demo 26 Part 9: the metric has no policy name; flows do (`ingress_allowed_by`) | hubble-observer, chart |
| E9 ([#9](https://github.com/ephico2real2/cilium-implementation-poc/issues/9)) | The `cluster` variable proven with a cross-cluster verdict — **[demo 29](../demos/29-cross-cluster-policy/README.md) Part 7** | demo 22 delivers poc2's metrics; no demo has a mesh verdict on the dashboard | PoC demo |
| E10 ([#10](https://github.com/ephico2real2/cilium-implementation-poc/issues/10)) | Policy as code: generated policies land in a branch and a PR | demo 27: a download is the end of the pipeline | workflow template |

## Follow-ups noted while proving 001

- **hubble-policy-verdicts: a source-or-destination namespace variable.** The dashboard is "by namespace" through
  the *destination* namespace label, so an egress drop that leaves the namespace (demo 29 Part 8: `mesh-lab → bank`)
  is not on the page; `demos/29-cross-cluster-policy/metric.sh` shows what the `or` form would.
- **cf2cnp chart: the fork's default image.** The chart's `image.repository` is still upstream's
  `ghcr.io/onzack/cf2cnp`, whose registry has no 0.6.0 tag; the fork's README says which image to set, and every
  consumer here sets it. A fork-specific default would be a divergence from the upstream PR, so it is documented, not changed.
