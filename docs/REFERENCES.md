# REFERENCES — every external source this PoC was built against

Each entry says what it was used for and where. Everything here was fetched during the build
(dated 2026-09-10 → 2026-09-12); statements quoted in the demos come from these pages as they read
on those dates. Pinned versions: Cilium **1.20.1**, kind **0.33.0**, Kubernetes **v1.36.4**,
cert-manager **v1.21.1**, Gateway API **v1.6.1**.

## Cilium — the documentation this PoC depends on

| Topic | Source | Used in |
|---|---|---|
| Release notes and headline features of 1.20 | [cilium/cilium v1.20.0 release](https://github.com/cilium/cilium/releases/tag/v1.20.0) · [Isovalent: Cilium 1.20](https://isovalent.com/blog/post/cilium-1-20/) | README versions, `docs/summary/MTLS_EVALUATION.md` §7 |
| LoadBalancer IPAM (the two reserved pools) | [LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/) | `NETWORKING_DESIGN.md`, SETUP Step 8, `cilium/lb-ippool.yaml` |
| L2 announcements (who answers ARP for a VIP) | [L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/) | `NETWORKING_DESIGN.md` §4.4, gotcha #14 |
| Masquerading → eBPF host routing (the day-1 value) | [Masquerading](https://docs.cilium.io/en/stable/network/concepts/masquerading/) · [Tuning Guide](https://docs.cilium.io/en/stable/operations/performance/tuning/) | `docs/TUNING.md` §1, demo 11 Part 3, `cilium/values-poc*.yaml` |
| Benchmark methodology (netperf, TCP_CRR, CPU per throughput) | [CNI Performance Benchmark](https://docs.cilium.io/en/stable/operations/performance/benchmark/) | demo 11 Part 4, demo 14 |
| ClusterMesh: global services, the "Service in every cluster" rule | [Global Services](https://docs.cilium.io/en/stable/network/clustermesh/global-services/) | demos 07, 15 |
| ClusterMesh: `service.cilium.io/affinity` (local / remote / none) | [Service Affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/) | demo 15 Failover B |
| Load-balancing algorithm: `random` default, `maglev` per Service (`service.cilium.io/lb-algorithm`, creation-time only), Maglev's 1 % reassignment property, socket-LB vs per-packet | [Kubernetes Without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/) · [ClusterMesh Load-balancing & Service Discovery](https://docs.cilium.io/en/stable/network/clustermesh/load-balancing/) | demo 15 Part 9 |
| Mutual authentication (SPIFFE/SPIRE) — deprecated | [Mutual Authentication](https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/) · [cilium#47132 deprecation CFP](https://github.com/cilium/cilium/issues/47132) | `docs/summary/MTLS_EVALUATION.md` |
| ztunnel (the successor) — guide and CFP | [`Documentation/security/network/encryption-ztunnel.rst` @ v1.20.1](https://github.com/cilium/cilium/blob/v1.20.1/Documentation/security/network/encryption-ztunnel.rst) · [`examples/kubernetes-ztunnel/generate-secrets.sh`](https://github.com/cilium/cilium/blob/v1.20.1/examples/kubernetes-ztunnel/generate-secrets.sh) · [cilium#38548 ztunnel CFP](https://github.com/cilium/cilium/issues/38548) | demo 13 |
| ztunnel ↔ ClusterMesh incompatibility, in the source | [`pkg/ztunnel/cell.go`](https://github.com/cilium/cilium/blob/v1.20.1/pkg/ztunnel/cell.go) · [`pkg/clustermesh/clustermesh.go`](https://github.com/cilium/cilium/blob/v1.20.1/pkg/clustermesh/clustermesh.go) | demo 13 Part 1, gotcha #45 |
| Gateway API gRPC needs ALPN | [Gateway API gRPC example](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/grpc/) · [cilium#30794](https://github.com/cilium/cilium/issues/30794) · [cilium#39484](https://github.com/cilium/cilium/issues/39484) | demo 09 Part 5b, gotcha #33 |
| BGP control plane (parked demo 12) | [BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/) · [BGP configuration](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/) · [BGP dev lab](https://docs.cilium.io/en/stable/contributing/development/bgp_cplane/) · [`contrib/containerlab/service` @ v1.20.1](https://github.com/cilium/cilium/tree/v1.20.1/contrib/containerlab/service) | `docs/summary/BGP_FRR_PLAN.md` |
| Metrics: agent/operator/Hubble helm values, ServiceMonitor vs annotations ("if ServiceMonitor is enabled, these annotations are omitted"), Hubble context options, the `dns`/`httpV2` options, the dynamic metrics ConfigMap | [Monitoring & Metrics](https://docs.cilium.io/en/stable/observability/metrics/) · [Running Prometheus & Grafana](https://docs.cilium.io/en/stable/observability/grafana/) · [`metrics.rst` @ v1.20.1](https://github.com/cilium/cilium/blob/v1.20.1/Documentation/observability/metrics.rst) | demo 16 |
| The dynamic-config refusal, in the source | [`pkg/hubble/metrics/metric_config_watcher.go`](https://github.com/cilium/cilium/blob/v1.20.1/pkg/hubble/metrics/metric_config_watcher.go) · [`pkg/hubble/metrics/dns/handler.go`](https://github.com/cilium/cilium/blob/v1.20.1/pkg/hubble/metrics/dns/handler.go) | gotcha #59, demo 16 Part 9 |
| The metric contexts Isovalent ships with its Grafana demo | [isovalent/cilium-grafana-observability-demo `helm/cilium-values.yaml`](https://github.com/isovalent/cilium-grafana-observability-demo/blob/main/helm/cilium-values.yaml) | demo 16 Part 6 |
| kube-prometheus-stack chart (Prometheus Operator, Grafana sidecar, `serviceMonitorSelectorNilUsesHelmValues`) | [prometheus-community/helm-charts — kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) — chart 90.1.1, operator v0.93.1, `helm show values` | demo 16 Section A, gotcha #57 |
| Helm chart values (defaults read for the service-mesh table, socket LB, ALPN, ztunnel) | [helm.cilium.io](https://helm.cilium.io/) — `helm show values cilium/cilium --version 1.20.1` | SETUP Step 5.4, gotchas #40, #49 |

## Kubernetes, kind, Gateway API, cert-manager

| Topic | Source | Used in |
|---|---|---|
| kind (node image pins, `KIND_EXPERIMENTAL_DOCKER_NETWORK`) | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/) | SETUP Steps 1–3, `clusters/poc3.yaml`, `clusters/poc4.yaml` |
| Gateway API CRDs (standard + experimental `TCPRoute`) | [kubernetes-sigs/gateway-api v1.6.1](https://github.com/kubernetes-sigs/gateway-api/tree/v1.6.1/config/crd) | demos 05, 09 |
| kube-proxy metrics (programming latency, rules count) | [`pkg/proxy/metrics/metrics.go` @ release-1.36](https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/proxy/metrics/metrics.go) · [Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/) | demo 11 §1 |
| cert-manager chart | [charts.jetstack.io](https://charts.jetstack.io) | SETUP Step 9.3a, demo 08 |
| gRPC ALPN enforcement (why grpcurl passed and grpc-go failed) | [grpc-go#434](https://github.com/grpc/grpc-go/issues/434) | demo 09 Part 5b |

## Designs and write-ups this PoC drew on

| Topic | Source | Used in |
|---|---|---|
| The bank's shape (frontend → ledger / balance / accounts over Postgres) | [Bank of Anthos](https://github.com/GoogleCloudPlatform/bank-of-anthos) | demo 15 design |
| Shared-services across clusters with ClusterMesh | [AWS: a multi-cluster shared services architecture with Amazon EKS using Cilium ClusterMesh](https://aws.amazon.com/blogs/containers/a-multi-cluster-shared-services-architecture-with-amazon-eks-using-cilium-clustermesh/) | demo 15 design |
| TCP_CRR tuning claims (tested, mostly not applicable here) | [OneUptime: Fix Connection Rate (TCP_CRR) Cilium Performance](https://oneuptime.com/blog/post/2026-03-14-fix-connection-rate-tcp-crr-cilium-performance/view) | demo 14 |
| FRR in a container peering with Kubernetes on macOS | [Exposing Kubernetes Service using Calico CNI and FRRouting BGP on macOS](https://medium.com/@dwiveditanuj41/exposing-kubernetes-service-using-calico-cni-and-frrouting-bgp-on-macos-8a3369f65015) | `docs/summary/BGP_FRR_PLAN.md` |

## Images and tools (pinned as used)

| What | Where | Used in |
|---|---|---|
| `kindest/node:v1.36.4` (by digest) | Docker Hub | every cluster |
| `quay.io/cilium/cilium:v1.20.1`, `quay.io/cilium/ztunnel:v1.0.0` | quay.io | all clusters; demo 13 |
| `frrouting/frr` (Docker Hub stops at v8.4.1, 2022) → `quay.io/frrouting/frr:10.7.1` | Docker Hub / quay.io tag APIs | BGP plan |
| `fullstorydev/grpcurl` v1.9.3, `nicolaka/netshoot:v0.14`, `fortio/fortio:1.69.5`, `networkstatic/iperf3`, `curlimages/curl:8.14.1` | Docker Hub | demos 09, 11, 13, 15 |
| `postgres:16-alpine`, `redis:7-alpine` | Docker Hub | demo 15 |
| `otel/opentelemetry-collector-contrib:0.160.0` | Docker Hub | demo 10 |
| Go modules: `google.golang.org/grpc` v1.76.0, `github.com/jackc/pgx/v5` v5.11.0 (needs Go ≥ 1.25), `github.com/redis/go-redis/v9` v9.22.0 | Go proxy | demos 09, 15 |

## Standard references relied on but not re-fetched

| Topic | Source | Used in |
|---|---|---|
| PostgreSQL 16 streaming replication, hot standby, `pg_basebackup -R`, replication slots, `pg_promote()` | [PostgreSQL 16 manual, ch. 27 High Availability](https://www.postgresql.org/docs/16/high-availability.html) · [`pg_basebackup`](https://www.postgresql.org/docs/16/app-pgbasebackup.html) | demo 15 Part 8 — every setting was read back from the live server rather than assumed |
