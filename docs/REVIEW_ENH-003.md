# Review — Enhancement 003: cf2cnp 0.7.0 consumes Cilium's own policy spec

Adversarial pass, 2026-09-13, on the 13-claim brief for
[`enhancements/003-cf2cnp-cilium-policy-api.md`](../enhancements/003-cf2cnp-cilium-policy-api.md) as implemented on
the fork branch `enh/E12-cilium-policy-api` ([PR #2](https://github.com/ephico2real2/cf2cnp/pull/2)). Cursor (Grok
4.6 high fast, ask mode: shell and network refused, so it traced the branch at `7be44d6`, the Cilium v1.20.1 module
in the local cache and the goldens, and marked what needed a live process PLAUSIBLE). Codex (gpt-5.6-sol, xhigh, 71
minutes, task `task-mu04bq5s-j7du4e`, session `01a09bec-4c20-7d81-bfe8-3c11552bc536`) worked in a `git archive`
copy under its own scratch directory, applied its patches there and ran `go test`; it read the branch at `70a9571`,
i.e. after Cursor's accepted fixes had landed, so its C8, C9 (in part), C10 and C13 confirm those. Every verdict
below was re-checked here against the branch, the Cilium v1.20.1 sources, and a live run of the built binary; every
accepted fix was applied on the branch with a test that failed first, and pushed (`4a0aa90`, `70a9571`, `cc01b46`).

## Verdicts

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 the envelope and `Selector()` | CONFIRMED (no `MarshalJSON` on `EndpointSelector` at v1.20.1; the `any:` prefix comes from `Sanitize` via `NewESFromK8sLabelSelector`; the envelope has no `specs`) | REFUTED: the value `Spec api.Rule` renders `spec: {}` on a `specs`-only document; `NewESFromLabels` prefixes, `NewESFromMatchRequirements` keeps raw keys | — ; `Specs` added to the envelope for `validate` (C5); Codex: — on the fact, **snippet rejected**: no code path renders a decoded `specs` document (`validate` validates, `merge` edits the node tree), and an `omitzero` + presence bit is machinery without a user |
| C2 render: byte identity and the precedence table | PLAUSIBLE (could not run `TestGolden`; the table's mechanics hold in code) | REFUTED: 14 goldens pass, the round trip keeps the quoting; `specs[]` fell to the lexicographic tail | — (14 goldens byte-identical, CI); Codex: **Accepted**: `specs` shares the rule order; `TestRender_SpecsUseRuleOrder` |
| C3 the deliberate golden change | CONFIRMED (the comment is keyed on `rules:\n            dns:`; Cilium forbids DNS L7 on ingress, so no ingress case) | CONFIRMED (develop keyed the comment on `k8s-app: kube-dns` anywhere in the file; regenerated 0.6.3 shows the false comment) | — |
| C4 `Validate` on a copy, 400, exit 1 | REFUTED: the copy, the 400 and the exit are real; `validate` split files on `\n---`, which cuts a literal block holding such a line | CONFIRMED (deep copies; 400; exit 1; 13 fixtures pass and the reply fixture exits 1 on purpose; the decoder, not a split) | **Accepted**: `DecodePolicyDocuments` (yaml.v3 decoder finds the boundaries); `TestDecodePolicyDocuments`; Codex: **Accepted** (Cursor) |
| C5 Sanitize + CRD cover admission | REFUTED: Sanitize sees the rule, not the object — no check on `metadata.name`; `endPort` without `port` is caught | REFUTED: three documents the API server, the CRD or the agent refuse passed — `namespace: BAD_NAMESPACE` + a label key with a space, `protocol: tcp`, a `nodeSelector` on a namespaced policy (`cnp_types.go` Parse: "rule cannot have NodeSelector") — "the most important finding" | **Accepted**: `Validate` refuses a name that is not a DNS-1123 subdomain and validates `specs` rule by rule; `TestValidate_ObjectNameAndSpecs`; Codex: **Accepted from both**: `ValidateObjectMeta`, the CRD protocol enum on every ports list, no nodeSelector unless clusterwide, `specs` rule by rule; `TestValidate_MatchesAdmission` |
| C6 the embedded CRD and CI | PLAUSIBLE (paths consistent; `kubectl-validate` needs network on first run) | REFUTED on the wording only: `k8s.io/client-go/util/jsonpath` and its forked template ride along via `pkg/command`; no client machinery; 19,568,576 bytes | — **rejected as a change**: CI already asserts exactly that boundary (Codex calls it correct); its Go test shelling out to `go list` duplicates the CI step |
| C7 Renovate re-runs `go generate` | REFUTED: `postUpgradeTasks` run on self-hosted Renovate only, and only for commands on `allowedCommands`; the Mend app ignores them | PLAUSIBLE: hosted Renovate exposes only an undocumented allow-list; the app would bump `go.mod` and skip the generator | **Accepted on the fact**: `renovate.json` says so; `TestEmbeddedCRDVersionMatchesModule` — snippet rejected (see below); Codex: **Accepted on the fact** (Cursor); Codex's CI step `go generate && git diff` **rejected**: the existing `cmp` against the module's file is the same check, byte for byte; its test reading `renovate.json` is a config lint, not behaviour |
| C8 `fromCIDR` for world sources | CONFIRMED (world + address → `FromCIDR`, `/32` and `/128`, Hubble's `IP.source` is pre-SNAT) — and, volunteered: **dual-stack world labels are not matched** | CONFIRMED on `70a9571` (all three world labels; `fromCIDR` xor `fromEntities`; `/32`, `/128`; Hubble's pre-SNAT `IP.source`) | **Accepted**: `reserved:world-ipv4` / `reserved:world-ipv6` are world (see below); Codex: **Accepted** (Cursor); confirmed by Codex after the fix |
| C9 the DNS resolver derived and profiled | REFUTED: (d) `looksLikeDNS` takes every `kube-system` peer on 53/5353; the kubernetes profile writes `53/UDP` where Cilium's example writes `53/ANY` | REFUTED: the derivation is right on `70a9571` (NodeLocal included, per the LRP doc); but a derived resolver kept a lone observed UDP, denying the TCP retry of a truncated answer; Cilium's examples and its validator say ANY | **Accepted on the facts, one snippet corrected**: the derivation takes CoreDNS / kube-dns / NodeLocal by label and OpenShift by namespace; profiles `ANY`; the goldens unchanged; Codex: **Accepted**: derived resolvers are ANY; the ANY L7 rule shadows the plain UDP/TCP twin; two goldens regenerated with the reason recorded; `TestDerivedDNSResolver_IsANY` |
| C10 page and API parameters | CONFIRMED (unknown profile → 400; `auto` sends nothing; values marshalled, never concatenated) | CONFIRMED (on `70a9571`: server defaults, request wins, 400, typed values) | — |
| C11 merge round-trips through JSON | CONFIRMED (no `matchExpressions: null`; `port: 80` vs `"80"` covered) | CONFIRMED (six merge tests; no custom marshal on `EndpointSelector`) | — |
| C12 CLI: `--input` file or dir, `version` | CONFIRMED (`ReadBuildInfo` survives `-trimpath` and `-s -w`) | CONFIRMED (file or dir; exit 1 without usage; Go 1.26 in go.mod, Dockerfile, workflows; both versions `v1.20.1`) | — |
| C13 the chart needs nothing new | REFUTED: `serve` had no DNS flags, so an OpenShift Grafana action (no `?dnsProfile=`) got the kubernetes resolver, which selects nothing there | CONFIRMED on `70a9571` (chart 0.7.0; no DNS flags by default; `openshift` renders the flag and the 5353/ANY rule; custom resolver renders `--dns-resolver`) | **Accepted**: `serve --dns-profile` / `--dns-resolver` (env too), chart `dns.profile` / `dns.resolver`, the chart's own policy follows the profile; `TestGenerate_ServerDNSDefaults`; Codex: **Accepted** (Cursor); confirmed by Codex after the fix |

## Measured here, independent of the reviewers

| What | Result | Used for |
|---|---|---|
| `pkg/labels/cidr.go` `getWorldLabel` (v1.20.1) | `world-ipv4` for an IPv4 address when IPv6 is enabled, `world-ipv6` the other way round; `world` only single-stack | C8 |
| `cilium-dbg identity list` on poc1 (IPv4-only) | `2 reserved:world`, `9 reserved:world-ipv4`, `10 reserved:world-ipv6`, `13 reserved:aggregate-world` | C8 |
| `TestParse_DualStackWorldLabels` against `7be44d6` | a `reserved:world-ipv4` destination parsed with `IsWorldTraffic:false`, `DestEntity:""` — no peer at all | C8 |
| the 14 goldens: which carry a resolver rule and from where | `31-pos-fqdn`, `31-pos-dns-visibility`, `29-worker-poc2-egress` — all derived from UDP lookups in the flows; none uses the profile fallback | C9: the profile change moves no golden |
| `docs/CRD-SPEC-FORENSICS.md` §6 as written before the review | the design said `kubernetes` = `53/ANY`; `dns.go` wrote `UDP` | C9: the code did not follow its own design |
| `local-redirect-policy.rst` (v1.20.1) | under the node-local DNS LRP the backend is `kube-system/node-local-dns-*` — the lookups reach that pod | C9: NodeLocal is a resolver, not an exclusion |
| the built binary, `serve` with `CF2CNP_DNS_PROFILE=openshift`, first try | wrote the kube-dns rule — cobra's `StringVar` on a variable shared with `generate`/`merge` reset it to the last registered default | C13: `serve` got its own variables; re-measured: `openshift-dns` |
| `serve --dns-profile nope`, `CF2CNP_DNS_RESOLVER=broken` | exit 1 at start with the parse error | C13 |
| `helm lint`; `helm template` default, `dns.profile=openshift`, `networkPolicy.enabled` with each, a custom `dnsEgress` | args carry the flags only when set; the policy's DNS egress is kube-dns `53/ANY`, `openshift-dns 5353/ANY`, or the custom rule | C13 |
| `cf2cnp validate` on a two-document file: a literal block holding `---`, an empty document, a `Bad_Name` object in `specs` form | document 1 ok, document 2 refused on `metadata.name`, exit 1 | C4, C5 |
| CI run 34774484089 on `4a0aa90` | `TestEmbeddedCRDVersionMatchesModule`: `module ""` — the test binary on the runner reports no build-info `Deps` | C7: the snippet |

## C8 — dual-stack world labels (Cursor, volunteered; Codex's interim message named the same)

**Finding.** The parser's `isWorldTraffic` matched `reserved:world` alone. On a dual-stack Cilium the world identity
is `world-ipv4` (9) or `world-ipv6` (10), so the new `fromCIDR` path never ran there and, worse, an egress to such a
peer was neither world nor an entity.

**Re-check.** `getWorldLabel` in `pkg/labels/cidr.go` and `GetWorldIdentityFromIP` in `pkg/identity/numericidentity.go`
at v1.20.1; `NumericIdentity.IsWorld` counts all three as world. The failing test on the old head printed the parsed
flow with no world flag and no entity (table above). poc1 is IPv4-only, so its own flows never showed it.

**Decision.** Accepted. `worldLabels` in the parser (all three are world and the `world` entity); two fixtures with
identity 9; `TestParse_DualStackWorldLabels`. Recorded in the forensics §2.5.

## C9 — the resolver derivation and the profiles (Cursor findings 1 and 4)

**Finding.** `looksLikeDNS` returned true for any `kube-system` destination on 53/5353. Cursor's snippet narrowed
it to the `kube-dns`/`coredns` labels and the `openshift-dns` namespace and **excluded** `node-local-dns` ("a cache,
not the cluster resolver"). And the kubernetes profile wrote `53/UDP`; Cilium's `dns-matchname.yaml` writes `ANY`.

**Re-check.** The catch-all is real (`dns.go` at `7be44d6`). The exclusion is wrong: under Cilium's node-local DNS
Local Redirect Policy the lookups are redirected to the `node-local-dns` pod on the node (`local-redirect-policy.rst`:
`10.96.0.10:53/TCP -> 10.244.1.49:53(kube-system/node-local-dns-72r7m)`), so the flow's destination — and the pods
the rule must name for the proxy to see the lookups — is that pod. A rule naming kube-dns would cut the pod off.
On the protocol: the forensics §6 design already said `53/ANY`; `dns.go` did not follow it. No golden uses the
profile (all three resolver rules in the goldens are derived from observed UDP lookups), so the change moves nothing
that 0.6.3 wrote from flows.

**Decision.** Accepted on both facts; the exclusion rejected — `k8s-app` in {`kube-dns`, `coredns`,
`node-local-dns`} or the `openshift-dns` namespace, nothing else. Profiles `ANY`; a `--dns-resolver` without a
protocol is `ANY` too; a derived resolver keeps the observed protocols. `TestLooksLikeDNS_NotTheWholeOfKubeSystem`
(NodeLocal derives), `TestDNSProfiles_FollowCiliumGuide`; the historic-rule test compares against an explicit
`53/UDP` resolver, since the profile no longer is one. README and forensics §6 corrected.

## C4 — `validate` split on `\n---` (Cursor finding 2)

**Finding.** `strings.Split(b, "\n---")` makes a literal block containing a `---` line a second document.

**Re-check.** A file with `description: |` holding `---` was two documents on the old head (the second failed to
parse). Cursor's snippet (a yaml.v3 `Decoder` over `yaml.Node`, re-marshalled and read by sigs.k8s.io/yaml) traced
correctly; an empty document (`---\n---`) is skipped by tag `!!null`.

**Decision.** Accepted, as `policy.DecodePolicyDocuments`; `runValidate` uses it. Measured with the two-document
file above.

## C5 — `Validate` never checked the object (Cursor finding 3)

**Finding.** Sanitize is the rule's; the agent refuses an empty name and the API server a non-DNS-1123 name;
`validate` accepted both.

**Re-check.** `cnp_types.go` `Parse` (empty name refused); `IsDNS1123Subdomain` is in apimachinery, already in the
graph. Generated names go through `sanitizeK8sName`, so this guards `validate` and `merge` inputs. While adding it:
the envelope had no `specs` (Cursor C1), so a policy in Cilium's list form validated as empty — `Specs` added and
validated rule by rule; a policy with `specs` and no `spec` is legal (Cilium's `Parse`: either, or both), which my
first cut got wrong and the test caught.

**Decision.** Accepted, snippet extended to `specs`. `TestValidate_ObjectNameAndSpecs`.

## C13 — no cluster-wide DNS default (Cursor finding 5)

**Finding.** `serve` had no `--dns-profile`/`--dns-resolver`; the chart could not set one; the Grafana action sends
none.

**Re-check.** True on `7be44d6` (`main.go`: the flags were on `generate` and `merge` only). Cursor's snippet applied
the server default and then the request's parameters; a request's `dnsProfile` would still have lost to a server
`dnsResolver`, because a resolver wins over a profile in `resolveDNS`. And the first build lost the env default
entirely: cobra's `StringVar` on the shared variable reset it when `merge` registered its flag last (measured with
the binary: `CF2CNP_DNS_PROFILE=openshift` produced the kube-dns rule).

**Decision.** Accepted; snippet corrected twice — the request's profile replaces the server's resolver, and `serve`
owns its two variables. Defaults are checked at start (exit 1 on a bad one). Chart: `dns.profile` / `dns.resolver`
→ args; the chart's own CiliumNetworkPolicy's DNS egress follows the profile (`53/ANY`, or `openshift-dns 5353/ANY`)
with `networkPolicy.dnsEgress` for a custom resolver — Cursor's "not asked" chart debt, fixed in the same values.
`TestGenerate_ServerDNSDefaults`; helm states measured.

## C7 — hosted Renovate and the CRD copy (Cursor finding 6)

**Finding.** `postUpgradeTasks` never run on the Mend GitHub App. Snippet: a test comparing `crd.Version()` with the
cilium entry of `debug.ReadBuildInfo().Deps`.

**Re-check.** Renovate's documentation agrees (self-hosted, `allowedCommands`). The test passed locally and failed
on the GitHub runner with `module ""` — the test binary there carries no `Deps`; the cause was not chased.

**Decision.** Accepted on the fact; snippet rejected. The test reads the `github.com/cilium/cilium` line of
`go.mod`, proven to fail with `VERSION` set to `v1.20.0` and pass restored. `renovate.json` says what hosted
Renovate does not do and names CI as the guard.

## Not asked, and what happened to it

- Cursor: `hostCIDR` writes `/128` for an IPv4-mapped IPv6 literal — no change; Hubble decodes IPv4 flows as IPv4.
- Cursor: the chart's optional policy pinned kube-dns `53/UDP` — fixed under C13.
- Cursor: NodePort traffic SNATed to a node is `reserved:host`, so it stays `fromEntities` — noted, correct.
- Codex: `cf2cnp validate` still accepts what the CRD schema alone refuses beyond the protocol enum (unknown fields
  are ignored by the decoder, as `kubectl apply` without strict field validation would) — the CI job runs
  `kubectl-validate` over the goldens for that layer; `validate` is the agent's checks plus the object's, and its
  help says so.

## C5 (Codex) — `validate` promised admission and checked the rule only

**Finding.** With Cursor's name check in place, Codex fed three documents that the API server, the CRD or the
agent refuse and `Validate` accepted all three: a namespace that is not DNS-1123 with a label key holding a space
(ObjectMeta validation, `k8s.io/apimachinery/pkg/api/validation/objectmeta.go`), `protocol: tcp` (the CRD's enum is
upper case; Sanitize upper-cases on its copy, so it never sees the fault), and a `nodeSelector` on a namespaced
policy (`cnp_types.go` Parse: "rule cannot have NodeSelector"). Snippet: `ValidateObjectMeta` with
`requiresNamespace = !clusterwide` and kubectl's default namespace substituted for the check, a walk over every
`toPorts` of the four rule lists through Cilium's `PortsIterator` against the enum, the nodeSelector rule, `specs`
rule by rule.

**Re-check.** The CRD's `protocol` enum, read from the embedded file at all eight paths: `TCP UDP SCTP VRRP IGMP
GRE IPIP IPV6 ESP AH ANY` — the `crdProtocols` set plus the empty string the schema allows by omission. The agent's
Parse at `cnp_types.go:195-212` refuses the nodeSelector for both `spec` and `specs`. `k8s.io/apimachinery/pkg/api/
validation` adds no module and no client package. All five documents (Codex's three, plus a `udp` in `egressDeny`
and a label-key case split out) were accepted on `70a9571` and are refused on `cc01b46`; a clusterwide policy with
a nodeSelector and a namespaced policy with no namespace still pass. The 14 goldens still validate.

**Decision.** Accepted, compacted (one `validateRule`, a set for the enum). `TestValidate_MatchesAdmission`.

## C9 (Codex) — a derived resolver rule on UDP alone

**Finding.** The Cursor-pass decision kept the observed protocol for a derived resolver. Codex: every golden's
lookups are UDP, so every derived rule is `53/UDP`; a truncated answer retries over TCP and the rule denies it under
default-deny egress. Cilium's examples write `ANY` for both platforms; `rule_validation.go:520-551` allows TCP, UDP or
ANY for DNS L7. Snippet: `DeriveDNSResolver` writes ANY; `dropShadowedDNSRule` drops the plain twin whatever its
protocol; two goldens regenerated.

**Re-check.** The failure is silent until a large answer arrives, and the rule's purpose is the proxy, not a
protocol restriction — the same argument that moved the profiles to ANY in the Cursor pass; it applies to the
derived rule too, and my earlier "keep what was observed" was the wrong principle for this one rule. The two
goldens differ from 0.6.3 in exactly the protocol and the description's `ANY/53`; `kubectl-validate` passes on both.

**Decision.** Accepted. The Cursor-pass decision on the derived protocol is reversed and recorded as such in the
forensics §6 and the golden README. `TestDerivedDNSResolver_IsANY`; the `DerivedKubernetes` test compares against
the profile again.

## C1 / C2 (Codex) — the `specs` form

**Finding.** The envelope's value-typed `Spec` renders `spec: {}` on a `specs`-only document, and `specs[]` rendered
in lexicographic order. Snippet: `omitzero` plus a presence bit set in a custom `UnmarshalJSON`; `specs` in the
precedence table.

**Re-check.** The order fix is one map entry and a real defect for a reader of a rendered `specs` document. The
`spec: {}` rendering has no path to a user: `validate` never renders, `merge` renders the existing node tree, and
`generate` writes `spec` only.

**Decision.** Order accepted (`TestRender_SpecsUseRuleOrder`); the presence machinery rejected as code without a
caller — noted here for the day a command renders a decoded document.

## Outcome

Thirteen claims. Cursor refuted five (C4, C5, C7, C9, C13) and volunteered the dual-stack finding under C8; Codex,
reading the head after Cursor's fixes, refuted C1, C2, C5, C6 and C9 and confirmed the rest, C8 and C13 among them.
Accepted and applied with failing-first tests: dual-stack world labels, the resolver derivation narrowed, profiles
and derived resolvers `ANY`, YAML document decoding, ObjectMeta / enum / nodeSelector / `specs` validation,
`serve` defaults and the chart's DNS values, the `specs` render order, the Renovate note. Rejected snippets: the
NodeLocal exclusion (the LRP backend is what the lookups reach), the build-info test (no `Deps` on the runner,
measured), the presence bit for `spec`, the Go-test duplicate of CI's dependency guard, the `go generate` CI step
(the `cmp` is the same check). Re-validated after the edits: `go vet`, the suite (the 14 goldens: 12 byte-identical
to 0.6.3, two regenerated for the DNS protocol with the reason recorded), `kubectl-validate` over the goldens, `helm
lint` and four `helm template` states, the built binary's `validate`, `version` and `serve` with the env defaults,
CI green on `70a9571` and `cc01b46`.

## Second pass, on `cc01b46`

The same two reviewers, a 12-claim brief: does each accepted fix close its hole without opening another (C1–C8),
and what the first pass did not name — `merge` with the new types, a clusterwide policy carrying a namespace, two
invocations in a row, the next real use (C9–C12). Cursor (no shell, verdicts from source) and Codex (shell, in its
own copy) — Codex's launch through the companion agent produced a `--help` job that completed at once; it was
relaunched directly (`codex exec … -m gpt-5.6-sol -c model_reasoning_effort=xhigh`, session `01a09c35`) with
stdin closed, since the first direct run blocked on "Reading additional input from stdin".

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 dual-stack labels everywhere | CONFIRMED (the two maps are the only comparators; later code compares the entity string) | CONFIRMED (a synthesised `reserved:world-ipv6` flow → `toCIDR …/128`) | — |
| C2 the four resolver shapes | CONFIRMED for the four — **and an attack that lands**: the official CoreDNS Helm chart labels `app.kubernetes.io/name: coredns` (`k8s-app: coredns` only as a cluster service), and `extractLabels` drops `k8s-app` beside the `app.kubernetes.io/*` labels, so `looksLikeDNS` (k8s-app only) never derived it and the kubernetes fallback selected none of its pods | REFUTED — the same CoreDNS Helm chart finding, measured through the parser; Kubespray `coredns_dual` (`k8s-app: kube-dns-secondary`) named as the shape that still needs `--dns-resolver` | **Accepted**: the resolver is recognised by whichever of `k8s-app`, `app.kubernetes.io/name`, `app` the parser kept, and the rule names that label; a fixture with the chart's labels, through the parser (`TestDeriveDNSResolver_HelmCoreDNSLabels`) — the first-pass tests injected `k8s-app` on aggregated flows and never went through `extractLabels`; Codex: **Accepted** (as Cursor); Codex's snippet is the code that was pushed |
| C3 the L7 rule wins over the plain rule | CONFIRMED from `pkg/policy/rule.go` (ANY expands to TCP/UDP/SCTP; an L4-only filter merges into the L7 filter on the same port; `ParserTypeNone` promotes to DNS) — the drop is readability, not correctness | CONFIRMED (`rule.go:395–406`, `l4.go:1072–1078`, `1271–1283`: the L7 filter absorbs the plain one; the drop is provenance, not correctness) | — (the cited merge read here: `rule.go:299–310`, `l4.go:457–461`) |
| C4 `Validate` and admission | CONFIRMED (a–e); `customresource/validator.go:46–54` runs `ValidateObjectMetaAccessor` plus the schema — `validate` has the first, CI's `kubectl-validate` the second | REFUTED: everything measured holds (13,536,000 bytes; the enum; 22 golden documents) but `apiVersion: cilium.io/v1` was accepted — `customresource/validator.go:115–128` refuses it | **Accepted**: `Validate` refuses a wrong apiVersion or kind on a decoded document (`3144152`) |
| C5 the document decoder | CONFIRMED (fail-fast on a syntax error is right for a validator) | CONFIRMED (fail-fast per file; no change) | — |
| C6 `serve` defaults and the chart | CONFIRMED (a, b); (c) **the trap is real**: `dns.resolver` set, `networkPolicy.enabled`, `dnsEgress` unset — an empty map is falsy — renders the kube-dns rule for a pod whose server names another resolver | REFUTED: the same chart trap, with the `fail` guard as the fix | **Accepted**: the template `fail`s in that state (measured: exit 1 with the message; the `dnsEgress` and no-policy states still render); Codex: **Accepted** (as Cursor) |
| C7 `specs` order | PLAUSIBLE | CONFIRMED | — |
| C8 the two regenerated goldens | PLAUSIBLE | CONFIRMED (the two diffs, `kubectl-validate` OK) | — (measured in the first pass: the protocol and the description only) |
| C9 `merge` with `specs` | REFUTED: a `specs`-only document is refused as "no metadata/spec" and the new rules go nowhere; snippet creates `spec` beside `specs`, seeding its selector from the generated policy | REFUTED: a `specs`-only document refused generically; snippet = an explicit refusal naming `specs` ("silently creating `spec` … is unsafe") | **Accepted on the fact, snippet rejected**: cf2cnp never writes `specs`, and a `spec` invented beside a user's `specs` with a selector the user did not write is a surprise, not a merge — the document is refused with a message that names `specs` and says what to do (`TestMergeDocument_SpecsOnlyIsRefusedByName`); Codex: **Accepted** — Codex and the applied fix agree; Cursor's create-a-spec snippet stays rejected |
| C10 a clusterwide policy with a namespace | REFUTED (my claim): `ValidateObjectMeta` with `requiresNamespace=false` **forbids** a namespace (`objectmeta.go:283–287`), as the API server does — `Validate` already refuses | REFUTED (my premise): `Validate` already refuses; the API server *clears* the namespace instead (`rest/create.go:111–123`, `rest/meta.go:59–62`) — keep the refusal, say why | — (no change; the brief's premise was wrong); Codex: **Accepted**: the refusal says Kubernetes discards it |
| C11 two invocations | CONFIRMED (overwrite; `appendUnique`; the UDP twin is not in the generated policy) | CONFIRMED (identical SHA-256 twice; `0 rule(s) added`) | — |
| C12 the next real use | CONFIRMED: drop-in for the policy-PR template (a file input) and the observer subchart; a 0.6.3 user changes nothing; regenerating an FQDN policy now writes `ANY` | REFUTED: the policy-PR template runs `cf2cnp merge … --l7` and `merge` had no `--l7` (`unknown flag`, exit 1) — latent since 0.6.3 | — ; the template's `CF2CNP_VERSION` (0.6.1) is bumped at release; Codex: **Accepted**: `merge --l7`; CI runs the template's two calls |

Fixes pushed as `051419a`; CI green (run 34777602591). Codex's second pass (on the `cc01b46` snapshot, in its own copy; it names a Kubespray dual-CoreDNS shape as what still needs `--dns-resolver`) found three more: a wrong `apiVersion` accepted, the clusterwide-namespace refusal without its reason, and `merge` without the `--l7` the PoC's policy-PR template passes — all three applied with tests as `3144152`, CI green. Its verdict before those: "do not release 0.7.0 unchanged"; after them every finding of both passes is closed or recorded.
