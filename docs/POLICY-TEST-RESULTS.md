# Network policy test results — what was generated, how it was tested, what happened

One page for the question "where are the results of the policy tests?". Every row is a policy cf2cnp generated from
observed flows in this lab, the way it was put under test (audit mode first, then enforced, then probed by the
callers Hubble had seen), and the recorded outcome — each linked to the demo part whose transcript, evidence file
and screenshots hold the raw output (`demos/<n>/output/`). The policies themselves are committed under
`demos/<n>/policies/` beside the flows they were generated from, so any row can be regenerated and diffed.

## The test method, the same in every demo

1. **Observe.** A default-deny policy is applied with the endpoints in Cilium's *audit mode*: every verdict is
   evaluated and reported as `AUDIT`, nothing is dropped (demo 26, `audit-mode.sh`).
2. **Generate.** The audited flows go to cf2cnp (the API, the page or the Grafana action) — a policy per workload.
3. **Enforce.** Audit mode off; the generated policies applied.
4. **Probe.** Every caller Hubble had seen calls again; the status each one gets and Hubble's verdict for each call
   (`hubble observe --type policy-verdict`, and the deciding policy's name from `--verdict`/`allowed_by`) are recorded.
5. **Watch.** The verdict dashboard shows the same counts (audited → forwarded / dropped) for the namespace.

## Results by demo

| Demo | Policies (`policies/`) | Enforced against | Outcome recorded | Where |
|---|---|---|---|---|
| 26 · policy from flows | `cnp-pos-to-shop.yaml`, `cnp-stranger-to-shop.yaml`, `cnp-pos-to-world.yaml`, `cnp-merged-from-three-flows.yaml`, `cnp-from-grafana.yaml` | `pos` → `shop`, `stranger` → `shop`, `pos` → the world | the intended caller forwarded, the stranger's flow turned into a policy too (the lesson that became `?exclude=`), the world by CIDR; verdicts read back from Hubble and the metric | [demo 26](../demos/26-cf2cnp-policy-from-flows/README.md) Parts 5–12, `output/evidence.txt` |
| 27 · the release | `cnp-shop.yaml`, `cnp-from-grafana.yaml` | two components of one app (`shop-frontend`, `shop-backend`) from one request, `pos` and the stranger | two policies, names that cannot collide, applied under audit then enforced; listed by label | [demo 27](../demos/27-cf2cnp-release/README.md) Parts 4–7 |
| 29 · cross-cluster (ClusterMesh) | `cnp-cache-0.5.1.yaml` vs `cnp-cache-0.6.0.yaml`, `cnp-worker-poc2.yaml` | `worker`@poc2 → `cache`@poc1 through a global Service; a same-labelled twin in poc1 | **0.5.1's policy dropped the real cross-cluster caller and admitted the local twin; 0.6.0's (cluster-aware selector) forwarded the caller** — each enforced in turn, verdicts on the hub's dashboard (`worker → accounts egress dropped 9`) | [demo 29](../demos/29-cross-cluster-policy/README.md) Parts 5–8, screenshots |
| 30 · L7 rules | `cnp-shop-l4.yaml` vs `cnp-shop-l7.yaml` | eight HTTP calls: `pos` `/` and `/checkout`, the frontend's sidecar `/api/…`, the stranger | L4: every path allowed; L7: the observed method+path pairs `200`, everything else `403` from the proxy — eight statuses recorded, `match = l7/http` on the dashboard | [demo 30](../demos/30-l7-rules/README.md) Part 4, `grafana-policy-verdicts-cf2cnp-lab30.png` |
| 31 · DNS visibility → toFQDNs | `cnp-pos-egress.yaml` (CIDR) → `cnp-pos-dns-visibility.yaml` → `cnp-pos-fqdn.yaml` | `pos` → `example.com` and `cilium.io` | `example.com` answers; `cilium.io` resolves and is **dropped by name** (`toFQDNs`); the double kube-dns rule found here became fork issue #1 and 0.6.1 | [demo 31](../demos/31-dns-visibility/README.md) Part 3 |
| 32 · the operator loop | `cnp-frontend-all.yaml`, `cnp-frontend-intent.yaml`, `shop-frontend-merged*.yaml` | `kiosk`, a new client, against demo 27's enforced policy | dropped first; `cf2cnp merge` added its rule; `200` after — three runs of the policy-PR template on a policies repository | [demo 32](../demos/32-operator-loop/README.md) Parts 1–3, [cilium-policies-lab#1](https://github.com/ephico2real2/cilium-policies-lab/pull/1) |
| 33 · hardening | the chart's own CiliumNetworkPolicy for the cf2cnp pod | a pod in the cluster, a browser on another site, a machine with and without the token | the pod refused, the Gateway and the kubelet admitted (`reserved:ingress`, `reserved:host` measured), the foreign origin gets no CORS header, 401 without the token | [demo 33](../demos/33-hardening/README.md) Parts 1–3 |
| 34 · verdict → policy | (the verdict stream, not a new policy) | every allowed flow of the lab | "which policy allowed it" answered from Loki for one raw verdict; the Loki row's action generates from a drop | [demo 34](../demos/34-verdict-to-policy/README.md) Parts 2–3 |
| 35 · the shop platform | `cnp-shop-all.yaml` (every caller), `cnp-shop-intent.yaml` (the stranger excluded) — six policies in six namespaces from one request | nine probes across `shop-edge`, `shop-core`, `shop-payments`, `shop-merchant`, `shop-reviews`, `shop-clients` | **six `200`, three drops**: the stranger twice, and the shopper straight at the catalog (bypassing the gateway); the descriptions read like the architecture | [demo 35](../demos/35-shop-platform/README.md) Part 5, `output/evidence.txt` |

## cf2cnp's own tests (the fork, every push)

| Layer | What it holds | Where to see it |
|---|---|---|
| unit tests | 104 tests (46 at 0.6.3): parsing, naming and merging, ClusterMesh selectors, L7, DNS visibility and the resolver derivation, exclude, merge, hardening, descriptions, dual-stack world labels, validation against admission | the CI job summary of every push ([Actions](https://github.com/ephico2real2/cf2cnp/actions)) — tests by package, failures named |
| golden captures | 14 real Hubble captures from demos 26–35 whose `/generate` answer must stay byte for byte what 0.6.3 gave (deliberate changes named in `internal/testdata/golden/README.md`) | the same summary, one line per capture |
| the CRD schema | every golden output validated offline with `kubectl-validate` against the embedded CRD of the pinned Cilium version, and the embedded CRD compared byte for byte with the module's | the same summary |
| the agent's checks | `cf2cnp validate` over every golden output: Sanitize, ObjectMeta, the protocol enum, apiVersion/kind, nodeSelector, `specs` | the same summary |
| reviews | two independent reviewers on every release: [REVIEW_ENH-001](REVIEW_ENH-001.md) (0.6.0), [REVIEW_ENH-003](REVIEW_ENH-003.md) (0.7.0), [REVIEW_DASHBOARD-0.4.0](REVIEW_DASHBOARD-0.4.0.md) | this directory |
| the record | [CHANGELOG.md](https://github.com/ephico2real2/cf2cnp/blob/develop/CHANGELOG.md) on the fork, release notes on every tag | the fork |

## What is not here

Performance numbers for policies (throughput with and without L7) are in demo 06 and `docs/TUNING.md`, measured on
the laptop's VM and to be re-measured in CI (enhancement 004). Egress-gateway and per-namespace egress-IP policies
are enhancement 002, not built yet.
