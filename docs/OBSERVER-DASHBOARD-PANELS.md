# The observer dashboard, panel by panel — what each one counts, where the data comes from, and why it looks the way it does

Written 2026-09-17 for *Cilium Flows – Hubble Observer* (Grafana dashboard 23862 as carried by the hubble-observer chart,
the fork's `develop`, provisioned by the lab under uid `hubble-observer-23862`). The operator's ask: *"some of the
panels have no data, measurement stats or gauge or the right comparisons … research them and the data sources behind
them … it needs to mean something, so maybe a little legend can be added below each"* — and, the same evening, *"flow
per source namespace have the same colours for different namespaces"*.

Everything below was read from the sources named (Cilium's flow API, the chart's templates, Grafana's documentation)
or measured on poc1 (the queries and the rendered colours), and each panel ends with what the redesign does about it.
The change itself is `demos/25-hubble-observer-loki/dashboard-design.py` applied to the fork's dashboard file.

## 1. The data source — one stream, one verdict, twenty-five fields

The dashboard reads **Loki**, not Hubble. What is in Loki is what the observer pod wrote to its stdout: the chart's
command is

```text
hubble observe flows --verdict DROPPED --not --drop-reason-desc 'UNSUPPORTED_L3_PROTOCOL' --follow --ip-translation
  --server hubble-relay.kube-system.svc.cluster.local:443 -o json --field-mask <25 fields>
```

(`helm/hubble-observer/templates/deployment.yaml:36`; `verdictFilter: DROPPED` is the chart default,
`values.yaml:16`, with `none` to disable the filter). Three consequences shape every panel:

1. **Every line is a dropped flow.** "Total Flows" is the number of drops; "Flows per Verdict" is 100 % DROPPED by
   construction; the histogram is a drop-rate chart. Nothing on this dashboard measures traffic that got through.
2. **Only the masked fields exist.** The lab's `fieldMask` (`values-hubble-observer.yaml:21`, twenty-five fields, −27 %
   bytes per flow measured in demo 25 Part 9) keeps `time, uuid, verdict, drop_reason, drop_reason_desc,
   traffic_direction, node_name, Type, Summary, IP, l4, l7, source.{namespace,pod_name,labels,identity,cluster_name},
   destination.{…}, destination_names, egress_denied_by, ingress_denied_by` — chosen as the smallest set that still
   feeds every panel. A panel that needs a field outside the mask can never fill.
3. **Loki's `json` parser flattens objects and skips arrays.** `flow.destination_names[0]` and
   `flow.egress_denied_by[0].name` are reached with the JSON-path form (`| json x="flow.destination_names[0]"`), which
   is why two panels carry their own `| json` after `$logparser` (demo 25 Part 7c).

## 2. What the fields mean — from `api/v1/flow/flow.proto` at v1.20.2

| Field | Definition (quoted from the proto) | What it means on this dashboard |
|---|---|---|
| `verdict` | `FORWARDED` "the trace point has forwarded this packet"; `DROPPED` "the connection or packet has been dropped (e.g. … rejected by a network policy). The exact drop reason may be found in drop_reason_desc"; `AUDIT` "flows that would have been dropped by policy if audit mode was turned off"; `REDIRECTED` "redirected to the proxy"; `ERROR`, `TRACED`, `TRANSLATED` | with the default filter only DROPPED arrives; AUDIT is the interesting second value for the "observe first, then enforce" workflow of demos 26–35 |
| `traffic_direction` | `INGRESS = 1; EGRESS = 2` — the direction of the flow at the point where Cilium observed it | for a drop: **EGRESS** = dropped as it left the source endpoint (the source's egress policy, or default-deny egress); **INGRESS** = dropped as it arrived at the destination endpoint (the destination's ingress policy). It says whose policy decided. Demo 26's default-deny-ingress lab is 100 % INGRESS; demo 31's `pos` FQDN drops are EGRESS |
| `drop_reason_desc` | "only applicable to Verdict = DROPPED"; `POLICY_DENIED = 133`, `STALE_OR_UNROUTABLE_IP = 151`, `UNSUPPORTED_L3_PROTOCOL = 139`, `CT_*` … | `POLICY_DENIED` is the datapath's "no rule allowed this" (default deny); `POLICY_DENY` an explicit deny rule; `STALE_OR_UNROUTABLE_IP` a destination that no longer exists — measured today: 11 drops between 22:34:11 and 22:35:20 UTC, `poc2`'s edge Prometheus → `10.20.0.109:9962`, the **clustermesh-apiserver pod the 1.20.2 rollout replaced at 22:33:41**; the scraper kept the old pod IP for ~90 s until discovery caught up (the 9962 port and the start time from `kubectl get pods -A -o json` on poc2); `UNSUPPORTED_L3_PROTOCOL` is filtered out by the observer's command (IPv6 RS/RA noise) |
| `destination_names` | "all names the destination IP can have" | filled by Cilium's **DNS proxy**: only when the source is under an L7 DNS rule (`rules: dns:`) does Cilium see the lookup and remember name → IP for that endpoint. Without such a policy on the dropped sources the field is absent and *Flows per Destination* is empty — which is what the lab showed until today |
| `egress_denied_by` / `ingress_denied_by` | "The CiliumNetworkPolicies denying the egress/ingress of the flow" (`repeated Policy`, with `name`, `kind`, `revision`, labels) | named only for an **explicit** deny rule. A default-deny drop is decided by the *absence* of an allow rule, so both arrays are `[]` — gotcha #82, measured in demo 26 (`ingress_denied_by: []` on every one of the lab's drops). The panel's `label_format` turns that into "default deny (no matching allow)" |
| `is_reply` | "this was a packet (L4) or message (L7) in the reply direction" | kept in the mask since PR #14 because cf2cnp refuses replies by it; not shown on any panel |
| `Type` / `Summary` | `FlowType` L3_L4 / L7; `Summary` deprecated | not on any panel; `Type` would separate datapath drops from proxy (L7) drops |

## 3. What Grafana says a panel type is for — and what the colours were doing

From the visualization guide: the pie chart is for data "that adds up to a total and you want to show the proportion
of each value compared to other slices, as well as to the whole"; bar charts are recommended for **categorical
comparisons**; the stat is "for big stats and optional sparkline"; the gauge shows "how far a single metric is from a
threshold" — which no panel here has (a drop count has no threshold that means anything without a baseline).

**The colour defect, measured.** Three pies (*Direction*, *Source Namespace*, *Destination*) ran an **instant** Loki
query with the pie's *All values* option, so Grafana received one table (label column, value column) and coloured
its rows; the other three (*Verdict*, *Drop Reason*, *Denying policy*) ran a **range** query with *Calculate*, one
series per label, and coloured per series. Read from the DOM on poc1 (Grafana 13.2.1):

| Panel | Series and colour as rendered |
|---|---|
| Flows per Source Namespace (instant, All values) | `cf2cnp-lab27` rgb(242,204,12) · `cf2cnp-lab30` **rgb(87,148,242)** · `shop-clients` **rgb(87,148,242)** · `cf2cnp-lab` rgb(115,191,105) — the two 28 % slices share a colour |
| Flows per Destination (instant, All values) | `example.com`, `example.org`, `www.cilium.io` **all** rgb(115,191,105) — three equal 33 % slices, one colour |
| the same panels with the range query and *Calculate* | four and three distinct colours (yellow, blue, orange, green; green, yellow, blue) |
| `palette-classic-by-name` on the instant shape | every slice the same colour — the name Grafana hashes is the field's, not the row's |

The same behaviour is reported by other users ([Grafana community: "Pie chart shows identical colors for different
labels"](https://community.grafana.com/t/pie-chart-shows-identitical-colors-for-different-labels/100320) — "coloring
appeared to be based on the count values rather than the distinct labels"; the by-name palette's pie behaviour is
[grafana/grafana#73275](https://github.com/grafana/grafana/issues/73275), closed as not planned). The fix is not a
workaround: it is making the three panels the same shape as the three that were right.

## 4. Panel by panel

The captions are Grafana **text panels** (markdown, transparent, three grid rows high) placed under each Statistics
panel — a `description` shows only on hover, and the operator asked for something a reader sees. Two things the first
attempt got wrong and the measurement caught: a caption whose HTML-comment marker shared the line with its text
rendered as raw markdown (CommonMark treats the line as an HTML block — the marker now sits on its own line), and a
bar gauge fed by a range query did not sort (`sortBy` orders rows inside one frame; a range query gives one frame per
series — the gauges run an instant query so the labels are rows of a single table).

| Panel | What it counts | Fills when / empty when | Was | Now |
|---|---|---|---|---|
| **Total Flows** | flow lines in the range after the filters | always, if the observer writes | stat, no context | stat + caption "Dropped flows … every panel here counts drops, not traffic"; description |
| **Flows per Verdict** | `sum by (flow_verdict)` | one slice with the default filter | pie, 100 % DROPPED, red by override | kept (upstream's panel; informative with `verdictFilter: none`); fixed semantic colours for every verdict; caption says why it is one colour |
| **Flows per Direction** | `sum by (flow_traffic_direction)` | INGRESS and/or EGRESS | pie, instant + All values (the colour defect) | pie, range + Calculate; INGRESS blue, EGRESS orange; caption "whose policy decided" |
| **Flows per Source Namespace** | `sum by (flow_source_namespace)`, `!=""` | any drop with a pod source | pie, instant + All values; four near-equal slices, two the same blue | **bar gauge**, `topk(10)`, sorted by the count (instant query, one table frame, `sortBy Value #A`), one muted colour — length carries the magnitude, a heat gradient would add an alarm the count does not justify; the count beside each name. A ranking, which is the question ("who is being denied") |
| **Flows per Destination** | `sum by (flow.destination_names[0])` | only DNS-proxied destinations | pie, empty on this lab until a DNS-visibility source was dropped | **bar gauge**, the same shape; caption names the condition (L7 DNS rule on the source) and how to get data (demo 31's `pos`: `wget https://example.org` → `DROPPED POLICY_DENIED pos → example.org:443`, measured) |
| **Flows per Drop Reason** | `sum by (drop_reason)` with the L7 fallback | always for drops | pie, range + Calculate, palette colours | kept; POLICY_DENIED red, POLICY_DENY dark-red, STALE_OR_UNROUTABLE_IP orange, `CT_*` purple, unknown grey; caption defines the three you will see |
| **Policy drops by denying policy** | `sum by (denied_by)` over POLICY_DEN(Y\|IED) | named for explicit denies; "default deny" otherwise | pie | kept; "default deny (no matching allow)" grey so a named policy stands out; caption quotes gotcha #82 |
| **Flows over time, by verdict** | drops per 30 s | always | bars | kept; verdict colours as the pie; caption on how to read a step |
| **Cilium Flows over Time** | one row per drop, with the cluster columns (fork PR #1) | always | table | description added |
| **Unique Cilium Flows** | rows deduplicated by pattern | always | table, collapsed | description added |
| **Raw Flows** | the JSON lines | always | logs, no title | title "Raw flow lines" and description |

What was **not** changed and why: no gauge anywhere (nothing here has a threshold — a drop count is only high or
low against a baseline the dashboard does not have; the *Policy Verdicts* companion dashboard from the `policy` metric
is where audited-vs-dropped ratios live); no percent-of-traffic panels (the stream has no FORWARDED flows to divide
by — that is a Hubble *metrics* question, answered by the chart's *Hubble / Network Policy* dashboards on
Prometheus); no "Flows per Type" panel yet (`flow.Type` L3_L4 vs L7 would separate datapath from proxy drops — a
candidate once the lab has L7 drops to show).

## 5. What to do to see data in each panel (the tests)

| Panel | The test on this lab | Measured |
|---|---|---|
| Destination by DNS name | from a pod under an L7 DNS rule, request a name the policy does not allow: `kubectl -n cf2cnp-lab exec pos -- wget -T6 -qO/dev/null https://example.org` (demo 31's `pos` has `rules: dns: matchPattern: "*"` and `toFQDNs: example.com:443` only) | 2026-09-17: 12 × `DROPPED POLICY_DENIED cf2cnp-lab/pos → example.org:443`, likewise `example.com:80` and `www.cilium.io:443`; the panel filled within 15 s |
| Denying policy, a *named* rule | an explicit `ingressDeny`/`egressDeny` rule (demo 15's cell baseline is a `CiliumClusterwideNetworkPolicy` deny) | `bank-cell-baseline 20` in demo 25 Part 7c |
| Verdict with more than one slice | `verdictFilter: none` (or `AUDIT`) on the observer — the second-release example in the fork streams `--type policy-verdict` | E8 example, demo 28 |
| Direction with both slices | an ingress default-deny (demo 26) and an egress FQDN drop (demo 31) in the same window | the capture of 2026-09-17 18:2x: INGRESS ≈ EGRESS, both present |

## 6. References

- Cilium `api/v1/flow/flow.proto` at v1.20.2 — `Verdict`, `TrafficDirection`, `DropReason`, `destination_names`,
  `egress_denied_by`, `is_reply` (quoted in §2).
- hubble-observer chart: `templates/deployment.yaml` (the `hubble observe` command), `values.yaml` (`verdictFilter`,
  `fieldMask`, `extraArgs`).
- Grafana docs: [Pie chart](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/pie-chart/)
  (when to use; *Calculate* vs *All values*), [Visualizations](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/)
  (stat, gauge, bar gauge, categorical data).
- [Grafana community — identical colours for different labels](https://community.grafana.com/t/pie-chart-shows-identitical-colors-for-different-labels/100320);
  [grafana/grafana#73275](https://github.com/grafana/grafana/issues/73275).
- This lab: demo 25 Parts 7c and 9 (the mask, the two extra pies), demo 26 Part 9 and gotcha #82 (`denied_by` empty on
  default deny), demo 31 (the DNS-visibility policy on `pos`), `docs/upstream/releases/hubble-observer-2.7.0.md`.
