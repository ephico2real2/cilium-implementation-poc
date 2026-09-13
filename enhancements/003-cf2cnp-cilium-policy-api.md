# Enhancement 003 — cf2cnp consumes Cilium's own policy spec: the full CiliumNetworkPolicy of 1.20.x, validated the way the agent validates, announced per release

Status: **plan for review** (2026-09-13). The forensic analysis it rests on is on the fork branch
[`enh/E12-cilium-policy-api`](https://github.com/ephico2real2/cf2cnp/tree/enh/E12-cilium-policy-api):
[`docs/CRD-SPEC-FORENSICS.md`](https://github.com/ephico2real2/cf2cnp/blob/enh/E12-cilium-policy-api/docs/CRD-SPEC-FORENSICS.md)
with the probe programs under `hack/cilium-api-probe/`. Nothing is changed in cf2cnp's code yet.

## 1. Why, in one paragraph

cf2cnp writes CiliumNetworkPolicies from 20 hand-written fields; the CRD of Cilium 1.20.1 has 291 schema paths
under `spec`. The gap showed up as a wrong policy — a world *source* has no `fromCIDR`, so the tool wrote an ingress
rule with no peer at all, which Cilium reads as "anyone on this port" — and it will show up again with every field
the next demo needs. Adding fields one by one keeps the tool a step behind the spec and leaves it unable to say
which spec it supports. The fix is to make cf2cnp **consume the spec**: Cilium's own Go types for the rules, Cilium's
own `Sanitize()` for the semantics the agent enforces at admission, the CRD schema of the same version embedded for
the shape, and the version printed and released. Measured feasible today: zero `replace` directives, 18 MB binary,
Go 1.26.

## 2. What the forensics established (the facts the plan uses)

| Fact | Where measured |
|---|---|
| 20 of 291 schema paths modelled; `fromCIDR`, `icmps`, `enableDefaultDeny`, the deny lists, `toCIDRSet`, `endPort`, `toServices`, TLS, `authentication` and more are not | forensics §2 (every field, with the source it could have: flows, intent, pass-through) |
| A `reserved:world` source produces an ingress rule with **no peer** (wider than observed) — the finding, read from `generateEntityIngressRules` | forensics §2.5 |
| `github.com/cilium/cilium@v1.20.1` `pkg/policy/api` builds with **no `replace` lines**, 310 modules, **18.1 MB** binary (cf2cnp today: 9 modules, 11.6 MB); importing the k8s **client** package for the embedded CRD costs **93.6 MB** — so the CRD is copied from the module cache and embedded as a file | forensics §3, probes 1–3 |
| `api.Rule.Sanitize()` is the agent's admission validation as a library: it refused *"combining FromEndpoints and FromCIDR is not supported yet"*, which the CRD schema accepts; the schema refused `protocol: tcp`, which `Sanitize` fixes — **two layers, both needed** | probe 3 |
| `Sanitize()` **mutates** (selector keys get Cilium's `any:` prefix, `enableDefaultDeny` is filled, the protocol upper-cased): it runs on a `DeepCopy()`; the original is rendered | probes 2 and 3 |
| `sigs.k8s.io/yaml` renders the CRD's shapes with alphabetical keys (`kubectl get -o yaml` order); the 0.6.1 node-based `merge` is unaffected | probe 1 |
| The supported spec is a build fact: `debug.ReadBuildInfo()` → `cilium v1.20.1`; the module needs Go 1.26 | probe 3 |

## 2.1 Two decisions, researched (2026-09-13)

**Decision 1 — how the YAML is rendered once the types come from upstream.** What the ecosystem does, checked:

| Practice | Source | What it means for cf2cnp |
|---|---|---|
| Import the published API module at a pinned version; never copy structs (`k8s.io/api` exists "to avoid diamond dependency problems … use the go types in this repo rather than copying structs") | [k8s.io/api](https://pkg.go.dev/k8s.io/api), [Go modules with the Kubernetes API](https://medium.com/programming-kubernetes/using-go-modules-with-kubernetes-api-and-client-go-projects-2f3fdd5589a) | the swap to `github.com/cilium/cilium/pkg/policy/api` is the normal way, not an exception |
| Kubernetes types carry `json` tags only; `sigs.k8s.io/yaml` marshals through JSON, so it is the library that renders them — and it "does not respect original mapping key order": keys come out alphabetical | [sigs.k8s.io/yaml](https://github.com/kubernetes-sigs/yaml/releases), [kubebuilder #1930](https://github.com/kubernetes-sigs/kubebuilder/issues/1930) (the trade-offs of the JSON step: performance, `json` tags instead of `yaml` tags, feature lag — kubebuilder kept it) | alphabetical output would put `egress` before `endpointSelector` and `labels` before `name`: correct, `kubectl`-like, and less readable than today |
| Tools that write Kubernetes YAML for humans **own a canonical field order**: kustomize/kpt's `kyaml` formatter orders "commonly encountered Resource fields" by a precedence list (`FieldOrder`, built from `fieldSortOrder`), sorts unknown fields lexicographically, and drops comments — a separate concern | [kyaml FormatFilter](https://pkg.go.dev/sigs.k8s.io/kustomize/kyaml/kio/filters), [kyaml/yaml](https://pkg.go.dev/sigs.k8s.io/kustomize/kyaml/yaml) | the sustainable pattern: **types from upstream, rendering owned by the tool** |

**Taken:** upstream types, marshalled with `sigs.k8s.io/yaml` to JSON, loaded into a `yaml.v3` node tree, and
**re-ordered by a cf2cnp-owned precedence list** (the kustomize pattern) — `apiVersion, kind, metadata{name,
namespace, labels, annotations}, spec{description, endpointSelector, nodeSelector, enableDefaultDeny, ingress,
egress, ingressDeny, egressDeny, labels, log}`, a rule's `from*`/`to*` before `toPorts`, `icmps`, `authentication`,
a port's `port, endPort, protocol`, then `rules`; everything unknown lexicographically. That is today's order, so the
golden tests need **no** accepted difference, `merge` keeps working on nodes, and the comment lines cf2cnp adds stay a
node operation instead of text. One small package (`internal/render`), one table, one test that every CRD field has a
place or falls into the lexicographic tail.

**Decision 3 — the DNS resolver rule is derived, not hard-coded.** Cilium's DNS-policy guide gives the resolver
rule for Kubernetes and says, verbatim: "OpenShift users will need to modify the policies to match the namespace
`openshift-dns` (instead of `kube-system`), remove the match on the `k8s:k8s-app=kube-dns` label, and change the port
to 5353" ([DNS-based policies](https://docs.cilium.io/en/stable/security/dns/)). OpenShift's DNS operator runs CoreDNS as the
DaemonSet `dns-default` in `openshift-dns`, listening on **5353** (container ports `dns`/UDP and `dns-tcp`/TCP),
behind the Service `dns-default` on 53; the pods carry the operator's own labels, not `k8s-app`
([cluster-dns-operator daemonset.yaml](https://github.com/openshift/cluster-dns-operator/blob/master/pkg/manifests/assets/dns/daemonset.yaml),
[OpenShift DNS Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.10/html/networking/dns-operator)).
cf2cnp today writes one hard-coded rule (`kube-system`, `k8s-app: kube-dns`, `53/UDP`) for both the `toFQDNs` path
and `--dns-visibility`.

**Taken:** the resolver rule comes from the **observed DNS flows** when the input has them — the destination's
namespace and identifying labels, the destination port and protocol as Hubble reports them (`53` on Kubernetes,
`5353` on OpenShift, `ANY` when both UDP and TCP were seen) — and from a **profile** when it does not:
`--dns-profile kubernetes` (the docs' rule: `kube-system` + `k8s-app: kube-dns`, `53/ANY`), `--dns-profile openshift`
(`openshift-dns`, no `k8s-app` label, `5353/ANY`), `--dns-profile auto` (default: from the flows, else `kubernetes`),
and `--dns-resolver <namespace>[/<label>=<value>]:<port>` for anything else. The description names the resolver as
written (`to dns-default in openshift-dns on ANY/5353 (DNS *)`). Test fixtures: a Kubernetes DNS flow (demo 31's) and
a synthesised OpenShift one (destination in `openshift-dns`, labels `dns.operator.openshift.io/daemonset-dns=default`,
port 5353).

## 3. The plan — branch `enh/E12-cilium-policy-api`, release cf2cnp 0.7.0

| Step | Change | Test that proves it |
|---|---|---|
| E12.1 | `go.mod`: `github.com/cilium/cilium v1.20.1`, `sigs.k8s.io/yaml`, Go 1.26; `internal/policy/types.go` deleted; one envelope `Policy{TypeMeta, ObjectMeta, Spec *api.Rule}`; the generator builds `api.*` values (selectors as `EndpointSelector{LabelSelector: &slimv1.LabelSelector{MatchLabels: …}}`, never the prefixing constructors); protocols normalised to the enum; **`internal/render`: the canonical field order (decision 1)**, comments as node operations | **golden tests**: every saved flow file under this PoC's `demos/2[6-9]*/policies` and `demos/3*/policies` (40+ policies) regenerated and diffed against the committed policy — **byte-identical** is the bar; a test that every CRD field has a place in the order table or falls into the lexicographic tail |
| E12.2 | `Sanitize()` on a deep copy of every generated and merged rule; on `/generate` an error is a 400 with Cilium's message, on the CLI an exit 1 | a rule mixing a pod peer and a CIDR peer is refused with the agent's own sentence; a valid one passes |
| E12.3 | `internal/crd/ciliumnetworkpolicies.yaml` copied from the module cache by `go generate` and embedded; `cf2cnp validate <file…>` validates documents against it offline (the same library `kubectl-validate` uses, or `kubectl-validate` as a `go run` in CI if the library is too heavy — measured before choosing); CI asserts the copy is byte-identical to the module's | `cf2cnp validate` rejects `protocol: tcp` and accepts the golden set; CI fails if the copy drifts |
| E12.4 | `cf2cnp version`: the tool's version and "CiliumNetworkPolicy `cilium.io/v2` as of Cilium v1.20.1"; the README's table "cf2cnp release → Cilium spec"; the chart's `appVersion` note; a Renovate rule for `github.com/cilium/cilium` whose PR re-runs `go generate` and the golden tests | `cf2cnp version` output tested; the release notes template names the spec |
| E12.5 | **`fromCIDR` for world sources** (the finding): one `/32` per observed source address, its own rule (never mixed with `fromEndpoints`: Cilium refuses the mix), a comment like `toCIDR`'s; the description reads `from 172.18.255.170/32` | a flow with a `reserved:world` source and an address yields `fromCIDR`; two addresses yield two entries; a pod peer and a world peer in one policy yield two rules and `Sanitize` passes |
| E12.6 | **The DNS resolver rule from the flows, with profiles** (decision 3): `--dns-profile auto` / `kubernetes` / `openshift`, `--dns-resolver`; the `toFQDNs` path and `--dns-visibility` share it; the description names the resolver | the Kubernetes and the OpenShift fixtures produce the docs' two rules; without a DNS flow, `auto` falls back to `kubernetes`; `openshift` writes `openshift-dns`, no `k8s-app`, `5353/ANY` |
| E12.7 | `--default-deny` (`enableDefaultDeny: {ingress: true}` on ingress policies, `{egress: true}` on egress ones) so the demos' hand-written default-deny object is no longer needed; `--deny-excluded` (an `exclude=` peer becomes an `ingressDeny` rule) | the options render the fields; without them the output is unchanged |
| E12.8 | `icmps` from ICMP flows; HTTP `host`/`headers` behind options (off by default, the review's reasoning) | fixtures from Hubble ICMP and HTTP flows |
| E12.9 | Review (Codex + Cursor, the same brief format as 001): claims per step, the golden diff, the two validation layers, the dependency graph (`go mod why`), the binary size | `docs/REVIEW_ENH-003.md` |

Order matters: E12.1–E12.4 are the platform and ship as **0.7.0** with `fromCIDR` (E12.5, the demo needs it) and the
DNS resolver from the flows (E12.6, OpenShift users need it); E12.7–E12.8 follow as 0.7.x. Enhancement 002's phase 0 depends on 0.7.0.

## 4. What it changes for the operator

- A release says which Cilium spec it supports, and a Cilium release becomes a cf2cnp release with a known diff.
- A generated policy is refused by cf2cnp for the reasons the agent would refuse it, before it is applied.
- Any field of the spec can be written by the generator once a source for it exists; `merge` preserves all of them
  already.
- The demos' default-deny companion object becomes an option on the generated policy.

## 5. Risks

| Risk | Answer |
|---|---|
| The dependency is large (310 modules) | measured; the k8s client packages are the line not crossed; a `go mod why` check in CI keeps it that way |
| Output byte-changes break the demos' recorded policies | the canonical field order keeps today's layout; the golden tests demand byte identity over the demos' files |
| Cilium's Go requirement (1.26) | the Dockerfile and the release workflow read `go.mod` |
| `Sanitize` semantics differ between Cilium versions | the module version is the spec version; the golden tests run on every bump |
