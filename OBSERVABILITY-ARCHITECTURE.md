# Observability architecture — what runs where, how the data moves, and why

Reviewed against the live clusters on 2026-09-12 (`kubectl get deploy,ds,sts` in every observability
namespace of both clusters, the Services carrying `service.cilium.io/*` annotations, and each
collector's pipeline configuration). Nothing here is assumed; the inventory is in the last section.

## The one picture

```
                         ┌──────────────────────────── poc1 = HUB (3 CP + 2 workers) ────────────────────────────┐
                         │                                                                                        │
                         │   Grafana ──reads──▶ Prometheus (2Gi)   Tempo (1Gi)   Loki (512Mi)      Hubble UI      │
                         │   :3000              :9090 + receiver   :4317/:3200   :3100/otlp        :80 → relay    │
                         │                         ▲    ▲   ▲        ▲    ▲        ▲                   ▲          │
                         │   scrape (54 targets) ──┘    │   │        │    │        │                   │ mTLS     │
                         │   Cilium/Hubble/kubelet/…    │   │        │    │        │            hubble-relay :443 │
                         │   + OBI :9464 (PodMonitor)   │   │        │    │        │            (7/7 nodes, mTLS) │
                         │                              │   │        │    │        │             ▲   ▲            │
                         │   Tempo metrics-generator ───┘   │        │    │        │             │   │            │
                         │   (service graph, span metrics)  │        │    │        │   hubble-observer (mTLS) ────┤
                         │                                  │        │    │        │   `hubble observe --verdict │
                         │                                  │        │    │        │    DROPPED --follow -o json`│
                         │   otel-collector DaemonSet (5) ──┼────────┘    │        │      stdout → /var/log/pods  │
                         │   ├ filelog: Hubble flow export → debug        │        │                 │            │
                         │   ├ otlp/zipkin: OBI + Spring Boot spans ───────┘        │                 │            │
                         │   └ filelog: the observer's pod log ───────────────────────────────────────┘            │
                         │        ▲                                                                                 │
                         │   OBI DaemonSet (eBPF) on bank + springboot                                              │
                         └────────┼──────────────────────────────────┬──────────────────────┬──────────────────────┘
                                  │ (local)                           │                      │
      ClusterMesh (global Services, one root CA, Hubble relay peers)  │ prometheus-remote-write :9090   tempo-central :4317
                                  │                                   │ (global Service, hub backends)  (global Service, hub backends)
                         ┌────────┼───────────────────────────────────┼──────────────────────┼──────────────────────┐
                         │        ▼                                   │                      │      poc2 = SPOKE    │
                         │   OBI DaemonSet (eBPF) on bank ──spans──▶ otel-collector Deployment ×2 (gateway,          │
                         │        │                                   persistent queue, k8s.cluster.name=poc2) ──────┘
                         │        └──metrics :9464──▶ Prometheus `edge` (768Mi, 6h, external_labels cluster=poc2) ───┘
                         │                            scrapes 32 targets: Cilium/Hubble/kubelet/… + OBI, and remote-writes ALL of it
                         │   hubble-relay :443 (mTLS) ◀── peered by poc1's relay across the mesh (no observer, no UI here)
                         │   NO Tempo, NO Loki, NO Grafana, NO flow export, NO observer — the hub does those
                         └────────────────────────────────────────────────────────────────────────────────────────────┘
                         ┌────────────────────────────────────────────────────────────────────────────────────────────┐
                         │   poc-N = the same spoke, verbatim: OBI, a gateway collector, a Prometheus under its own   │
                         │   release name with cluster=poc-N, its relay peered. Three things per cluster; the hub     │
                         │   grows by one `cluster` value in every dropdown.                                          │
                         └────────────────────────────────────────────────────────────────────────────────────────────┘
```

## The three signals, one at a time

### Metrics — pull locally, push to the hub

```
 poc1 (hub)                                             poc2 (spoke)                       poc-N
 ┌──────────────────────────────┐                       ┌──────────────────────────────┐   ┌───────────┐
 │ Prometheus `monitoring`      │                       │ Prometheus `edge`            │   │ `edge`    │
 │  scrapes: cilium-agent ×5,   │                       │  scrapes: cilium-agent ×2,   │   │ cluster=N │
 │  envoy, operator, hubble ×5, │   remote_write over   │  envoy, operator, hubble ×2, │   └─────┬─────┘
 │  clustermesh-apiserver ×3,   │◀──the mesh, through───│  clustermesh-apiserver ×3,   │         │
 │  kubelet, apiserver, coredns,│   the global Service  │  kubelet, apiserver, coredns,│         │
 │  node-exporter, ksm, OBI     │   prometheus-remote-  │  node-exporter, ksm, OBI     │◀────────┘
 │  = 54 targets, cluster=poc1  │   write (hub backends │  = 32 targets, external_label│
 │  (default scrape class)      │   only)               │  cluster=poc2, 6 h retention │
 │ + receives: poc2 (32), Tempo │                       │  answers local queries and   │
 │   metrics-generator          │                       │  alerts by itself            │
 │ 262k head series, 797 MB RSS │                       │ 69k head series, 702 MB RSS  │
 └──────────────────────────────┘                       └──────────────────────────────┘
```

*Why a full Prometheus per spoke, not an agent:* local queries and alerting survive the hub or the
mesh being down (demo 22). *Why the hub's memory is not the single-cluster budget:* it holds every
spoke's series too — 1Gi OOM-killed it 51 times (demo 22 Part 5); 2Gi now, and a 30-minute
out-of-order window so a spoke's backlog after a hub outage is accepted, not rejected with 400.
*Why the spoke's release name differs (`edge`):* a global Service with the same selector in both
clusters would have made poc2 write to itself (gotcha #69).

### Traces — instrument everywhere, one collector per cluster, one Tempo

This is the part that reads as "poc2 only" in the demo files, and is not. The **components** are
symmetric; only the **manifests** live in different demos because the clusters were built in order:

```
 poc1 (hub)                                                   poc2 (spoke)
 ┌───────────────────────────────────────┐                     ┌────────────────────────────────────────┐
 │ OBI DaemonSet ─── demos/18-obi ───────┼─── same file ──────▶│ OBI DaemonSet                          │
 │  eBPF, no code change, bank (+spring) │                     │  eBPF, bank                            │
 │  stamps k8s.cluster.name=poc1         │                     │  stamps k8s.cluster.name=poc2          │
 │       │ OTLP/http :4318               │                     │       │ OTLP/http :4318                │
 │       ▼                               │                     │       ▼                                │
 │ otel-collector DaemonSet              │                     │ otel-collector Deployment ×2           │
 │  demos/10-tracing (a DaemonSet because│                     │  demos/23 (a Deployment: no flow files │
 │  it ALSO tails Hubble's per-node flow │                     │  to tail here), PDB, persistent queue, │
 │  export files) — traces pipeline:     │                     │  inserts k8s.cluster.name=poc2 on any  │
 │  otlp+zipkin → otlp/tempo (local)     │                     │  span without it                       │
 │       │                               │                     │       │ otlp/tempo-central              │
 │       ▼                               │                     │       │ (global Service → hub Tempo)    │
 │ Tempo ◀───────────────────────────────┼─────────────────────┼───────┘                                │
 │  demos/21: traces of BOTH clusters;   │                     │ (no Tempo here — the hub stores)       │
 │  metrics-generator → Prometheus;      │                     └────────────────────────────────────────┘
 │  Grafana: service graph, drilldown    │
 └───────────────────────────────────────┘
 a payment = one trace: web/api (poc1) → payments (poc1 or poc2) → accounts (poc2): spans from BOTH
 collectors, joined by the W3C traceparent OBI propagates at the network layer.
```

*Why a collector per cluster and never a global Service for it (demo 23):* the gateway stamps the
cluster identity and buffers on disk when the hub is down; global merging put poc2's gateway behind
poc1's collector address (seven backends, wrong cluster stamp). *Why the services `otel-collector`
have the same name in every cluster:* so the instrumentation config is identical everywhere.

### Flows — live from the relay, history through Loki

```
 every node, both clusters: cilium-agent's Hubble server :4244 (mTLS, one root CA since demo 24)
        │                                                    │
        └──── poc1's hubble-relay peers ALL 7 nodes ─────────┘   (ClusterMesh + shared CA = 7/7; before demo 24: 5/7)
                          │ mTLS :443
        ┌─────────────────┼──────────────────────┐
        ▼                 ▼                      ▼
   Hubble UI         hubble CLI            hubble-observer (poc1 only — one relay already sees the mesh)
   (live map,        (operators:            `observe --verdict DROPPED --follow -o json` → stdout
    minutes of        hubble-tls.sh)              │ /var/log/pods, tailed by the poc1 collector
    ring buffer)                                  ▼ otlphttp, labels namespace/container/k8s.cluster.name
                                             Loki (24 h) ──▶ Grafana "Cilium Flows – Hubble Observer":
                                             time range, flows/min, table — per source/destination cluster
   plus, per cluster: Hubble METRICS :9965 (dynamic, contexts app/workload, cluster label) → that cluster's
   Prometheus → the hub → the Hubble dashboards; and on poc1 only: Hubble flow EXPORT files → the collector's
   logs pipeline (demo 10, debug exporter — the events-not-spans story).
```

*Why the observer runs in poc1 only:* since demo 24 the hub's relay streams every node of every
meshed cluster and each flow carries `source.cluster_name` / `destination.cluster_name`; a drop caused
in poc2 lands in Loki labelled `poc2` (demo 25 Part 3b). A per-cluster observer is the right shape
when relays are not meshed or the relay stream would cross a WAN.

## The rationale, in one table

| Decision | Reason | Where measured |
|---|---|---|
| Hub-and-spoke, not a UI per cluster | one `cluster` dropdown; the spokes keep enough to run alone | demo 22 |
| Every cluster keeps a Prometheus | local queries/alerts survive the hub or the mesh being down | demo 22 |
| `cluster` stamped at the source | `external_labels` on spokes; a default scrape class on the hub; OBI's `cluster_name`; the gateway's `resource` insert | demo 22 Part 4, demo 18, demo 23 |
| Global Services only where the flow must cross | `prometheus-remote-write`, `tempo-central`: role-named, hub backends only; apps declare their own HA | demo 22 (#69) |
| A collector per cluster, never global | identity, buffering, egress are the cluster's own; seven-backend trap | demo 23 (#70) |
| One relay reads the mesh | shared CA (#71) → 7/7 nodes; the observer then needs one instance | demo 24, demo 25 |
| Relay on mTLS from day one | any pod read every flow of both clusters in plaintext (#75) | demo 25 Part 5 |
| Hub Prometheus sized as a hub | 1Gi = 51 OOM kills once poc2 wrote in; 2Gi + out-of-order window | demo 22 Part 5 (#77) |

## What is actually deployed (2026-09-12)

| | poc1 (hub) | poc2 (spoke) |
|---|---|---|
| Cilium / Hubble | agents ×5, envoy ×5, relay (mTLS), **UI**, clustermesh-apiserver, Hubble metrics :9965, dynamic **flow export** to files | agents ×2, envoy ×2, relay (mTLS), clustermesh-apiserver, Hubble metrics :9965 — no UI, no export |
| Metrics | kube-prometheus-stack `monitoring`: Prometheus (2Gi, receiver on), Alertmanager, **Grafana**, kube-state-metrics, node-exporter ×5; 17 monitors incl. OBI | kube-prometheus-stack `edge`: Prometheus (768Mi, 6 h, remote_write), kube-state-metrics, node-exporter ×2; 13 monitors incl. OBI (PodMonitor added 2026-09-12) |
| Traces | OBI DaemonSet, otel-collector **DaemonSet** ×5 (demo 10), **Tempo** | OBI DaemonSet, otel-collector **Deployment** ×2 (demo 23) → `tempo-central` |
| Flows history | hubble-observer + cf2cnp, **Loki** | — (read through poc1's relay) |
| Global Services (platform) | `prometheus-remote-write`, `tempo-central` (hub backends) | the same two objects, backends in poc1 |
| Global Services (apps) | bank: accounts, payments, postgres-primary/standby, redis; demo 07's | the same |

Everything above the line is the standard for poc-N: OBI, a gateway collector, a Prometheus under
its own release name, the relay peered — and nothing else.
