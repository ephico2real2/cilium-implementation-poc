# Review — hubble-policy-verdicts 0.4.0: the verdict dashboard grows five sections

Adversarial pass, 2026-09-13, on a 9-claim brief for the chart's working tree that became 0.4.0
([hubble-policy-verdicts#2](https://github.com/ephico2real2/hubble-policy-verdicts/pull/2)): the 0.2.2 verdict panels
under a section header, then Flows, Drops, Connection health, DNS and HTTP — each a tile line, charts and ranked
lists — re-homed from Cilium's Hubble Network Overview and DNS Overview dashboards on this page's one namespace
filter (demo 29 Part 10, gotcha #90). Cursor (Grok 4.6 high fast, ask mode, no shell: it read the JSON and reasoned
through the PromQL with the label semantics the brief gave) and Codex (gpt-5.6-sol, xhigh, in a copy; it evaluated
synthetic PromQL cases and hashed section 1 against the 0.2.2 tag). The operator asked for this pass in one line
("a quick cursor or codex review of the new dashboards … validate the data point exist"); Tempo was parked the same
minute for lack of resources on the lab. Every verdict was re-checked here against a live Prometheus (three
namespaces, both sides of the filter) and a live Grafana.

## Verdicts

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 the "missing" queries | REFUTED: replies matched by identity only (`source`/`destination` are Cilium identities, not pod names — a same-named workload elsewhere shares the match); the over-count with the namespace as destination unstated; `clamp_min` after a global sum hides it | REFUTED, and more: **PromQL subtraction drops a sender that has no reply series at all** — the worst case, every reply missing, rendered as a green 0; clamp per sender, not after the sum | **Accepted from both**: replies joined on identity AND namespace, zero-filled per sender (`… or on (source, source_namespace) 0 * sent`), clamped per sender, summed on the tile; the under-count written on the panels |
| C2 the role variable everywhere | CONFIRMED; volunteered: CI banned only one literal label | REFUTED on `allValue: ".*"` — it also matches the empty namespace Cilium keeps on host/world peers, so "All" was not "all namespaces" | **Accepted**: `.+`; both literals banned outside DNS; the role matcher required positively |
| C3 double counting | CONFIRMED (HTTP `reporter="server"`); flows **do** count once per node that saw them | same, with the citation | **Accepted**: "Flow events in range", the description says it is not a unique-flow count |
| C4 section 1 unchanged from 0.2.2 | PLAUSIBLE (no git) | CONFIRMED: targets, options, fieldConfig hashed identical; y +1 on all eight | — (measured here too: only `gridPos.y` differs) |
| C5 the ranked tables | CONFIRMED (an empty workload label is a blank cell) | CONFIRMED | — |
| C6 the tiles | REFUTED: latency tiles with 3 decimals hide sub-millisecond values | REFUTED: an extrapolated `increase` of 0.4 showed as a green 0 | **Accepted**: the nine alert tiles colour from 1e-9 with one decimal; the latency tiles let Grafana scale seconds and read 0 with no requests. **Rejected**: `noValue: "N/A"` — an absent counter over the range is zero events, and restyling "Dropped by policy" would break C4 |
| C7 the Loki row | PLAUSIBLE (field names by Loki's `json` flattening) | PLAUSIBLE | — (measured here: 1,694 / 1,544 lines for `cf2cnp-lab` as source / destination in the hour, `shop-core` 1,254 as destination) |
| C8 the layout | REFUTED as a uniform rule (section 1 keeps its 0.2.2 heights; section 4 has no lists) — the meaningful invariants given | same | **Accepted**: four tiles per section by position, h4 w6 for the new tiles, unique ids, a 2-D overlap check, sections in visual order |
| C9 what CI catches | REFUTED: order by array not by y; total 24 tiles not four per section | REFUTED, with a mutation table (visual reorder, Loki overlap, a moved tile: all missed) | **Accepted**: `hack/check-dashboard.py` holds the contract; CI runs it on both renders |

## Measured here

| What | Result |
|---|---|
| every 0.4.0 query against Prometheus, `cf2cnp-lab` as source, `shop-core` and `bank` as destination | 0 failures; `cf2cnp-lab`: SYNs 0.98/s, SYN-ACKs back 0.43/s, missing per sender `pos` 0.43/s and `stranger` 0.11/s (its dropped attempts); `bank`: six senders listed incl. `reserved:ingress` |
| the zero-fill, on the lab | before: a sender with no reply series absent from "missing"; after: `stranger` present |
| Loki, the hubble-observer stream, last hour | `cf2cnp-lab` 1,694 as source / 1,544 as destination; `shop-core` 0 / 1,254 |
| Tempo | 0 traces in 24 h (the only traced workloads, petclinic, are scaled to zero) — parked |
| Grafana, the preview ConfigMap (its own uid), `cf2cnp-lab` source and `bank` destination | 45 panels each, 0 "No data", 0 error panels, no `kubecon` on the page |
| Prometheus during the captures | restarting under liveness failures whenever a review job or the six petclinic JVMs loaded the workers (18 restarts by the end); the captures were retaken on a quiet cluster |

## Outcome

Nine claims, five refuted by both reviewers on the same points (the reply matching, the tiles, the layout claim,
the CI contract) and one each on top (Cursor: the latency decimals; Codex: the dropped sender, the `.*` All).
Every accepted fix has an assert in the chart's contract script. Rejected: `N/A` on empty tiles and a restyle of
section 1. Released as 0.4.0; the observer fork pins it beside cf2cnp 0.7.0.
