# Enhancement 001 — policy from observed flows, enterprise-ready

Tracking issue [#11](https://github.com/ephico2real2/cilium-implementation-poc/issues/11); one issue per item
([#1](https://github.com/ephico2real2/cilium-implementation-poc/issues/1)–[#10](https://github.com/ephico2real2/cilium-implementation-poc/issues/10)).
Status: **reviewed, both passes** — [`docs/REVIEW_ENH-001.md`](../docs/REVIEW_ENH-001.md): Cursor refuted seven,
Codex ten; every accepted fix is on its branch with a test. Nothing is merged yet; the merge order is in the
branches table. One branch per issue in the fork it changes: `enh/E<n>-<slug>` on
[ephico2real2/cf2cnp](https://github.com/ephico2real2/cf2cnp),
[ephico2real2/hubble-observer](https://github.com/ephico2real2/hubble-observer),
[ephico2real2/hubble-policy-verdicts](https://github.com/ephico2real2/hubble-policy-verdicts); the PoC carries the
demos and the workflow template.

**Released and proven (2026-09-13):** cf2cnp [`v0.6.0`](https://github.com/ephico2real2/cf2cnp/releases/tag/v0.6.0) and [`v0.6.1`](https://github.com/ephico2real2/cf2cnp/releases/tag/v0.6.1), hubble-policy-verdicts 0.2.0, the observer fork `develop` (`7853c77`) — demos [29](../demos/29-cross-cluster-policy/README.md) (E1, E9), [30](../demos/30-l7-rules/README.md) (E2), [31](../demos/31-dns-visibility/README.md) (E3), [32](../demos/32-operator-loop/README.md) (E4, E5, E10), [33](../demos/33-hardening/README.md) (E6), [34](../demos/34-verdict-to-policy/README.md) (E7, E8). What the demos found that the two review passes could not (each fixed and recorded): the merge re-serialised the file (0.6.1), the kube-dns rule twice (0.6.1), the E10 archive name and the repository's PR setting (template), the observer chart's wider policy beside the subchart's (#88), one container name for two releases (#89).

## 0. What this is, and the rules it follows

Demos 26–28 built a working "policy from observed flows" loop on open-source parts: Hubble's flows and its
`policy` metric, cf2cnp (forked, 0.5.1), the hubble-observer chart, Loki, Grafana, and the Policy Verdicts
dashboard (its own chart since demo 28). Ten gaps were measured on the way. This plan turns them into an
enterprise-ready toolchain — one where a platform team can hand the loop to application teams across a
ClusterMesh and trust what comes out.

Rules for every item:

- **No redesign.** Each change extends the code as it is (the fork's `internal/{flow,aggregator,policy,server}`
  packages, the two charts). A fix is allowed where the existing code would otherwise carry a known debt.
- **Readable by a mid-level engineer.** One concept per function, a comment on *why*, a test that shows the
  behaviour with a real flow from the labs.
- **Off unless it changes the datapath's meaning.** New behaviour is opt-in (a flag, a query parameter, a
  value) — except E1, where the *absence* of the change produces a wrong policy on Cilium ≥ 1.19.
- **Every claim below names its source**: a demo transcript, a Cilium source file at v1.20.1, or the docs.

### The stack facts the plan rests on (measured or cited)

| Fact | Source |
|---|---|
| Cilium 1.20.1 on kind (poc1 3 CP + 2 W, poc2 1 CP + 1 W), ClusterMesh, Hubble relay on mTLS, Gateway API | demos 01–24 |
| Since Cilium 1.19, "policies automatically select endpoints from the **local cluster only**, unless one or multiple clusters are specifically targeted" with `io.cilium.k8s.policy.cluster`; "in Cilium v1.18 or lower, policies used to select endpoints from all clusters by default". The behaviour is the chart value `clustermesh.policyDefaultLocalCluster` (default `true` on 1.20.1); a cluster that sets it `false` is back on the ≤ 1.18 rule, and E1's label then narrows rather than enables | `Documentation/network/clustermesh/policy.rst` at v1.20.1, lines 49–56; the 1.20.1 chart README (review) |
| A cross-cluster flow carries the peer's cluster as a label: `k8s:io.cilium.k8s.policy.cluster=poc2` on the source of a `payments@poc2 → api@poc1` INGRESS flow, and `source.cluster_name` / `destination.cluster_name` | measured on the bank, 2026-09-13 (this plan's Part 1 record) |
| L7-visible flows carry `l7.type` (`REQUEST` / `RESPONSE`), `l7.http.method`, `l7.http.url` (a full URL), `l7.http.protocol`, `l7.http.code`, `l7.http.headers`; DNS flows carry `l7.dns.query` (with a trailing dot), `qtypes`, `ips`, `observation_source: proxy` | measured on the bank (demo 19's visibility rules), 2026-09-13 |
| `PortRuleHTTP{Path, Method, Host, Headers, HeaderMatches}`: Path and Method are "extended POSIX regex" matched against the request; empty = any | `pkg/policy/api/http.go` v1.20.1, lines 66–105 |
| "Layer 7 policies will proxy traffic through a node-local envoy instance … Layer 7 traffic targeted by policies will therefore depend on the availability of the Cilium agent pod" | `Documentation/security/policy/layer7.rst` v1.20.1, line 61 |
| `toFQDNs` needs the DNS proxy: "This requires Cilium to be configured with `--enable-l7-proxy=true` and an L7 policy allowing DNS requests (`rules.dns` YAML block)"; "The DNS Proxy is the only method to allow IPs from responses" | `Documentation/security/policy/layer3.rst` v1.20.1, lines 502–506 and `layer7.rst` 204–222 |
| Policy-verdict events are **5.6 %** of Hubble's events on a poc1 worker (223 of 4000 over 67.7 s: 3.3/s of 59/s); they carry `ingress_allowed_by` / `egress_allowed_by` with the policy's name and kind | measured 2026-09-13, `hubble observe --node-name poc1/poc1-worker2 --last 4000` |
| The Grafana action's request is `fetch: {method: POST, url: ${hubbleobservercf2cnpurl}/generate, headers: [["Content-Type","application/json"]], body: ${__data.fields.Line}}` | the 23862 dashboard JSON, `dashboard/cilium-hubble-flows.json` |
| kube-prometheus-stack's Grafana sidecar watches `NAMESPACE=ALL`, label `grafana_dashboard=1`, folder annotation `grafana_folder` | measured, demo 28 |
| Two objects of one kind in one namespace cannot share a name; a second `kubectl apply` replaces the first | Kubernetes docs (names) and demo 26 Part 14e (measured: `pos` dropped 20 s after the second apply) |

### Phasing

| Phase | Items | Why in this order |
|---|---|---|
| 1 — correctness on the mesh | E1 | A generated policy is *wrong* on 1.19+ ClusterMesh without it |
| 2 — what Hubble saw, all of it | E2, E3 | The policy says what the flows said (L7, names) |
| 3 — the operator's loop | E4, E5, E10 | Intent before generation, evolution instead of regeneration, a PR instead of a download |
| 4 — a shared service | E6 | Only once several teams use one endpoint |
| 5 — one dashboard | E7, E8, E9 | Verdict → policy in one place, which policy allowed it, proven across the mesh |

Each item ends with the demo that proves it (demos 29–34) with a recorded transcript and evidence, as demos
26–28 did.

---

## E1 — cluster-aware selectors for ClusterMesh flows (#1, cf2cnp)

**Measured.** A `payments@poc2 → api@poc1` INGRESS flow has, on its source, the label
`k8s:io.cilium.k8s.policy.cluster=poc2` and `source.cluster_name: poc2`. cf2cnp's `extractLabels` keeps only
the priority/fallback app labels, so the generated `fromEndpoints` names `app.kubernetes.io/name: payments`
and nothing about the cluster. On Cilium ≥ 1.19 that selector matches **the local cluster only**
(`clustermesh/policy.rst` 49–56): applied on poc1, it allows a local `payments` and **excludes the poc2 one the
flow came from**. Demo 19's gotcha #62 (400 drops on the mesh) is the same rule seen from the other side.

**Design.** Carry the peer's cluster into the peer selector when the two sides are in different clusters.
Same-cluster flows are untouched (no label, the local-only default is what is wanted). Not a flag: on 1.19+
the label is the only correct output for a cross-cluster flow; on ≤ 1.18 the label narrows an all-clusters
match to the observed cluster, which is also what the flow said.

**Code.**

`internal/flow/types.go` — the parsed flow remembers both clusters:

```go
type ParsedFlow struct {
 UUID            string
 Direction       string
 SourceNamespace string
 SourceLabels    map[string]string
 SourceCluster   string // flow.source.cluster_name — empty when Hubble did not set it
 SourceEntity    string
 IsSourceEntity  bool
 DestNamespace   string
 DestLabels      map[string]string
 DestCluster     string // flow.destination.cluster_name
 DestFQDNs       []string
 DestIP          string
 DestEntity      string
 Protocol        string
 Port            int
 IsWorldTraffic  bool
 IsDestEntityTraffic bool
 IsReply         bool
}
```

`internal/flow/parser.go`, in `parseFlow` after the labels:

```go
 // ClusterMesh: which cluster each side is in. Since Cilium 1.19 a selector without
 // io.cilium.k8s.policy.cluster matches the LOCAL cluster only, so a policy generated
 // from a cross-cluster flow must name the peer's cluster or it excludes that peer.
 parsed.SourceCluster = flow.Source.ClusterName
 parsed.DestCluster = flow.Destination.ClusterName
```

`internal/aggregator/aggregator.go` — the clusters are part of the identity of a peer, so two peers with the
same labels in two clusters become two rules:

```go
type AggregatedFlow struct {
 // … existing fields …
 SourceCluster string // ClusterMesh: the source's cluster (E1)
 DestCluster   string // ClusterMesh: the destination's cluster (E1)
}
```

In `AggregateFlows`, when creating the aggregated flow: `SourceCluster: f.SourceCluster, DestCluster: f.DestCluster`.
In `generateAggregationKey`:

```go
 parts = append(parts, f.SourceCluster) // after the source labels
 // …
 parts = append(parts, f.DestCluster)   // after the destination labels
```

and `parsedFlowFromAggregated` copies both fields.

`internal/policy/generator.go` — the peer selector:

```go
// ClusterLabel is the label Cilium puts on every endpoint of a ClusterMesh member and matches
// in fromEndpoints / toEndpoints (Documentation/network/clustermesh/policy.rst).
const ClusterLabel = "io.cilium.k8s.policy.cluster"

// crossCluster reports whether the flow's two sides are in different, known clusters.
func crossCluster(a, b string) bool { return a != "" && b != "" && a != b }
```

in `generateEndpointIngressRules`, after the namespace label:

```go
 if crossCluster(f.SourceCluster, f.DestCluster) {
  fromLabels[ClusterLabel] = f.SourceCluster
 }
```

in `generateEndpointEgressRules`, after the namespace label:

```go
 if crossCluster(f.SourceCluster, f.DestCluster) {
  toLabels[ClusterLabel] = f.DestCluster
 }
```

**Tests** (`internal/policy/generator_test.go`): a fixture from a measured bank request across the mesh,
`payments@poc2 → redis-0@poc1:6379` (`internal/testdata/egress-payments-poc2-to-redis-poc1.json`; the flows
from poc2 into poc1 that the relay showed as INGRESS were replies, recognisable by their ephemeral destination
ports — the request is an EGRESS flow, an ESTABLISHED-connection packet traced at `TO_ENDPOINT` on
`poc1/poc1-worker`, the destination's node; enforcement of the generated egress policy is at the source
endpoint on poc2, which is what makes the fixture right for E1): the egress policy for `payments` gets
`toEndpoints` with `io.cilium.k8s.policy.cluster: poc1`; single-cluster fixtures produce no cluster label
(byte-identical to before); two peers with equal labels in two clusters produce two rules.

**Demo 29.** The bank across the mesh (demo 15/19): audit mode on poc1's `api`, a default-deny, the
cross-cluster flow from `payments@poc2` collected and generated *with* and *without* E1 (0.5.1 for the
without), both applied in turn, `verify.sh` on both clusters: without → `payments@poc2 → api DROPPED`; with →
`FORWARDED by api`. That is the measurement the docs' sentence predicts.

**Risk.** A policy carrying a cluster label is rejected by nothing on a non-mesh cluster (the label simply
never matches), so E1 is safe where there is no mesh; the test for `cluster_name` empty keeps single-cluster
output byte-identical.

---

## E2 — L7 rules from L7-visible flows (#2, cf2cnp)

**Measured.** With demo 19's visibility rules, bank flows carry `l7.type: REQUEST`, `l7.http.method: POST`,
`l7.http.url: http://payments.bank.svc.cluster.local/payments`, and DNS flows `l7.dns.query:
accounts.bank.svc.cluster.local.` (trailing dot). cf2cnp's `Flow` type has no `l7` field, so all of it is
dropped and the rule is port-only.

**Cited.** `PortRuleHTTP.Path` and `.Method` are extended POSIX regexes; empty means any (`http.go` 66–105).
Cilium compiles them and hands them to Envoy as safe-regex matchers on `:path` and `:method`
(`pkg/envoy/policy/envoy_l7_rules_translator.go`); Envoy matches a safe regex against the **whole** header
value, and `:path` carries the query string — so the tool escapes the path and allows an optional query
(`^/payments(\?.*)?$`); the anchors are explicit rather than required (review finding).
"Layer 7 policies will proxy traffic through a node-local envoy instance … will therefore depend on the
availability of the Cilium agent pod" (`layer7.rst` 61). Demo 16 measured the same: an L7 rule is what puts a
port on the proxy.

**Design.** Opt-in (`--l7` in the CLI, `?l7=true` on the API, a checkbox on the page). Only `REQUEST`
L7 records are used (a `RESPONSE` is the reply side, exactly as `is_reply` is skipped today). HTTP: the rule
gets `http: [{method: "POST", path: "^/payments(\?.*)?$"}]` per distinct method + path — the path escaped
(`regexp.QuoteMeta`), an optional query allowed. DNS: `dns: [{matchName: "<query without the trailing dot>"}]`
per distinct query, **exactly as the resolver sent it**: an L7 DNS policy allows only the names it lists, and
the resolver tries its search-list expansions (`…svc.cluster.local.bank.svc.cluster.local`) before the real
name — strip them and lookups fail (both reviewers weighed in; the docs decided). L7 records are kept **per
port**: a port with them gets its own port rule with a `rules:` block, ports without stay together — an HTTP
rule seen on 8080 must not restrict 5432 of the same peer pair (review finding).

What it must say in the output (a comment, like the `toCIDR` one): the port now goes through the proxy; a TLS
port yields no L7 records (nothing was parsed, so no rule is produced — the port stays L4).

**Code.**

`internal/flow/types.go`:

```go
// L7 is Hubble's layer-7 record on a flow, present when a visibility or L7 policy put the port on the proxy.
type L7 struct {
 Type string   `json:"type"` // REQUEST or RESPONSE
 HTTP *L7HTTP  `json:"http,omitempty"`
 DNS  *L7DNS   `json:"dns,omitempty"`
}

type L7HTTP struct {
 Method   string `json:"method"`
 URL      string `json:"url"`
 Protocol string `json:"protocol"`
 Code     int    `json:"code,omitempty"`
}

type L7DNS struct {
 Query  string   `json:"query"`
 Qtypes []string `json:"qtypes,omitempty"`
}
```

and on `Flow`: `L7 *L7 \`json:"l7,omitempty"\``. On`ParsedFlow`:

```go
 HTTPMethod string // E2: from l7.http.method, REQUEST records only
 HTTPPath   string // E2: the path of l7.http.url
 DNSQuery   string // E2: from l7.dns.query without the trailing dot
```

`internal/flow/parser.go`, in `parseFlow`:

```go
 // Layer 7 (E2): only REQUEST records describe what the client asked for; a RESPONSE
 // is the reply side, skipped like is_reply. A request carries either http or dns.
 if flow.L7 != nil && flow.L7.Type == "REQUEST" {
  if flow.L7.HTTP != nil && flow.L7.HTTP.URL != "" {
   parsed.HTTPMethod = flow.L7.HTTP.Method
   if u, err := url.Parse(flow.L7.HTTP.URL); err == nil {
    parsed.HTTPPath = u.Path
   }
  }
  if flow.L7.DNS != nil {
   parsed.DNSQuery = strings.TrimSuffix(flow.L7.DNS.Query, ".")
  }
 }
```

`internal/aggregator/aggregator.go` — L7 records are collected per aggregated flow (they do not change the
key: same peers, same port, more detail):

```go
type HTTPRequest struct{ Method, Path string }

type AggregatedFlow struct {
 // … existing fields …
 HTTPRequests []HTTPRequest // E2: distinct method+path seen on this peer pair
 DNSQueries   []string      // E2: distinct names queried on this peer pair
}
```

In `AggregateFlows`, for both the new and the existing branch:

```go
func addL7(agg *AggregatedFlow, f *flow.ParsedFlow) {
 if f.HTTPMethod != "" || f.HTTPPath != "" {
  r := HTTPRequest{Method: f.HTTPMethod, Path: f.HTTPPath}
  if !containsRequest(agg.HTTPRequests, r) {
   agg.HTTPRequests = append(agg.HTTPRequests, r)
  }
 }
 if f.DNSQuery != "" && !containsString(agg.DNSQueries, f.DNSQuery) {
  agg.DNSQueries = append(agg.DNSQueries, f.DNSQuery)
 }
}
```

`internal/policy/types.go` — the HTTP rule type beside `DNSRules`:

```go
// L7Rules is the `rules:` block of a port rule: HTTP request rules and/or DNS rules.
type L7Rules struct {
 HTTP []HTTPRule `yaml:"http,omitempty"`
 DNS  []DNSRule  `yaml:"dns,omitempty"`
}

// HTTPRule: method and path are extended POSIX regexes (cilium pkg/policy/api/http.go)
type HTTPRule struct {
 Method string `yaml:"method,omitempty"`
 Path   string `yaml:"path,omitempty"`
}
```

`PortRule.Rules` changes type from `*DNSRules` to `*L7Rules` (the existing DNS rule in
`generateFQDNEgressRules` becomes `Rules: &L7Rules{DNS: […]}` — the rendered YAML is identical).

`internal/policy/generator.go` — the generator gets the option and applies it where port rules are built:

```go
type Generator struct {
 outputDir    string
 nameOverride string
 l7           bool // E2: emit HTTP/DNS rules from the flows' l7 records
}

// WithL7 makes the generator write layer-7 rules (HTTP method+path, DNS names) where the flows carry them.
// The port then goes through the node's Envoy proxy; the caller opted in.
func (g *Generator) WithL7() *Generator { g.l7 = true; return g }

// l7Rules builds the rules: block for one aggregated flow, or nil when there is nothing to say
func (g *Generator) l7Rules(f *aggregator.AggregatedFlow) *L7Rules {
 if !g.l7 || (len(f.HTTPRequests) == 0 && len(f.DNSQueries) == 0) {
  return nil
 }
 r := &L7Rules{}
 for _, req := range f.HTTPRequests {
  // the fields are regexes: anchor the path and escape it, or "/payments" also allows "/payments-admin"
  r.HTTP = append(r.HTTP, HTTPRule{Method: req.Method, Path: "^" + regexp.QuoteMeta(req.Path) + "$"})
 }
 for _, q := range f.DNSQueries {
  r.DNS = append(r.DNS, DNSRule{MatchName: q})
 }
 return r
}
```

and every `ToPorts: []PortRule{{Ports: convertPorts(f.Ports)}}` in the four endpoint/entity rule builders
becomes `[]PortRule{{Ports: convertPorts(f.Ports), Rules: g.l7Rules(f)}}`. The CLI flag `--l7` on
`generate` and the query parameter `l7=true` on `/generate` call `WithL7()`; the page gets a checkbox
"Layer 7 rules (puts the port on the proxy)" that adds the parameter.

**Tests.** Two fixtures from the bank: an HTTP `REQUEST` (`POST http://payments.bank.svc.cluster.local/payments`)
→ `rules.http: [{method: POST, path: ^/payments$}]`; a DNS `RESPONSE` → no rule (responses are skipped); a
DNS `REQUEST` → `rules.dns: [{matchName: accounts.bank.svc.cluster.local}]`; without `WithL7()` the output is
byte-identical to today's. A path with a regex character (`/v1/items?x`) is escaped.

**Demo 30.** The bank under demo 19's policies: flows with L7 collected, generated with `--l7`, applied on
`api`; `hubble observe --type l7` shows the proxy's verdicts; `hubble_http_requests_total` on the dashboard.
A TLS port (the Gateway's 443) collected too: no L7 record, no rule, the port stays L4 — the caveat measured.

---

## E3 — a DNS-visibility companion rule when `destination_names` is absent (#3, cf2cnp)

**Measured.** Demo 26 Part 3: `pos → example.com:443` had no `destination_names`, so the policy was
`toCIDR: 104.20.23.154/32` — a CDN address that will change. **Cited.** Names come only from the DNS proxy,
and the proxy is enabled by an L7 DNS rule (`layer3.rst` 502–506, `layer7.rst` 204–222).

**Design.** Opt-in (`--dns-visibility`, `?dnsVisibility=true`, a checkbox). When a world flow has no names,
the CIDR rule is written as today *and* a second egress rule is added: the same DNS rule
`generateFQDNEgressRules` already writes (kube-dns, port 53 UDP, `rules.dns: [{matchPattern: "*"}]`), with a
comment: "names appear in the next flows once this applies; regenerate for a `toFQDNs` rule". The DNS rule is
an L7 rule: port 53 goes through the proxy (the same caveat as E2, stated in the comment).

**Code.** `internal/policy/generator.go`:

```go
// WithDNSVisibility adds the kube-dns L7 DNS rule to a world policy that has no names, so that the DNS
// proxy records them and the next generation can write toFQDNs instead of toCIDR.
func (g *Generator) WithDNSVisibility() *Generator { g.dnsVisibility = true; return g }

// dnsVisibilityRule is the egress rule that turns the DNS proxy on for the selected endpoints — the same
// rule every toFQDNs policy carries (generateFQDNEgressRules), factored out so both paths write one thing.
func dnsVisibilityRule() EgressRule {
 return EgressRule{
  ToEndpoints: []LabelSelector{{MatchLabels: map[string]string{flow.GetNamespaceLabel(): "kube-system", "k8s-app": "kube-dns"}}},
  ToPorts: []PortRule{{
   Ports: []Port{{Port: "53", Protocol: "UDP"}},
   Rules: &L7Rules{DNS: []DNSRule{{MatchPattern: "*"}}},
  }},
 }
}
```

`generateFQDNEgressRules` uses `dnsVisibilityRule()` for its second rule (behaviour unchanged);
`generateWorldEgressRules` becomes:

```go
 policy.Spec.Egress = []EgressRule{cidrRule}
 if g.dnsVisibility {
  policy.Spec.Egress = append(policy.Spec.Egress, dnsVisibilityRule())
 }
```

and `addToCIDRComment` gains a second sentence when the DNS rule is present ("# the DNS rule below makes
the proxy record names; regenerate once flows carry destination_names to get toFQDNs").

**Tests.** The demo 26 `egress-pos-to-world` fixture: without the option, one rule (unchanged bytes); with
it, two rules, the second equal to the FQDN path's DNS rule (compared as YAML).

**Demo 31.** Demo 26's lab: generate with `--dns-visibility`, apply, wait for the next `pos → example.com`
flow: `destination_names: [example.com]` now present (measured), regenerate → `toFQDNs: matchName:
example.com` with the DNS rule. The CIDR rule retired.

---

## E4 — review before generate: a peer checklist in the page, `exclude=` on the API (#4, cf2cnp)

**Measured.** Demo 27 Part 3: the intent ("stranger may call nothing") was applied as a `hubble observe --not
--from-pod` flag at collection time. Anyone who collected without it gets stranger's rule in the policy.

**Design.** The API accepts `exclude=<label>=<value>` (repeatable): a flow is dropped when its *peer* (the
source for INGRESS, the destination for EGRESS) carries that label with that value. The page parses the
peers it already summarises into a checklist (one row per distinct peer label set, with the flow count);
unchecked rows become `exclude=` parameters. `?name=` and `?l7=` stay as they are.

**Code.** `internal/server/server.go`:

```go
// excludeFlows drops flows whose peer carries any of the excluded label=value pairs. The peer is the
// side the rule would name: the source for an INGRESS flow, the destination for EGRESS.
func excludeFlows(flows []*flow.ParsedFlow, excludes []string) []*flow.ParsedFlow {
 if len(excludes) == 0 {
  return flows
 }
 kept := flows[:0]
 for _, f := range flows {
  peer := f.SourceLabels
  if f.Direction == "EGRESS" {
   peer = f.DestLabels
  }
  if !peerMatches(peer, excludes) {
   kept = append(kept, f)
  }
 }
 return kept
}

func peerMatches(labels map[string]string, excludes []string) bool {
 for _, ex := range excludes {
  kv := strings.SplitN(ex, "=", 2)
  if len(kv) == 2 && labels[kv[0]] == kv[1] {
   return true
  }
 }
 return false
}
```

in `handleGenerate`, after parsing: `parsedFlows = excludeFlows(parsedFlows, r.URL.Query()["exclude"])`, and
"No valid flows found" when nothing is left. The page: after `summarize()`, `renderPeers(flows)` builds the
checklist (`<label><input type=checkbox checked data-peer="app.kubernetes.io/name=stranger"> stranger (6 flows)</label>`),
and `generatePolicy()` appends `exclude=` for every unchecked box. The peer key is the same label the
policy would use (`app.kubernetes.io/name`, else `app`, `k8s-app`), so unchecking removes exactly that rule.

**Tests.** Server: the three demo-27 style flows with `?exclude=app.kubernetes.io%2Fname%3Dstranger` → the
stranger rule absent; two excludes; an exclude that matches nothing → unchanged; all excluded → 400.

**Demo 32** (with E5 and E10): the operator's loop end to end.

---

## E5 — `cf2cnp merge`: fold new flows into an existing policy, idempotently (#5, cf2cnp)

**Measured.** Demo 26 Part 14 merges flows *within one request*. A policy already applied (yesterday's
generation, or one written by hand with fields cf2cnp does not model — `ingressDeny`, `enableDefaultDeny`,
annotations) has no path to evolve except regeneration, which drops everything the generator does not know.

**Design.** A CLI subcommand, `cf2cnp merge --existing policy.yaml --input flows/ --output policy.yaml`,
and the same through the API with a multipart or a second body field — CLI first, API when a demo needs it.
The existing document is read **unstructured** (`map[string]interface{}` via `yaml.v3`), so every field
survives; the generated policy for the *same target* (namespace, name and endpointSelector equal —
otherwise the command refuses) contributes its `ingress` / `egress` entries; an entry already present
(canonical YAML equality, the same test `MergePolicies` uses) is not added twice. Output order: existing
entries first, new ones after. Running it twice is a no-op.

**Code.** `internal/policy/merge.go`:

```go
// MergeInto adds the generated policy's rules to an existing CiliumNetworkPolicy document without
// touching anything else in it. The document is handled as a generic map so fields this tool does not
// model (ingressDeny, enableDefaultDeny, annotations, …) survive untouched. It refuses to merge into a
// different target: same namespace, same name, same endpointSelector, or nothing happens.
func MergeInto(existing map[string]interface{}, generated *CiliumNetworkPolicy) (added int, err error) {
 meta, _ := existing["metadata"].(map[string]interface{})
 spec, _ := existing["spec"].(map[string]interface{})
 if meta == nil || spec == nil {
  return 0, errors.New("existing document has no metadata/spec")
 }
 if meta["name"] != generated.Metadata.Name || meta["namespace"] != generated.Metadata.Namespace {
  return 0, fmt.Errorf("target mismatch: existing %v/%v, generated %s/%s",
   meta["namespace"], meta["name"], generated.Metadata.Namespace, generated.Metadata.Name)
 }
 if mustYAML(spec["endpointSelector"]) != mustYAML(toGeneric(generated.Spec.EndpointSelector)) {
  return 0, errors.New("target mismatch: the endpointSelector differs")
 }
 for _, r := range generated.Spec.Ingress {
  if appendUnique(spec, "ingress", toGeneric(r)) {
   added++
  }
 }
 for _, r := range generated.Spec.Egress {
  if appendUnique(spec, "egress", toGeneric(r)) {
   added++
  }
 }
 return added, nil
}

// toGeneric round-trips a typed value through YAML so it compares and stores like the existing document
func toGeneric(v interface{}) interface{} {
 var out interface{}
 b, _ := yaml.Marshal(v)
 _ = yaml.Unmarshal(b, &out)
 return out
}

// appendUnique adds item to spec[key] (a list) unless an equal item is already there
func appendUnique(spec map[string]interface{}, key string, item interface{}) bool {
 list, _ := spec[key].([]interface{})
 want := mustYAML(item)
 for _, have := range list {
  if mustYAML(have) == want {
   return false
  }
 }
 spec[key] = append(list, item)
 return true
}
```

`cmd/cf2cnp/main.go` — the subcommand:

```go
 mergeCmd := &cobra.Command{
  Use:   "merge",
  Short: "Merge rules generated from flows into an existing CiliumNetworkPolicy file",
  Long: `Read flows (a file or a directory), generate the policy for their workload, and add its rules to
an existing CiliumNetworkPolicy YAML — keeping every field of the existing document, adding only rules
that are not already there. Running it twice changes nothing. The existing policy must be the same target
(namespace, name, endpointSelector); otherwise the command refuses.`,
  RunE: runMerge,
 }
 mergeCmd.Flags().StringVar(&existingFile, "existing", "", "Existing CiliumNetworkPolicy YAML (required)")
 mergeCmd.Flags().StringVarP(&inputDir, "input", "i", "", "Flow file or directory (required)")
 mergeCmd.Flags().StringVarP(&outputFile, "output", "o", "", "Where to write the merged policy (default: --existing, in place)")
 mergeCmd.Flags().BoolVar(&l7, "l7", false, "Emit layer-7 rules from the flows' l7 records")
 mergeCmd.MarkFlagRequired("existing"); mergeCmd.MarkFlagRequired("input")
```

```go
func runMerge(cmd *cobra.Command, args []string) error {
 existingBytes, err := os.ReadFile(existingFile)
 if err != nil {
  return err
 }
 var existing map[string]interface{}
 if err := yaml.Unmarshal(existingBytes, &existing); err != nil {
  return fmt.Errorf("existing policy: %w", err)
 }
 flows, err := readFlows(inputDir) // a file → ParseFlowsFromBytes; a directory → ParseFlowsFromDirectory
 if err != nil {
  return err
 }
 gen := policy.NewGenerator("")
 if l7 {
  gen = gen.WithL7()
 }
 policies, err := gen.BuildPolicies(aggregator.AggregateFlows(flows))
 if err != nil {
  return err
 }
 if len(policies) != 1 {
  return fmt.Errorf("the flows produce %d policies; merge takes exactly one target — filter the flows", len(policies))
 }
 added, err := policy.MergeInto(existing, policies[0])
 if err != nil {
  return err
 }
 out, err := yaml.Marshal(existing)
 if err != nil {
  return err
 }
 target := outputFile
 if target == "" {
  target = existingFile
 }
 if err := os.WriteFile(target, out, 0o644); err != nil {
  return err
 }
 fmt.Printf("%d rule(s) added → %s\n", added, target)
 return nil
}
```

**Tests** (`internal/policy/merge_test.go`): an existing document with `ingressDeny`, an annotation and one
ingress rule; merging the demo 27 flows adds the missing rule, keeps `ingressDeny` and the annotation,
returns `added == 1`; a second merge returns `0` and byte-identical output; a different name → error; a
different selector → error.

**Demo 32.** Demo 27's `shop-frontend` policy: a new peer appears (a second client), its flows merged into
the applied file, `kubectl diff` showing only the new rule, applied, `verify.sh` FORWARDED by the same policy
name. Then E10 turns the diff into a PR.

---

## E6 — hardening of a shared `/generate` (#6, cf2cnp + chart)

**Measured.** `/generate` accepts anything from anyone; CORS is `*`; 0.5.1 added the 8 MiB body cap and
server timeouts. Behind the PoC's Gateway the route is https-only but unauthenticated; the Grafana action
is a browser call carrying whatever the dashboard's `headers` list says (`[["Content-Type","application/json"]]`).

**Design.** Three layers, each optional:

1. **Allowed origins.** `--allowed-origins` (env `CF2CNP_ALLOWED_ORIGINS`, comma-separated; default `*` for
   compatibility). The CORS middleware echoes the request's `Origin` only when listed. The chart value
   `cors.allowedOrigins: []` (empty = `*`) renders the flag; the hubble-observer chart passes the Grafana URL.
2. **A bearer token.** `--auth-token` (env `CF2CNP_AUTH_TOKEN`, the chart's `auth.existingSecret`/`auth.token`):
   when set, `/generate` and `/download/*` require `Authorization: Bearer <token>`; `/health` and `/` do not.
   The page keeps the token in `sessionStorage` from an input field, never in the HTML. The Grafana action can
   carry it in its `headers` list — **which every viewer of the dashboard can read** in the dashboard JSON, so
   the token protects a machine path (CI, `cf2cnp merge` in a pipeline), not a browser path. Said in the README.
3. **A policy for the pod.** `networkPolicy.enabled` in the cf2cnp chart renders a `CiliumNetworkPolicy`
   selecting the cf2cnp pod: ingress from `reserved:ingress` (the Gateway's Envoy) and from the pods matching
   `networkPolicy.fromEndpoints` (default: the Grafana pod's labels), on the container port; egress to
   kube-dns only. The observer chart already does this for the observer (PR #9 made it correct).

For the browser path the enterprise answer is not a token in a dashboard: put cf2cnp behind the **same
identity-aware gateway as Grafana** (oauth2-proxy or the platform's SSO in front of the HTTPRoute), so the
Grafana session and the cf2cnp call are both the user's. Cilium's Gateway API in 1.20 has no built-in
authentication filter, so this is a deployment pattern, documented, not a chart value.

**Code.** `internal/server/server.go`:

```go
type Server struct {
 port           int
 externalURL    string
 allowedOrigins []string // E6: CORS allow-list; empty or ["*"] = any origin
 authToken      string   // E6: when set, /generate and /download need Authorization: Bearer <token>
 cache          map[string]*CachedPolicy
 mu             sync.RWMutex
}

func NewServer(port int, externalURL string, allowedOrigins []string, authToken string) *Server { … }

// corsMiddleware echoes the request's Origin when it is allowed (or any origin when the list is "*"),
// and answers preflight. Grafana's action is a cross-origin fetch from the Grafana origin.
func (s *Server) corsMiddleware(next http.HandlerFunc) http.HandlerFunc {
 return func(w http.ResponseWriter, r *http.Request) {
  if origin := s.allowedOrigin(r.Header.Get("Origin")); origin != "" {
   w.Header().Set("Access-Control-Allow-Origin", origin)
   w.Header().Set("Vary", "Origin")
  }
  w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With, Accept, X-Grafana-Action, X-Grafana-Device-Id, X-Grafana-Org-Id")
  w.Header().Set("Access-Control-Expose-Headers", "Content-Disposition")
  w.Header().Set("Access-Control-Max-Age", "86400")
  if r.Method == http.MethodOptions {
   w.WriteHeader(http.StatusOK)
   return
  }
  next(w, r)
 }
}

func (s *Server) allowedOrigin(origin string) string {
 if len(s.allowedOrigins) == 0 || (len(s.allowedOrigins) == 1 && s.allowedOrigins[0] == "*") {
  return "*"
 }
 for _, o := range s.allowedOrigins {
  if strings.EqualFold(o, origin) {
   return origin
  }
 }
 return ""
}

// requireToken wraps a handler with the bearer check when a token is configured. Constant-time compare.
func (s *Server) requireToken(next http.HandlerFunc) http.HandlerFunc {
 return func(w http.ResponseWriter, r *http.Request) {
  if s.authToken != "" {
   got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
   if subtle.ConstantTimeCompare([]byte(got), []byte(s.authToken)) != 1 {
    w.Header().Set("WWW-Authenticate", `Bearer realm="cf2cnp"`)
    http.Error(w, "Unauthorized", http.StatusUnauthorized)
    return
   }
  }
  next(w, r)
 }
}
```

`Start()` registers `s.corsMiddleware(s.requireToken(s.handleGenerate))` and the same for `/download/`.
`main.go` adds `--allowed-origins` and `--auth-token` (env fallbacks). Chart: `values.yaml` gains

```yaml
cors:
  allowedOrigins: []        # empty = any origin (the default today); e.g. [https://grafana.example.com]
auth:
  token: ""                 # a bearer token for /generate and /download; prefer existingSecret
  existingSecret: ""        # name of a Secret with key `token`
networkPolicy:
  enabled: false
  fromEndpoints:            # who may call cf2cnp besides the Gateway (reserved:ingress)
    - matchLabels: {app.kubernetes.io/name: grafana}
```

`templates/deployment.yaml` renders `--allowed-origins` and the env `CF2CNP_AUTH_TOKEN` from the Secret;
`templates/ciliumnetworkpolicy.yaml`:

```yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ include "cf2cnp.fullname" . }}
  labels: {{- include "cf2cnp.labels" . | nindent 4 }}
spec:
  endpointSelector:
    matchLabels: {{- include "cf2cnp.selectorLabels" . | nindent 6 }}
  ingress:
    - fromEntities: [ingress]                      # the Gateway's Envoy
      toPorts: [{ports: [{port: {{ .Values.containerPort | quote }}, protocol: TCP}]}]
    - fromEndpoints: {{- toYaml .Values.networkPolicy.fromEndpoints | nindent 8 }}
      toPorts: [{ports: [{port: {{ .Values.containerPort | quote }}, protocol: TCP}]}]
  egress:
    - toEndpoints:
        - matchLabels: {io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}
      toPorts: [{ports: [{port: "53", protocol: UDP}]}]
{{- end }}
```

**Tests.** Server: an `Origin` on the list is echoed with `Vary: Origin`, one off the list gets no
`Access-Control-Allow-Origin`; with a token, no header → 401 with `WWW-Authenticate`, wrong → 401, right →
200, `/health` open. Chart: renders with and without each value; the CNP validated by `kubectl apply
--dry-run=server` in the demo.

**Demo 33.** The PoC's cf2cnp with the CNP on (`reserved:ingress` + Grafana), the Grafana action still
working, a `curl` from a pod in `cf2cnp-lab` dropped (`hubble observe` shows the policy verdict), and the
token on the machine path (`cf2cnp merge` in the E10 workflow).

---

## E7 — verdict to policy in one dashboard (#7, hubble-policy-verdicts)

**Measured.** Two dashboards for one workflow: the verdicts (Prometheus) on ours, the dropped flows with the
cf2cnp actions on the 23862 one (Loki).

**Design.** An optional row at the bottom of the verdicts dashboard, rendered by the chart only when
`lokiRow.enabled: true`: a Loki-backed table of the namespace's dropped flows, the *Flow UUID* column carrying
the three actions the 23862 dashboard has (Generate, Download, Open) — the same `fetch` shape, the same
`${__data.fields.Line}` body — pointed at `lokiRow.cf2cnpURL`. The row's query uses the observer's stream
labels (`{namespace="hubble-observer",container="hubble-observer"}`) and the dashboard's `namespace` variable
for `flow_destination_namespace`. The chart assembles the JSON at render time so the base dashboard stays one
file:

`templates/_dashboard.tpl`:

```yaml
{{- define "hubble-policy-verdicts.dashboardJSON" -}}
{{- $d := .Files.Get "dashboards/hubble-policy-verdicts.json" | fromJson -}}
{{- if .Values.lokiRow.enabled -}}
  {{- $row := .Files.Get "dashboards/loki-row.json" | replace "__CF2CNP_URL__" .Values.lokiRow.cf2cnpURL | replace "__OBSERVER_NAMESPACE__" .Values.lokiRow.observerNamespace | fromJson -}}
  {{- $_ := set $d "panels" (concat $d.panels $row.panels) -}}
  {{- $_ := set $d.templating "list" (concat $d.templating.list $row.templating.list) -}}
{{- end -}}
{{- $d | toPrettyJson -}}
{{- end -}}
```

`dashboards/loki-row.json` holds a `DS_LOKI` datasource variable and the row + table panel (copied from the
23862 dashboard's table: its `transformations` from the `| json` fields, the `Flow UUID` field override with
`links` and `actions`). Values:

```yaml
lokiRow:
  enabled: false
  cf2cnpURL: https://cf2cnp.example.com    # the base URL the browser reaches cf2cnp at
  observerNamespace: hubble-observer        # the observer's stream label
```

Both templates (`configmap.yaml`, `grafanadashboard.yaml`) use `include "hubble-policy-verdicts.dashboardJSON" .`
instead of `.Files.Get`.

**Tests.** CI renders with the row off (JSON unchanged from the file) and on (one more row panel, one more
variable, the action URL substituted), both parsed back as JSON. The Playwright check from demo 26
(`grafana-generate.js`) against the new dashboard's table in the demo.

**Demo 34.** Demo 27's namespace: from `dropped none` in the table to a downloaded `shop-frontend` policy
without leaving the dashboard.

---

## E8 — which policy allowed it: a policy-verdict stream into Loki (#8, hubble-observer)

**Measured.** `hubble_policy_verdicts_total` has no policy name; policy-verdict events do
(`ingress_allowed_by: [{name: shop-frontend, kind: CiliumNetworkPolicy}]`), and they are **5.6 %** of events
(3.3/s of 59/s on a worker) — cheap where "all flows" (demo 25 Exercise 3, thousands per minute) was not.

**Design.** A second release of the hubble-observer chart in the same namespace, `hubble-observer-verdicts`,
with `verdictFilter: none` and `extraArgs: ["--type", "policy-verdict"]` (PR #11 added `extraArgs`), so the
pod streams exactly the policy-verdict events, every verdict. The demo 10 collector tails it like the first
(one more `filelog` include on the pod's log path, the same attributes), into the same Loki with
`container=hubble-observer-verdicts`. The dashboard gains, in the E7 Loki row, a "Which policy allowed it"
panel: `sum by (allowed_by) (count_over_time({container="hubble-observer-verdicts"} | json
allowed_by="flow.ingress_allowed_by[0].name" [$__range]))` (the array-index JSON path demo 25 measured for
`egress_denied_by`) and its egress twin.

**Code.** The PoC's values for the second release (`demos/25-hubble-observer-loki/values-hubble-observer-verdicts.yaml`):

```yaml
fullnameOverride: hubble-observer-verdicts
image: {repository: quay.io/cilium/cilium, tag: v1.20.1}      # as the first release (demo 25 Part 7d)
verdictFilter: none                                          # every verdict …
extraArgs: ["--type", "policy-verdict"]                      # … but only policy-verdict events (5.6 % of all)
fieldMask: [time, uuid, verdict, traffic_direction, source, destination, l4, ingress_allowed_by, egress_allowed_by, ingress_denied_by, egress_denied_by, event_type, node_name]
cf2cnp: {enabled: false}                                     # one cf2cnp is enough
grafanaDashboard: {enabled: false}
ciliumNetworkPolicy: {enabled: true}
```

and the collector's `filelog` receiver gets a second `include` glob for `*_hubble-observer-verdicts_*.log`
with `container: hubble-observer-verdicts` in the same `resource` block. **Measure first** in the demo: the
line rate into Loki for one hour against the first observer's, before the second release stays.

**Demo 34** (with E7): "allowed by `shop-frontend`: N", "denied by <none — default-deny>: M", beside the
verdict counts.

---

## E9 — the `cluster` variable proven with a cross-cluster verdict (#9, PoC demo)

**Measured.** Demo 22 delivers poc2's metrics to the hub Prometheus with `cluster=poc2`; the verdicts
dashboard has the variable; no demo has put a mesh verdict on it. Prerequisite: the `policy` dynamic metric
is on poc1 only (demo 26 Part 4a) — poc2's agents need the same values block.

**Design (demo 29, with E1).** Enable the `policy` metric on poc2 (`demos/16-monitoring/values-cilium-metrics.yaml`
applied to poc2 with `--reuse-values`, the same one-ConfigMap diff), put the audit-mode default-deny on the
bank's `payments` on **poc2**, drive `api@poc1 → payments@poc2` through the global service (demo 15), and
read the dashboard with `cluster=poc2`: `api → payments audit` then, with E1's policy applied, `forwarded
l3-l4`; with 0.5.1's policy (no cluster label), `dropped none` — the docs' local-only rule made visible.
`policy-metric.sh` gets a `CLUSTER=` variable for the same query.

---

## E10 — policy as code: a branch and a PR (#10, workflow template)

**Measured.** Demo 27 ends with a download. The enterprise loop ends with a reviewed change in the
repository the cluster is reconciled from.

**Design.** A GitHub Actions workflow template in this repository (`enhancements/templates/policy-pr.yml`),
to be copied into a policies repository: given a flows file (an artifact, or a path in the repo), it runs
`cf2cnp merge` against the policy file for that workload, and opens a pull request with the diff. cf2cnp
stays git-agnostic; the template is the integration.

```yaml
name: Policy from flows → pull request
on:
  workflow_dispatch:
    inputs:
      flows:    {description: "Path to a Hubble flows file (NDJSON) in this repository", required: true}
      policy:   {description: "Path to the policy file to evolve (created if missing)", required: true}
      l7:       {description: "Emit layer-7 rules", type: boolean, default: false}
permissions: {contents: write, pull-requests: write}
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install cf2cnp     # the draft — the template verifies the checksum and keeps the archive's own name (first-run notes below)
        run: |
          curl -sSL -o cf2cnp.tgz https://github.com/ephico2real2/cf2cnp/releases/download/v0.6.0/cf2cnp_linux_amd64.tar.gz
          tar -xzf cf2cnp.tgz && sudo install cf2cnp /usr/local/bin/cf2cnp
      - name: Merge the flows into the policy
        run: |
          if [ -f "${{ inputs.policy }}" ]; then
            cf2cnp merge --existing "${{ inputs.policy }}" --input "${{ inputs.flows }}" ${{ inputs.l7 && '--l7' || '' }}
          else
            mkdir -p "$(dirname "${{ inputs.policy }}")"
            cf2cnp generate --input "$(dirname "${{ inputs.flows }}")" --output "$(dirname "${{ inputs.policy }}")" ${{ inputs.l7 && '--l7' || '' }}
          fi
      - uses: actions/setup-go@v5
        with: {go-version: "1.24"}
      - name: Validate against the CRD schema (offline; --local-crds takes a directory)
        run: |
          mkdir -p .cilium-crds
          curl -sSL -o .cilium-crds/ciliumnetworkpolicies.yaml https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml
          go run sigs.k8s.io/kubectl-validate@v0.0.4 --local-crds .cilium-crds "${{ inputs.policy }}"
      - name: Open the pull request
        uses: peter-evans/create-pull-request@v7
        with:
          branch: policy/${{ github.run_id }}
          title: "policy: ${{ inputs.policy }} from ${{ inputs.flows }}"
          body: |
            Generated by cf2cnp merge from `${{ inputs.flows }}`. Review the rules against the intent; nothing is applied until this merges and the reconciler picks it up.
          commit-message: "policy: evolve ${{ inputs.policy }} from observed flows"
```

The binary release (`cf2cnp_linux_amd64.tar.gz`) is a new artefact: a `goreleaser`-free step in the fork's
release workflow that `go build`s for linux/amd64 and linux/arm64 and attaches the archives to the
`v*` release. `kubectl-validate` with the CNP CRD is the offline schema check (no cluster in the runner).

**Demo 32.** The demo 27 policy evolved by the workflow in a throwaway policies repository, the PR's diff
being exactly the new rule, merged, applied by `kubectl apply` in the demo (the reconciler's job elsewhere).

---

### E10 — first-run notes (demo 32, 2026-09-13)

The template, not the snippet above, is the reference (`enhancements/templates/policy-pr.yml`). Its first real run,
on a throwaway repository ([cilium-policies-lab](https://github.com/ephico2real2/cilium-policies-lab)), found three
things neither review pass could — none of them visible in a template read:

1. **The archive's name.** The reviewed install step saved the asset as `cf2cnp.tgz` and then ran `sha256sum -c`
   on a checksum line naming `cf2cnp_<version>_linux_amd64.tar.gz` — "No such file or directory". The template now
   keeps the asset's own name.
2. **The repository setting.** With `permissions: {contents: write, pull-requests: write}` the last step still failed:
   "GitHub Actions is not permitted to create or approve pull requests". The repository's Actions setting *Allow
   GitHub Actions to create and approve pull requests* must be on (or the step gets its own token). Noted in the
   template's header.
3. **The merge's layout.** cf2cnp 0.6.0's `merge` re-serialised the whole policy file (alphabetical keys, 4-space
   indentation), so the PR's diff was the whole file; 0.6.1 edits the YAML node tree and the diff is the added rule
   — the template pins 0.6.1.

The third run opened [PR #1](https://github.com/ephico2real2/cilium-policies-lab/pull/1): one rule added, validated
against the 1.20.1 CRD offline, nothing applied.

## The branches (one per issue, each with the code above applied and its tests green)

| Item | Repository | Branch | What it carries |
|---|---|---|---|
| E1 | ephico2real2/cf2cnp | [`enh/E1-cluster-aware-selectors`](https://github.com/ephico2real2/cf2cnp/tree/enh/E1-cluster-aware-selectors) | clusters on the parsed and aggregated flow, `ClusterLabel` on the peer selector, a fixture from a measured `payments@poc2 → redis-0@poc1:6379` request, three tests |
| E2 | ephico2real2/cf2cnp | [`enh/E2-l7-rules`](https://github.com/ephico2real2/cf2cnp/tree/enh/E2-l7-rules) | `L7` types, REQUEST-only parsing, per-peer HTTP/DNS collection, `WithL7`, `--l7` / `?l7=true` / checkbox, fixtures measured on the bank |
| E3 | ephico2real2/cf2cnp | [`enh/E3-dns-visibility`](https://github.com/ephico2real2/cf2cnp/tree/enh/E3-dns-visibility) | `WithDNSVisibility`, the factored `dnsVisibilityRule`, `--dns-visibility` / `?dnsVisibility=true` / checkbox, the comment, a test |
| E4 | ephico2real2/cf2cnp | [`enh/E4-exclude-peers`](https://github.com/ephico2real2/cf2cnp/tree/enh/E4-exclude-peers) | `?exclude=` on the API, the peer checklist on the page, tests including the EGRESS peer case |
| E5 | ephico2real2/cf2cnp | [`enh/E5-merge`](https://github.com/ephico2real2/cf2cnp/tree/enh/E5-merge) | `MergeInto` (unstructured, idempotent, target-checked), `cf2cnp merge`, README, tests with `ingressDeny` and an annotation surviving |
| E6 | ephico2real2/cf2cnp | [`enh/E6-hardening`](https://github.com/ephico2real2/cf2cnp/tree/enh/E6-hardening) | CORS allow-list, bearer token (constant-time, preflight and `/health` open), the page's token field, chart `cors` / `auth` / `networkPolicy` with a Secret and a CiliumNetworkPolicy, tests |
| E7 | ephico2real2/hubble-policy-verdicts | [`enh/E7-loki-row`](https://github.com/ephico2real2/hubble-policy-verdicts/tree/enh/E7-loki-row) | `lokiRow` assembled at render time, the table with the Generate/Download actions, CI parsing the JSON with and without the row (chart 0.2.0) |
| E8 | ephico2real2/hubble-observer | [`enh/E8-policy-verdict-stream`](https://github.com/ephico2real2/hubble-observer/tree/enh/E8-policy-verdict-stream) | `examples/values-policy-verdicts.yaml` (a second release, `--type policy-verdict`, the field mask) and the README's Loki query |
| E9 | this repository | demo 29 (with E1) | no code: the demo plan above |
| E10 | ephico2real2/cf2cnp and this repository | [`enh/E10-binary-release`](https://github.com/ephico2real2/cf2cnp/tree/enh/E10-binary-release), [`enhancements/templates/policy-pr.yml`](templates/policy-pr.yml) | the binary release workflow on `v*` tags; the policy-as-code workflow template |

Branches E2 and E3 both touch the port rule's `rules:` type (E2 renames `DNSRules` to `L7Rules`); E3 keeps
the old name so each branch stands alone, and the merge order is E1, E2, E3 (E3 rebased onto E2's type),
E4, E5, E6 — then a fork release 0.6.0 and the demos.

## Cross-cutting: what "enterprise-ready" adds around the code

- **Audit mode at scale.** Per-endpoint audit (`cilium-dbg endpoint config`) is a lab tool; the agent-wide
  `policy-audit-mode` flag is how a namespace is onboarded, with the dashboard's "workloads still audited"
  as the exit criterion. Written into demo 29's README; no code.
- **Baseline and cell.** Generated policies sit *under* a `CiliumClusterwideNetworkPolicy` baseline
  (demo 19: DNS, in-cell, kube-apiserver deny); cf2cnp never generates a baseline. Stated in E10's template
  README.
- **Naming and labels** are settled (0.5.0: name = f(selector); labels `app.kubernetes.io/managed-by=cf2cnp`
  plus the selector's identifying labels). E5 relies on the name to find the target.
- **Multi-tenancy.** Generation is namespaced by construction (a flow's namespaces name the policy's); an
  `exclude=` cannot cross namespaces. The API's token (E6) is one per deployment; per-team tokens are the
  gateway's job (the SSO pattern), not cf2cnp's.
- **Observability of the tool.** cf2cnp exposes no metrics; a `/metrics` endpoint with request and policy
  counters is a follow-up outside this plan (E11 candidate).

## Review claims (the brief for the Codex + Cursor pass)

The reviewers verify, with the artefact demanded for each: the ClusterMesh selector semantics on 1.20.1 (E1);
that `l7.http.url` always carries a path and how Cilium anchors `PortRuleHTTP.Path` (E2); that the DNS rule
written by E3 is exactly what `toFQDNs` needs (E3); the `exclude` semantics against the aggregation key (E4);
`MergeInto`'s equality and its behaviour on documents with `ingressDeny` (E5); the CORS echo and the
constant-time compare (E6); the Helm `fromJson`/`concat` assembly and Grafana 13's acceptance of the merged
JSON (E7); the observer's `--type policy-verdict` with `verdictFilter: none` and the collector include (E8);
the poc2 metric path (E9); `kubectl-validate` with the CNP CRD and `create-pull-request@v7` (E10). Every
refutation must come with the full corrected code and a test that fails before and passes after.
