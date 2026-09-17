# Hubble's L7 labels for Gateway traffic — why the "by Workload" dashboard goes blind, and the lab's answer

Written 2026-09-17 from the written sources and from measurements on the M5 lab (poc1/poc2, Cilium 1.20.1, Hubble
`httpV2` metrics, the Gateways of demo 37). Everything asserted here was measured that day or is quoted from the
document named beside it; nothing is recalled.

## 1. The symptom

During demo 37's load runs, Cilium's chart dashboard *Hubble L7 HTTP Metrics by Workload* read **No data** for
`team-a` and `team-b` while the hub Prometheus held 3,000–7,000 req/s for those namespaces
([demo 37 Part 6](../demos/37-two-gateways/README.md#part-6--the-noisy-neighbour-measured-does-a-teams-own-gateway-isolate-it),
gotcha #115). The dashboard is not broken; 29 of its 32 queries filter on `destination_workload`, and for that traffic
the label is empty.

## 2. The mechanism, measured

`hubble_http_requests_total` for Gateway traffic is reported by the Envoy on the **client's** node — the Gateway's
Envoy is per node, and an in-cluster client's connection to a Gateway VIP is served by its own node's Envoy (demo 37
Part 6, the first rig fault); for a client outside the cluster it is the node holding the VIP's L2 lease. Grouped by
every label, with the pods' placement from `kube_pod_info` at the same instants:

| time (2026-09-16) | backend pod | reporting Envoy (= the client's node) | `destination_workload` | `destination` | req/s |
|---|---|---|---|---|---|
| 14:57Z | `team-b/shop` @ worker | worker (the load pod) | **`shop`** | `shop` | 937 |
| 14:57Z | `team-a/probe` @ control plane | control plane (the probe pod) | **`probe`** | `probe` | 6 |
| 14:57Z | `team-a/shop` @ control plane | worker | *(empty)* | `shop` | 7,405 |
| 14:57Z | `team-b/probe` @ worker | control plane | *(empty)* | `probe` | 5 |
| 15:16Z | all four @ control plane | worker (both fortio pods) | *(empty)* on all | present on all | 7,214 / 5 / 5 |

On eleven series, `destination_workload` is present exactly when the backend pod is **local** to the reporting node,
and empty otherwise; `destination` — the `destinationContext` value, `app` first — is present on all of them. The lab
had met the same boundary before, for the source/destination contexts: demo 16 Part 9 measured "workload-name is known
only for endpoints local to the reporting agent, so every peer on another node (or the other cluster) rendered as
`-`", and put `app` first in every context for that reason
([`values-cilium-metrics.yaml`](../demos/16-monitoring/values-cilium-metrics.yaml), the comment above `content:`).
Gotcha #115 is the same fact reaching `labelsContext`.

Why the two labels differ: `app` is read from the pod's labels (`app.kubernetes.io/name`, `k8s-app`, or `app`), which
are part of the endpoint's security identity and so in every agent's ipcache for every peer; `workload` is the
Deployment/StatefulSet name from the pod's Kubernetes metadata, which the reporting agent has for its own endpoints.
Cilium added workload metadata to the ipcache for remote endpoints in
[cilium#27974](https://github.com/cilium/cilium/pull/27974) / [#28373](https://github.com/cilium/cilium/pull/28373); on
1.20.1, for Envoy-reported L7 flows to a remote backend, it does not arrive. That is the upstream report (§6).

## 3. The written basis for the fix

Cilium's metrics reference ([Monitoring & Metrics — Hubble metrics](https://docs.cilium.io/en/stable/observability/metrics/))
defines the levers:

- `labelsContext` — "a list of labels to be enabled on metrics … All labels listed are included in the metric, even if
  empty." Its values include `source_app` and `destination_app` beside `*_workload`, `*_pod`, `*_namespace`, `*_ip`,
  `*_workload_kind`, `traffic_direction`.
- `app` — "Kubernetes pod's app name from labels (`app.kubernetes.io/name`, `k8s-app`, or `app`)";
  `workload-name` — "Kubernetes pod's workload name (Deployment, Statefulset, Daemonset, etc.)".
- `sourceContext` / `destinationContext` take a `|`-list: "the first non-empty value is added to the metric as a label".
- `sourceIngressContext` / `destinationIngressContext` "take precedence over" the plain contexts for ingress traffic —
  **not** the lever here: the Gateway's traffic is reported as `traffic_direction=egress` from `source=reserved:ingress`.

Cilium's source at the lab's version confirms the label set the reference lists
([`pkg/hubble/metrics/api/context.go` @ v1.20.1](https://github.com/cilium/cilium/blob/v1.20.1/pkg/hubble/metrics/api/context.go),
line 59: `label ::= … | source_app | … | destination_app | traffic_direction`).

## 4. What the lab changed

1. **The metric** — `source_app` and `destination_app` added to `httpV2`'s `labelsContext`
   ([`values-cilium-metrics.yaml`](../demos/16-monitoring/values-cilium-metrics.yaml)); both clusters (`apply-poc2.sh`
   rewrites the same file with `cluster=poc2`).
2. **A restart, not a reload** — the dynamic metrics config **refuses a label-set change on a live metric**: after the
   `helm upgrade` the agents logged every 10 s
   `failed reading dynamic exporter config … metric config validation failed - label set cannot be changed without
   restarting Prometheus. metric: httpV2`, the DaemonSet reported "successfully rolled out" (only a ConfigMap changed, no
   pod restarted), and the exposed series kept the old labels. `kubectl -n kube-system rollout restart ds/cilium` on each
   cluster — with gotcha #42's cost: the Gateway was off the air ~45 s and both VIPs' L2 leases re-elected (both landed
   on the control plane).
3. **The dashboard** — the lab's copy of the chart's dashboard, keyed on the app labels:
   [`demos/37-two-gateways/l7-by-app-dashboard.py`](../demos/37-two-gateways/l7-by-app-dashboard.py) reads the chart's
   ConfigMap and rewrites every Hubble query's `destination_workload` → `destination_app` and `source_workload` →
   `source_app`, the two variables likewise, drops the two CPU panels (they join Hubble's *workload* name onto
   kube-state-metrics' `kube_pod_owner`; an app name is not a workload name — dropped rather than left silently wrong),
   and sets `allValue: ".*"` on the multi-value source variables. Provisioned beside Cilium's untouched original as
   *Hubble L7 HTTP Metrics by App (Gateway-aware)*, uid `hubble-l7-http-by-app`, by `lab-stack.sh`'s monitoring step
   (the demo 25 `dashboard-from-file.sh` way). Cilium's own dashboard stays the chart's.

   The `allValue` point is a second hole, in Cilium's dashboard too: Grafana's "All" on a multi-value variable is a
   regex of the *listed* values, and `label_values` never lists the empty string — the Gateway's traffic has
   `source_app=""` / `source_workload=""` (`reserved:ingress` has no app) and `source_namespace=""`, so every "by
   Source" panel dropped it. `.*` makes "All" mean all.

## 5. The alignment — does the dashboard say what the load generator says?

A fixed 500 qps through each door for 120 s, from the worker's fortio pods, both backends **remote** to the reporting
Envoy (the case that was blind):

| same 120 s window | team-a | team-b |
|---|---|---|
| fortio's achieved rate | 499 qps | 499 qps |
| the new dashboard's query, `sum by (destination_app)` | **499.9 req/s** | **499.94 req/s** |
| Cilium's dashboard's query, `sum by (destination_workload)` | **0** | **0** |
| fortio p50 / p99 | 0.61 / 1.38 ms | 0.61 / 1.48 ms |
| Hubble p50 / p99 (`destination_app="shop"`) | 2.50 / 4.95 ms | 2.50 / 4.95 ms |

Volume matches to a tenth of a request per second; the old query sees nothing. In the browser (Chromium, 300 qps per
door flowing): the app-keyed dashboard for `team-a` — 0 panels without data, *Incoming Request Volume* 193 req/s at the
ramp's edge and 500 at the previous run's peak, success 100 %, the by-source table `poc1 loadtest/: 200 — 500 max, 290
mean`; the workload-keyed original for the same namespace and moment — no request figures at all.

**The latency numbers are the histogram, not the path.** `hubble_http_request_duration_seconds_bucket` uses Prometheus'
default buckets — `0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5 10 +Inf` — so **5 ms is the first bucket**: any request
faster than that interpolates inside it (p50 → 2.5, p99 → 4.95, regardless of the true 0.6–1.5 ms). Below 5 ms the
dashboard's percentiles measure the bucket; fortio (client-side) and Envoy's own `envoy_cluster_upstream_rq_time`
histogram are the sources for that range, and demo 37 Part 6 reads them, not Hubble, for its latency claims.

## 6. What remains, and where

- **Upstream**: a report to cilium/cilium — 1.20.1, `httpV2` with `labelsContext` including `destination_workload`,
  Gateway API traffic, backend on another node than the reporting Envoy → the label empty; the same backend local →
  present; §2's table as the repro; #27974 as the mechanism that should cover it.
- **Cilium's chart dashboard**: the `allValue` hole in the source variables, and `destination_app` as a more robust
  key for ingress-style traffic — a candidate change for the chart's `hubble-l7-http-metrics-by-workload.json`, with
  this document as its evidence.
- **`Hubble Metrics and Monitoring`** (the chart's other dashboard): no `cluster` variable at all — since the spoke
  (demo 22) every panel sums poc1 and poc2. The multi-cluster convention every other Hubble dashboard follows
  (`external_labels.cluster`, a `cluster` variable from `label_values`, `cluster=~"$cluster"` in each query —
  [Grafana Cloud: multi-cluster](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/configuration/config-other-methods/helm-operator-migration/multi_cluster/))
  is the fix; a separate change.
- **The observer flow table** (the Loki dashboard, the hubble-observer fork): `flow.source.cluster_name` /
  `flow.destination.cluster_name` are parsed and used by its filters but not shown as columns; two columns, on the fork
  and in upstream PR #16.
