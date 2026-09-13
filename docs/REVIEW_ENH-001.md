# Review — Enhancement 001: policy from observed flows, enterprise-ready

Adversarial pass, 2026-09-13, on the 15-claim brief for
[`enhancements/001-policy-from-flows-enterprise.md`](../enhancements/001-policy-from-flows-enterprise.md) and its ten
branches. Cursor (Grok 4.6 high fast, ask mode: no shell, no network, no cluster) traced the branches, the
fixtures and this repository's records. Codex (gpt-5.6-sol, xhigh) ran as task `task-mtzbuw8k-t5rjkh`; its
answer had not been fetched when this record was written — the plugin's `result` step is reserved for the
operator (`/codex:result task-mtzbuw8k-t5rjkh`); its column is filled in when it is. Every verdict below was
re-checked here, most by measurement on poc1 (the transcript lines are quoted), and every accepted fix was
applied on its branch with a test and pushed.

## Verdicts

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 local-cluster default since 1.19 | CONFIRMED (from this repo's records) | pending | — (cited from `clustermesh/policy.rst` 49–56 in the plan) |
| C2 `cluster_name` + the cluster label on flows | CONFIRMED (fixture) | pending | — |
| C3 the L7 record's shape | CONFIRMED (fixtures) | pending | — |
| C4 Path/Method regexes, not anchored by Cilium | PLAUSIBLE | pending | — (E2 anchors and escapes; the plan says so) |
| C5 kube-dns selector, UDP/53 | CONFIRMED | pending | — **measured**: pods `k8s-app=kube-dns`, Service ports 53/UDP and 53/TCP; the UDP-only rule is upstream's and the FQDN path's; DNS over TCP is a follow-up note, not changed |
| C6 policy-verdict events, 5.6 % | PLAUSIBLE | pending | — (measured in the plan) |
| C7 E1 | REFUTED | pending | **Accepted**: empty `cluster_name` fell back to nothing though the label was on the flow — `clusterOf` reads the label; the fixture is an established-connection packet traced on the destination's node, the egress policy is still the right one (plan text corrected) |
| C8 E2 | REFUTED | pending | **Accepted**: the measured DNS query is a search-list expansion — `cleanDNSQuery` cuts at the first cluster-domain occurrence; query strings dropped (Cilium has no query field); L7-on-a-port semantics are Cilium's, stated in the plan |
| C9 E3 | CONFIRMED / PLAUSIBLE | pending | — |
| C10 E4 | REFUTED | pending | **Accepted**: the page's key list now equals the parser's priority list; a test reads the served page |
| C11 E5 | REFUTED | pending | **Accepted**: `port: 80` and `port: "80"` compare equal (scalars canonicalised as strings); labels stay untouched by design |
| C12 E6 | CONFIRMED / PLAUSIBLE | pending | **Accepted on two facts I measured**: Gateway traffic is `reserved:ingress`, the kubelet's probes are `reserved:host` (26 of 35 flows) — both admitted; the Grafana selector default is empty (a cross-namespace selector needs the namespace label; the action arrives through the Gateway anyway) |
| C13 E7 | REFUTED | pending | **Accepted**: `Line` excluded from the frame left the Generate action an empty body — kept and hidden as the 23862 dashboard does; CI asserts it on the Loki table |
| C14 E8 | REFUTED | pending | **Accepted**: the example pins `quay.io/cilium/cilium:v1.20.1` — `--field-mask` exists on that CLI, not on the chart's default 1.16.4 (demo 25 Part 7b); render checked |
| C15 E10 | REFUTED / CONFIRMED | pending | **Accepted**: `setup-go` added; `--local-crds` takes a directory (measured from `--help`); `--version` dropped; the plan's snippet aligned |

## Measured here, independent of the reviewers

| What | Result | Used for |
|---|---|---|
| `kubectl -n kube-system get svc kube-dns`, pod labels | selector `k8s-app: kube-dns`; ports 53/UDP, 53/TCP, 9153/TCP; pods `k8s-app=kube-dns` | C5, C9 |
| `hubble observe --to-pod hubble-observer/hubble-observer-cf2cnp --last 30` | `reserved:host` (identity 1) 26 flows, `reserved:ingress` (identity 8) 9 flows, all to :8080 | C12 — E6's policy admits both entities |
| `helm template … -f examples/values-policy-verdicts.yaml` | `hubble observe flows … -o json --field-mask time,uuid,… --type policy-verdict`, no `--verdict`; image `quay.io/cilium/cilium:v1.20.1` after the fix | C14 |
| `hubble observe --type policy-verdict --field-mask <the E8 list>` against the relay | accepted, a flow returned | C14 (the mask's names) |
| `go run sigs.k8s.io/kubectl-validate@v0.0.4 --help` | `--local-crds` "Paths to directories containing .yaml or .yml files for CRD definitions" | C15 |
| the CRD path at v1.20.1 | `pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml` → HTTP 200 | C15 |

## Not asked, and what happened to it

- **Cursor: E1's fixture is not "a request reported by the source's node"** (it is an established-connection
  ACK traced at `TO_ENDPOINT` on `poc1/poc1-worker`). Accepted as a text correction: the generated egress
  policy is what poc2 needs regardless; the plan says what the fixture is.
- **Cursor: the plan's E10 snippet still passed a file to `--local-crds`.** Aligned with the template.
- **Cursor: E6's Grafana `fromEndpoints` without a namespace label matches the release namespace only.**
  Accepted; the default is empty and the README shows the namespaced form.

## Outcome

Fifteen claims: seven refuted by Cursor, every refutation re-traced or measured here and accepted, each fix
applied on its branch with a test, the branches' suites green (`go test ./...` on E1, E2, E4, E5, E6; `helm
lint` and the render checks on E6, E7, E8; the CI job on E7). The plan's stack facts stood. Codex's pass is
outstanding until `/codex:result task-mtzbuw8k-t5rjkh` is run; its verdicts go into the table above and any
new finding follows the same path (re-check, decide in writing, apply with a test).

Branch heads after the fixes: E1 `e8be5ca`, E2 `f757a3a`, E4 `3c74e93`, E5 `aeaf34e`, E6 `f0cdb97`, E7 `db44bfa`,
E8 `7a4d78d`, E3 `49f55eb` and E10 `f84c7ce` unchanged.
