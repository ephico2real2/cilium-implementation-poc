# Review — Enhancement 001: policy from observed flows, enterprise-ready

Adversarial pass, 2026-09-13, on the 15-claim brief for
[`enhancements/001-policy-from-flows-enterprise.md`](../enhancements/001-policy-from-flows-enterprise.md) and its ten
branches. Cursor (Grok 4.6 high fast, ask mode: no shell, no network, no cluster) traced the branches, the
fixtures and this repository's records. Codex (gpt-5.6-sol, xhigh, 54 minutes, task
`task-mtzbuw8k-t5rjkh`) ran `go test` on archived copies of every branch, `helm lint` and both renders on
E7, an offline render of E8, and fetched Cilium's source and docs at v1.20.1; its sandbox refused the live
cluster. (Its answer file was overwritten by the `result` fetch and recovered from the Codex session log —
the write command carried the full text.) Every verdict below was re-checked here, most by measurement on
poc1 or by reading the cited source, and every accepted fix was applied on its branch with a test and pushed.

## Verdicts

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 local-cluster default since 1.19 | CONFIRMED (from this repo's records) | CONFIRMED (`policy.rst` 49–56; the chart value `clustermesh.policyDefaultLocalCluster=true`, configurable) | — the plan now names the value |
| C2 `cluster_name` + the cluster label on flows | CONFIRMED (fixture) | CONFIRMED (`flow.proto` 276–285) | — |
| C3 the L7 record's shape | CONFIRMED (fixtures) | CONFIRMED (`flow.proto` 243–260, 684–719; DNS also has `cnames`, `rcode`) | — |
| C4 Path/Method regexes, not anchored by Cilium | PLAUSIBLE | REFUTED: Envoy's safe-regex matches the whole header, so bare `/payments` never matched `/payments-admin` (`envoy_l7_rules_translator.go` 62–117) | **Accepted as a premise correction**: the anchors stay (explicit, valid); `:path` carries the query string, so the rule allows an optional query; the plan's text corrected |
| C5 kube-dns selector, UDP/53 | CONFIRMED | CONFIRMED (`layer3.rst` 450–499, `layer7.rst` 172–202) | — **measured**: pods `k8s-app=kube-dns`, Service ports 53/UDP and 53/TCP; the UDP-only rule is upstream's and the FQDN path's; DNS over TCP is a follow-up note, not changed |
| C6 policy-verdict events, 5.6 % | PLAUSIBLE | PLAUSIBLE (semantics confirmed from `parser.go` 182–211; the share not re-measured) | — (measured in the plan) |
| C7 E1 | REFUTED | REFUTED (same: the label-only cluster was discarded; single-cluster outputs byte-identical to develop, SHA-256 compared) | **Accepted**: empty `cluster_name` fell back to nothing though the label was on the flow — `clusterOf` reads the label; the fixture is an established-connection packet traced on the destination's node, the egress policy is still the right one (plan text corrected) |
| C8 E2 | REFUTED (strip the search expansion) | REFUTED (one L7 block was attached to every port of a peer pair — release blocker; the expansion must be KEPT: an L7 DNS policy allows only listed names) | **Accepted from Codex, Cursor's strip reverted**: L7 records live on their port (one port rule per port with rules); the path regex allows an optional query; DNS queries kept exactly as observed — the docs decided (`layer7.rst`: "No other DNS queries will be allowed") |
| C9 E3 | CONFIRMED / PLAUSIBLE | CONFIRMED | — |
| C10 E4 | REFUTED (key order) | REFUTED (a name-only key removes every component) | **Accepted from both**: the page sends a peer's whole identifying label set as one comma-joined exclude that must match entirely; a bare `key=value` still matches every peer carrying it |
| C11 E5 | REFUTED | REFUTED (same) | **Accepted**: `port: 80` and `port: "80"` compare equal (scalars canonicalised as strings); labels stay untouched by design |
| C12 E6 | CONFIRMED / PLAUSIBLE | REFUTED: `ConstantTimeCompare` returns at once on unequal lengths; the scheme was case-sensitive; the Grafana selector lacked its namespace | **Accepted**: `reserved:ingress` and `reserved:host` admitted (measured); the Grafana selector default empty; the token compare hashes both sides before the constant-time compare and the scheme is case-insensitive |
| C13 E7 | REFUTED | REFUTED (same) | **Accepted**: `Line` excluded from the frame left the Generate action an empty body — kept and hidden as the 23862 dashboard does; CI asserts it on the Loki table |
| C14 E8 | REFUTED | REFUTED (same, plus: the example inherited the plaintext relay on port 80, refused by a mutual-TLS relay) | **Accepted**: the example pins `quay.io/cilium/cilium:v1.20.1` and carries the relay's mutual-TLS settings; rendered `--server hubble-relay.kube-system.svc.cluster.local:443` |
| C15 E10 | REFUTED / CONFIRMED | REFUTED: inputs interpolated into shell (script injection), downloads left in the checkout and committed by the PR action's default selection, no checksum check | **Accepted**: inputs reach the shell through the environment; the archive's checksum is verified; downloads go to `mktemp` directories; `add-paths` commits only the policy file; `setup-go` added; `--local-crds` takes a directory (measured) |

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

## Codex's findings the branches now carry, beyond Cursor's

- **E2 per-port L7 (release blocker).** `HTTPRequests`/`DNSQueries` moved from the aggregated flow to its
  `PortInfo`; the generator emits one port rule per port that carries L7 records and keeps the plain ports
  together. Test: a peer pair with 5432 plain and 8080 HTTP yields `[5432] [8080 + rules]`.
- **E2 keep the DNS query as observed.** Cursor's strip was reverted; the test asserts the measured
  expansion `accounts.bank.svc.cluster.local.bank.svc.cluster.local` is emitted as is.
- **E2 optional query in the path regex** (`^…(\?.*)?$`), tested against four paths.
- **E4 whole-label-set exclude.** Tested: unticking `shop/frontend` keeps `shop/backend`; `name=shop` alone
  removes both.
- **E6 compare and scheme.** SHA-256 both sides, `strings.EqualFold` on `Bearer`; tested with a shorter, a
  longer and a `Basic` header.
- **E8 relay settings** in the example, rendered.
- **E10 workflow**: env indirection, checksum, temp directories, `add-paths`.

Codex's remaining suggestions not taken: carrying `Host` into the HTTP rule (the observed host is the
Gateway's name for Gateway traffic and the Service name for pod traffic — narrowing on it would break
clients that use another; documented as a design choice), and `RequestURI` verbatim (pins exact query
strings; the optional-query regex is the intent).

## Outcome

Fifteen claims. Cursor refuted seven, Codex ten (six in common, plus C4 as a premise, C8's per-port defect,
C12's compare, C15's workflow security). Every refutation was re-traced against the cited source or measured
on poc1, and on the one point where the reviewers disagreed (the DNS search expansion) the documentation
decided for Codex. Every accepted fix is on its branch with a test that fails before and passes after; the
suites are green (`go test ./...` on E1, E2, E4, E5, E6; `helm lint` and the renders on E6, E7, E8; the E7
CI job; the template parses). The plan's stack facts stood, one corrected (C4). Nothing is merged: the
branches wait for the operator's go, in the order the plan gives.

## After the merge (added 2026-09-13)

The branches were merged in the plan's order and released (cf2cnp 0.6.0, then 0.6.1; hubble-policy-verdicts 0.2.0; the observer fork), and demos 29–34 ran every item on the clusters. Six defects surfaced that neither reviewer could reach from source, a render or an offline `go test` — each needed the thing to run: `merge` re-serialised the whole file (a PR diff of the file, not the rule), the kube-dns rule appeared twice, the E10 install step saved the archive under a name its checksum line did not carry, the PR step needed a repository setting, the subchart's stricter policy was idle beside the parent chart's `[cluster, world]`, and two releases of the observer chart shared one container name in Loki. All are fixed on the forks and in the template, and recorded in the demos and gotchas #87–#89. The lesson for the next review brief: demand one real run of every artefact that has an environment (a workflow, a second release, a merge on a real file), not only its tests.
