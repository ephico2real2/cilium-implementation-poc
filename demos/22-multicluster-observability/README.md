# Demo 22 — one Grafana for the mesh: poc2's metrics and traces into the central stack on poc1

> **Superseded in part by [demo 23](../23-collector-per-cluster/README.md):** the collector Service
> re-declared global with local affinity in Part 2, and Exercise 4's cross-cluster fallback, were
> measured to be the trap demo 23 records (seven backends, the wrong cluster stamp). The collector is
> a per-cluster service now. The rest of this demo — the hub's role-named global Services — stands.

## Summary context

Until here every dashboard's `cluster` dropdown offered one value. poc1 had the stack (demo 16),
Tempo (demo 21) and the collector (demo 10); poc2 had Cilium, half the bank and an OBI, and nothing
that collected anything. This demo makes poc2 a **spoke** of the observability **hub** on poc1, the
way the Cilium post *Multi-Cluster Kubernetes Explained* describes the hub-and-spoke topology: "a
central hub cluster acts as the core shared-services center … Instead of deploying operational
tooling in every spoke", and "With Cilium ClusterMesh, you can expose these specific shared services
from the Hub to the Spokes". The standard it follows, per signal:

| Signal | In every cluster (spoke) | Central (hub, poc1) | The wire |
|---|---|---|---|
| metrics | a **full** Prometheus: scrapes, keeps a short local copy, can answer and alert locally; `external_labels: cluster=<name>`; `remote_write` to the hub | Prometheus with the remote-write receiver (demo 21) — Thanos Receive / Mimir in production | a global Service, `prometheus-remote-write`, backends only on the hub |
| traces | an OTel collector per cluster: receives OTLP locally, stamps `k8s.cluster.name`, forwards | Tempo (demo 21) | a global Service, `tempo-central`, backends only on the hub |
| the join key | `cluster` on every metric, `k8s.cluster.name` on every span | every dashboard filters on it (demo 16 Part 9 stamped it) | — |

Everything below is recorded in [`output/transcript.txt`](output/transcript.txt); the captures are
in [`output/screenshots/`](output/screenshots/).

> **The rule this demo settled on (Part 2c).** Application HA across clusters is the *application's*
> declaration: its own Service carries `service.cilium.io/global: "true"` (and `affinity` / `shared`
> where the topology needs them) in every cluster — the bank has done that since demo 15, and the
> post's active-active and active-standby patterns are exactly those annotations. **Shared platform
> services are different:** they must be reachable from the spokes but must never pick up a spoke's
> look-alike as a backend. So they get a *role-named* Service of their own (`prometheus-remote-write`,
> `tempo-central`, not the chart's Service name), whose selector can only match the hub's pod, and the
> spoke installs its own copy under a **different release name** (`edge`). Same name in both clusters
> is the global-service contract; same *selector match* in both clusters is the trap (gotcha #69).

## Part 0 — memory

Six JVMs and a second Prometheus do not fit together on this VM: petclinic to zero, the bank back
up on both clusters (`demos/20-springboot/scale.sh up`). `VM available: 2530 MB` afterwards.

## Part 1 — a full Prometheus on poc2, writing to the hub across the mesh

[`values-prometheus-poc2.yaml`](values-prometheus-poc2.yaml): kube-prometheus-stack 90.1.1 with
`remoteWrite` to `http://prometheus-remote-write.monitoring.svc.cluster.local:9090/api/v1/write`,
`externalLabels: {cluster: poc2}`, 6 h local retention, the selector fix of gotcha #57, no Grafana and
no Alertmanager (central), node-exporter and kube-state-metrics on, the kind-specific components off.
[`10-remote-write-service.yaml`](10-remote-write-service.yaml) is the global Service, applied to both
clusters; [`20-tempo-central-service.yaml`](20-tempo-central-service.yaml) likewise for Tempo.

```bash
helm install edge prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --create-namespace --kube-context kind-poc2 -f demos/22-multicluster-observability/values-prometheus-poc2.yaml --wait
for c in poc1 poc2; do kubectl --context kind-$c apply -f demos/22-multicluster-observability/10-remote-write-service.yaml -f demos/22-multicluster-observability/20-tempo-central-service.yaml; done
```

```
  the two global Services as poc2 sees them (backends are poc1 pod IPs, 10.10.x)
poc1 Prometheus: what arrives with cluster=poc2 (by job)          ← 60 s after the install
  apiserver 1 · coredns 2 · kube-state-metrics 1 · kubelet 6 · node-exporter 2 · prometheus 2 · operator 1
poc2 Prometheus, locally: up series 15;  prometheus_remote_storage_samples_total 97792
```

## Part 2 — poc2's collector, and Cilium's metrics on poc2

[`30-otel-collector-poc2.yaml`](30-otel-collector-poc2.yaml): a collector Deployment in poc2 (OTLP
in, `k8s.cluster.name=poc2` inserted, `debug` + `otlp/tempo-central` out). Its Service is the demo 18
global `otel-collector` re-declared with `service.cilium.io/affinity: local`: poc2's OBI now has a
collector in its own cluster and uses it, falling back to poc1's only if it disappears — the demo 15
Failover B behaviour, applied to a platform service.

[`apply-poc2.sh`](apply-poc2.sh): the demo 16 Cilium metrics values with every `replacement: poc1`
rewritten to `poc2` (relabelings are lists; an overlay cannot change one element) plus
[`values-cilium-metrics-poc2-overrides.yaml`](values-cilium-metrics-poc2-overrides.yaml) (no
dashboard ConfigMaps: no Grafana here). One agent rollout on poc2 (`prometheus.enabled` adds a port,
the dynamic-metrics volume is new): six ServiceMonitors, and poc2's own Prometheus scraping all of
them within a minute (`cilium-agent ×2, cilium-envoy ×2, cilium-operator, clustermesh-apiserver ×3,
hubble ×2, hubble-relay` — all `up`).

### Part 2b — and then nothing new reached the hub: gotcha #69

Five minutes after Part 2, poc1 still had only the stack's poc2 jobs. poc2's Prometheus said why:

```
  samples_total 869506   failed_total 576000   shards 1
  level=ERROR msg="non-recoverable error" … err="server returned HTTP status 404 Not Found:
    remote write receiver needs to be enabled with --web.enable-remote-write-receiver"
```

A 404 from a Prometheus whose receiver is *off* — and the only such Prometheus was poc2's own. The
global Service in poc2 carried the same selector as in poc1, the operator's default labels
`app.kubernetes.io/name: prometheus, operator.prometheus.io/name: monitoring-kube-prometheus-prometheus`,
and poc2's first install used the same release name, `monitoring`. So in poc2 the "central" Service
had **two** backends, poc1's pod and poc2's own:

```
    32   10.21.38.20:9090/TCP   ClusterIP   1 => 10.10.4.97:9090/TCP  (poc1, receiver ON)
                                            2 => 10.20.1.232:9090/TCP (poc2, receiver OFF)
```

The remote-write client holds one connection; whichever backend it landed on after the Part 2 agent
restart, it kept. It landed on poc2. The first minute had worked because it had landed on poc1.

### Part 2c — the fix: a different release name on the spoke

Two ways to make the selector match only the hub: a label only the hub's pod carries (tried, works,
reverted — it is a workaround), or **install the spoke's stack under another release name**, so the
operator's own labels differ. poc2 was reinstalled as release **`edge`** (its Prometheus is
`prometheus-edge-kube-prometheus-stack-prometheus-0`, Service
`edge-kube-prometheus-stack-prometheus`), the central Service kept its poc1-named selector:

```
  poc2 Prometheus pod labels: operator.prometheus.io/name=edge-kube-prometheus-stack-prometheus
  backends of prometheus-remote-write as poc2 sees them:
    1 => 10.10.4.97:9090/TCP (active)                     ← poc1
    2 => 10.20.1.232:9090/TCP (terminating-not-serving)   ← the old poc2 pod, on its way out
  poc2 sender (release edge): non-recoverable errors in the last 3 min: 0
  poc1 receiver: apiserver 1 · cilium-agent 2 · cilium-envoy 2 · cilium-operator 1 · clustermesh-apiserver-metrics 3 ·
                 coredns 2 · edge-…-operator 1 · edge-…-prometheus 2 · hubble-metrics 2 · hubble-relay-metrics 1 ·
                 kube-state-metrics 1 · kubelet 12 · node-exporter 2
  newest up{cluster=poc2} sample: 1 s old
```

(The Cilium docs' `service.cilium.io/shared: "false"` would not have helped: it stops a cluster's
backends being *exported*, not being used locally. And `enableEndpointSliceSynchronization` is about
making remote backends visible to DNS and controllers — orthogonal to which backends a Service has.)

## Part 3 — the proof

**1. poc2, locally** — its own Prometheus (`edge`), through poc2's API server:

```
      3.504  accounts -> reserved:host        (no cluster label locally: external labels are added on the way out)
      1.706  payments -> reserved:host
      0.364  payments -> accounts
      0.298  accounts -> payments
```

**2. poc1, centrally** — the same query with `cluster="poc2"`: the same numbers, plus the label
(`3.514 accounts → reserved:host`, `0.3655 payments → accounts`, `0.2987 accounts → payments`, … and
`0.0949 postgres-standby → postgres`: replication, seen from the poc2 side).

**3. One query, both clusters** — the bank's HTTP by cluster and workload:

```
       0.07931  cluster=poc1 destination_workload=api
       0.07139  cluster=poc2 destination_workload=accounts
       0.03103  cluster=poc1 destination_workload=payments
       0.02816  cluster=poc2 destination_workload=payments
```

**4. Cilium itself, per cluster:** agents up 5 / 2; endpoints ready 63 / 25; ClusterMesh readiness
`cluster=poc1 target=poc2: 5`, `cluster=poc2 target=poc1: 2` — each side sees the other, from one panel.

**5. Tempo, centrally:** `k8s.cluster.name=poc1: 51 traces, poc2: 49` in the last 15 minutes; one
payment trace: `poc1/api 4 spans, poc1/payments 8, poc2/accounts 4`; poc2's collector log shows the
poc2-tagged batches leaving.

**6. Grafana:** the `cluster` dropdown offers `All, poc1, poc2`
([capture](output/screenshots/mc-cluster-dropdown.png)); Hubble Network Overview for `poc2` / `bank`
([capture](output/screenshots/mc-net-poc2-bank.png)); Hubble L7 for `poc2` / `accounts` / `server`
with zero empty panels ([capture](output/screenshots/mc-l7-poc2-accounts.png)); Cilium Metrics for
`poc2` ([capture](output/screenshots/mc-cilium-poc2.png)). [`browser-check.js`](browser-check.js) retakes them.

## Part 4 — the gap closed: `cluster=poc1` on the hub's own scrapes

**The symptom, on the dashboard the stack ships:** *Kubernetes / Compute Resources / Multi-Cluster*
listed two clusters — `poc2` by name, and a row with **no name** for poc1 ([before](output/screenshots/mc-multicluster-before.png)).
Every series poc1's Prometheus scraped itself (kubelet 15, node-exporter 5, apiserver 3, coredns 2,
kube-state-metrics 1, the stack's own components) had no `cluster` label; poc2's arrived labelled by
its `externalLabels`. The dashboard's recording rule, `cluster:node_cpu:ratio_rate5m`, therefore had
`cluster=(none)` and `cluster=poc2`.

**Why `externalLabels` cannot fix it:** they are attached on the way *out* (remote write, alerts,
federation), never to the local TSDB. Demo 16 Part 9 labelled the Cilium/Hubble monitors one by one
with `relabelings`; the stack has nine more jobs.

**The fix, one setting for all of them** — a *default scrape class* on the hub's `Prometheus`
object (prometheus-operator > v0.73; this stack runs v0.93.1): a relabeling "applied to all scrape
targets" of every ServiceMonitor, PodMonitor, Probe and ScrapeConfig that names no class.
Added to [`../16-monitoring/values-kube-prometheus-stack.yaml`](../16-monitoring/values-kube-prometheus-stack.yaml):

```yaml
prometheus:
  prometheusSpec:
    scrapeClasses:
      - name: cluster-label
        default: true
        relabelings:
          - {action: replace, targetLabel: cluster, replacement: poc1}
```

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 90.1.1 -n monitoring --kube-context kind-poc1 -f demos/16-monitoring/values-kube-prometheus-stack.yaml
```

Recorded (Part 4 of the transcript): `REVISION: 7`, the `Prometheus` object carrying the class;
75 s later `up` by cluster `poc1 54 · (none) 5 · poc2 32`, the five being pre-change series not yet
stale; after the 5-minute staleness window `active targets without a cluster label: 0 of 54`, `up`
by cluster `poc1 54 · poc2 32`, and the recording rule `cluster=poc1 0.525 · cluster=poc2 0.417`.
The dashboard now names both rows ([after](output/screenshots/mc-multicluster-after.png)); the
unnamed green line in its graphs is the pre-change history, and leaves the window with time.
[`browser-multicluster.js`](browser-multicluster.js) takes the captures.

Two things to know: the Cilium monitors of demo 16 set the same value themselves, so the two
relabelings agree (a scrape class is applied *before* the object's own relabelings, which could
override it); and the hub's Prometheus container was restarted once during this Part by a failed
liveness probe — VM load 146 with 1.3 GB free while Playwright and two clusters competed, the
gotcha #66 pattern, not the configuration (the StatefulSet generation did not change).

## Exercises

1. Break the join key: remove `externalLabels` from the poc2 values, upgrade, wait a minute. *Expect*
   poc2's series in poc1 without a `cluster` label, indistinguishable from poc1's own; the dashboards'
   dropdown loses `poc2`. Put it back.
2. Reproduce gotcha #69: install a second stack on poc2 as release `monitoring` (any small values),
   watch `prometheus-remote-write`'s backends in poc2 gain a local entry and the sender's
   `samples_failed_total` climb. Uninstall it.
3. Cut the mesh for the hub Service only: scale poc1's Prometheus to 0. *Expect* poc2 buffering
   (`prometheus_remote_storage_samples_pending` rising, retries in the log — recoverable 5xx/timeouts,
   unlike #69's 4xx) and full catch-up when it returns, within the WAL's 2-hour window.
4. `affinity: local` on the collector: delete poc2's collector Deployment, run the bank, search Tempo
   for `k8s.cluster.name="poc2"`: *expect* traces still arriving — through poc1's collector, the
   fallback. Re-apply.
5. Ask the hub what the spoke cannot: any `by (cluster)` query above. Then ask the spoke what the hub
   cannot: the same query on `edge-kube-prometheus-stack-prometheus` after cutting the mesh — local
   observability survives the hub being gone.

## What to take away

- **Hub and spoke, and every cluster keeps a Prometheus.** Local queries and local alerting must not
  depend on the hub; the hub is for the view across clusters. A remote-write *agent* would also work
  (`prometheus.agentMode`) but gives up the local copy.
- **`cluster` is the join key; stamp it at the source** (`external_labels`; the collector's
  `resource` processor) — never rely on the hub to know where a sample came from.
- **Apps declare their own HA; platform services get role-named, non-colliding Services.**
  Global-service annotations belong on the application's Service (the bank); a shared service is
  reached through a Service whose name says its role and whose selector cannot match a spoke's
  look-alike — hence distinct release names per cluster (gotcha #69).
- **One gap, left visible:** `count by (cluster) (up)` on the hub returns a third bucket with *no*
  `cluster` label — poc1's own kubelet/apiserver/node-exporter series. `external_labels` are added
  only on the way out (remote write, alerts), never to locally stored series, so the hub's own
  non-Cilium jobs are unlabelled; only the Cilium/Hubble ServiceMonitors were stamped in demo 16
  Part 9. In production the hub is a receiver only (Thanos/Mimir) and every cluster, the hub's
  included, is a spoke writing through it — which stamps everything. Here it would need a relabel on
  each of the stack's own jobs. **Closed in Part 4** below — one relabel for all of them.
- **The mesh did the networking.** No ingress, no LoadBalancer, no TLS termination for remote write
  or OTLP: pod-to-pod across clusters over the existing ClusterMesh path (demo 04 encrypts it if wanted).

Remove it:

```bash
helm uninstall edge -n monitoring --kube-context kind-poc2
kubectl --context kind-poc2 delete -f demos/22-multicluster-observability/30-otel-collector-poc2.yaml
for c in poc1 poc2; do kubectl --context kind-$c delete -f demos/22-multicluster-observability/10-remote-write-service.yaml -f demos/22-multicluster-observability/20-tempo-central-service.yaml --ignore-not-found; done
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system --kube-context kind-poc2 -f .tmp/poc2-values-before-demo22.yaml   # Cilium metrics off again on poc2
```
