# Enhancement 002 — the shop platform on the mesh: global services, a gateway per cluster, an "external" database behind a TCPRoute, egress IPs, load, HPA and DR

Status: **plan, revision 2** (2026-09-13) — the operator's decisions on D1–D5 are folded in (§5 is now the decision
log). Nothing built yet. Written from the operator's summary, the Cilium 1.20.1 documentation, and measurements on
poc1/poc2 taken today; every fact that shaped a decision is in §2 with its source.

## 1. The brief, rewritten

Take demo 35's shop platform and run it as a **ClusterMesh application**: the same namespaces in poc1 and poc2,
stateless services deployed in both and declared global so each cluster serves itself and fails over to the other,
one database in poc1 that the platform treats as an **external database** — reached by an IP and a DNS name
through a TCPRoute, never by a Kubernetes Service name — an API gateway in each cluster behind one public URL that
an external customer's client keeps calling through every failure, load with health checks and autoscaling, a
vendor namespace whose traffic carries addresses Cilium assigns, and a series of failures and a DR exercise that
prove the whole thing behaves. Every policy is generated from observed flows with cf2cnp (the descriptions saying
who may reach whom, in which cluster, by which name), and every claim is measured.

| # | Requirement | Cilium feature it exercises |
|---|---|---|
| R1 | The platform's namespaces exist in **both** clusters with the same names; the stateless services (`api-gateway`, `catalog`, `orders`, `payment-gateway`, `merchant`, `reviews`, `backend`) run in both | ClusterMesh: identical name + namespace is what makes a service global |
| R2 | Every stateless service is a **global service that prefers its own cluster** and falls over to the other only when its local backends are gone | `service.cilium.io/global: "true"` + `service.cilium.io/affinity: local` |
| R3 | The **database** (`shop-db`, PostgreSQL) runs in **poc1 only** and is treated as an **external database**: it is published on the poc1 Gateway with a **TCPRoute** on port 5432, a **pinned address** and the DNS name **`db-service.poc.local`**; the backend in both clusters connects to that name, not to a Service name | Gateway API `TCPRoute`, LB IPAM static address, the DNS proxy (`toFQDNs`) |
| R4 | The backend's egress policy is **generated as `toFQDNs: matchName: db-service.poc.local`** (plus DNS) and nothing else; the database admits ingress **only from the Gateway that fronts it** (the way an external database's firewall admits the gateway's address) | DNS visibility → `toFQDNs` (demo 31's path), `reserved:ingress` |
| R5 | An **API gateway per cluster**; **one public URL** `api.shop.poc.local` on a **virtual address that poc1 announces and poc2 takes over in DR**, plus one address per cluster for observation; a script produces the MacBook's `/etc/hosts` block from live state | Gateway API in both clusters, LB IPAM static addresses, L2 announcements as the takeover mechanism |
| R6 | **Two external clients**, one in Go and one in Python, on the MacBook (or any Linux box): they know **only the URL**, check health, generate load, report per-second success and the serving cluster, and have a flag to skip CA verification; what happens behind the URL is the mesh's business | the platform seen from outside the mesh |
| R7 | Every workload has **liveness and readiness probes**; the stateless services **autoscale** (HPA on CPU) under the clients' load | metrics-server + HPA, so the failure scenarios are honest |
| R8 | A **vendor namespace** with a `customer` service gets addresses **from Cilium's pool**: an ingress LoadBalancer IP on the mesh clusters, and an **egress IP** on its traffic to the outside — on a **throwaway single cluster**, because the egress gateway is documented as incompatible with Cluster Mesh | LB IPAM; Egress Gateway |
| R9 | **Failure and DR scenarios**, each measured from the client and from Hubble: a pod dies, a service scales to zero in one cluster, a node is drained, a whole cluster is paused and poc2 takes over the public address, the mesh link is cut, the database is lost, everything comes back | global services, affinity, L2 takeover, health |
| R10 | Policies for all of it are **generated from flows**, reviewed by their descriptions, applied under audit first, then enforced; the verdict dashboards show both clusters | enhancement 001 end to end, on the mesh |

## 2. What research and measurement changed in the brief

| Fact | Source | Consequence in the plan |
|---|---|---|
| A global service load-balances across clusters when the Service has the **identical name and namespace** in each cluster; `shared: "false"` keeps a cluster's backends to itself while still consuming remote ones | [Global Services, 1.20](https://docs.cilium.io/en/stable/network/clustermesh/global-services/) | R1 as written; the stateless services are global in both clusters |
| `service.cilium.io/affinity: local` — "the Global Service will load-balance across healthy local backends, and only use remote endpoints if and only if all of local backends are not available or unhealthy" | [Service Affinity, 1.20](https://docs.cilium.io/en/stable/network/clustermesh/affinity/) | R2 is the documented behaviour; scenario S2 measures it |
| **Egress gateway is not compatible with Cluster Mesh** — "the gateway selected by an egress gateway policy must be in the same cluster as the selected pods"; needs BPF masquerade + KPR (on here), CRD identities (on here); applies only to destinations **outside** the cluster; new pods have a short window before the policy applies | [Egress Gateway, 1.20.1](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/) | R8's egress IP runs on a throwaway `poc5` (as demo 13 ran ztunnel on `poc4`), with an external receiver on that docker network measuring the source IP. Recorded as a gotcha |
| A Gateway takes its address from LB IPAM; a **specific address** is requested with `spec.addresses` (type `IPAddress`) | [Gateway API, 1.20](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/) | R3, R5: pinned addresses for the shop gateways and the DB route |
| A Gateway's `TCPRoute` forwards a TCP listener to a Service; demo 09 ran one on poc1 (the line-echo server) with the native Go client | demo 09, [Gateway API — TCPRoute support](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/) | R3: the DB behind a `TCPRoute` on a dedicated Gateway listener (port 5432), the Envoy proxy in between |
| Traffic that reaches a pod **through the Gateway carries the Gateway's identity, `reserved:ingress`**, not the caller's (measured in demo 33 on cf2cnp) | demo 33 Part 2, the review's C12 | R4: the DB's policy admits `reserved:ingress` on 5432 — the backend's identity ends at the proxy, exactly as with an external database and its firewall. The **backend's** policy is where "only the backend may reach the DB" lives, as `toFQDNs` |
| `toFQDNs` needs the DNS proxy: an egress L7 DNS rule on the endpoint; the names must resolve through kube-dns for the proxy to see them | [layer3.rst v1.20.1 lines 502–506](https://raw.githubusercontent.com/cilium/cilium/v1.20.1/Documentation/security/policy/layer3.rst), demo 31 | R3/R4: `db-service.poc.local` must resolve **inside** both clusters: a CoreDNS `hosts` entry (the `.poc.local` zone is not a cluster domain), then cf2cnp's `--dns-visibility` → `toFQDNs` on the next run, as demo 31 did |
| Two clusters on one bridge can each announce addresses with L2 announcements; an address announced by both at once is an ARP conflict. Cilium's L2 announcer holds a lease per service and sends gratuitous ARP when it takes one | [L2 Announcements, 1.20](https://docs.cilium.io/en/v1.20/network/l2-announcements/) | R5/R9: the public VIP is in **both** clusters' Gateways but **announced by poc1 only**; poc2's `CiliumL2AnnouncementPolicy` for it is applied by the DR runbook (`scripts/vip-takeover.sh poc2`) — an active/passive takeover the client never sees except as a pause |
| **poc2 has no Gateway API CRDs, no L2 announcement policy, no LB pool and `gatewayAPI` off** (measured) | `kubectl --context kind-poc2 get crd`, `helm get values` | Phase 0 brings poc2 to poc1's level, with a pool disjoint from poc1's |
| **No metrics-server in either cluster** (measured) | `kubectl top nodes` | R7: metrics-server on both (kind needs `--kubelet-insecure-tls`), HPA v2 on CPU |
| The MacBook reaches the kind bridge directly (measured: the Gateway at 172.18.255.240 → 200) | this session | R6 works with a hosts entry; the DBA's `psql` reaches the DB route the same way |
| Both clusters run VXLAN, BPF masquerade, KPR, CRD identities; the wildcard `*.poc.local` certificate comes from the enterprise root in poc1 and cert-manager runs in poc2 | `cilium-dbg status`, `cilium-config`, `get certificate` | poc2's Gateway carries a certificate from the same root; the clients trust one CA, or skip verification with the flag |

## 3. Architecture

```mermaid
flowchart LR
  subgraph mac["MacBook / any Linux box (outside the mesh)"]
    go["shopctl (Go)"]
    py["shopctl.py (Python)"]
    dba["psql (DBA)"]
    hosts["/etc/hosts (scripts/hosts-entries.sh)\napi.shop.poc.local   → 172.18.255.160  VIP, poc1 announces, poc2 takes over\napi.poc1.shop.poc.local → 172.18.255.242\napi.poc2.shop.poc.local → 172.18.255.142\ndb-service.poc.local → 172.18.255.244"]
  end

  subgraph poc1["poc1 — 3 CP + 2 workers, cluster.id 1"]
    gw1["Gateway shop-gw\naddresses: 172.18.255.160 (VIP), 172.18.255.242\nHTTPRoute api.shop.poc.local"]
    dbgw["Gateway db-gw  172.18.255.244\nlistener 5432 → TCPRoute → shop-db"]
    subgraph ns1["shop-edge · shop-core · shop-payments · shop-merchant · shop-reviews · vendor"]
      ag1["api-gateway"] --> cat1["catalog"] & ord1["orders"] & rev1["reviews"] & pay1["payment-gateway"]
      ord1 --> be1["backend (Go)"]
      pay1 --> mer1["merchant"]
      cust1["customer (vendor)\nLB IP 172.18.255.243"]
    end
    db1[("shop-db — PostgreSQL\npoc1 only\ningress: reserved:ingress on 5432")]
    dbgw --> db1
    gw1 --> ag1
    be1 -->|"db-service.poc.local\n(toFQDNs, via the DNS proxy)"| dbgw
    dns1["CoreDNS hosts:\ndb-service.poc.local 172.18.255.244"]
  end

  subgraph poc2["poc2 — 1 CP + 1 worker, cluster.id 2"]
    gw2["Gateway shop-gw\naddresses: 172.18.255.160 (VIP, announced only in DR), 172.18.255.142\nHTTPRoute api.shop.poc.local"]
    subgraph ns2["same namespaces"]
      ag2["api-gateway"] --> cat2["catalog"] & ord2["orders"] & rev2["reviews"] & pay2["payment-gateway"]
      ord2 --> be2["backend (Go)"]
      pay2 --> mer2["merchant"]
    end
    gw2 --> ag2
    dns2["CoreDNS hosts:\ndb-service.poc.local 172.18.255.244"]
  end

  go & py -->|"HTTPS api.shop.poc.local (the VIP)"| gw1
  go & py -.->|"after takeover, same URL, same IP"| gw2
  dba -->|5432| dbgw
  be2 -->|"db-service.poc.local, across the bridge"| dbgw
  cat2 -.->|"affinity: local → remote\nonly when local gone"| cat1
  cat1 -.-> cat2

  subgraph poc5["poc5 — throwaway single cluster (egress gateway; not compatible with Cluster Mesh)"]
    vend["vendor/customer"] -->|"SNAT to egress IP 172.31.0.200"| ext["external receiver\n(container on the kind-lab network)\nlogs the source IP"]
  end
```

Namespaces are identical in poc1 and poc2 (R1). Solid arrows are the calls the application makes; dotted arrows
are what Cilium adds or what DR changes: cross-cluster backends for the global services, used only when the local
ones are gone (R2), and the public VIP served by poc2 after the takeover (R5, S4). The database is on the far side
of a Gateway for **everyone** — the backends in both clusters and the DBA on the MacBook reach the same address
and name (R3).

### 3.1 The database as an external database — what that buys and what it costs

- **Buys:** the backend's configuration is a hostname and a port, as it would be for RDS or an on-prem Postgres; the
  policy cf2cnp writes for it is the one an external dependency gets, `toFQDNs: matchName: db-service.poc.local`,
  discovered from the flows once the DNS proxy is on (demo 31's two generations); the same name and address work
  from poc1, from poc2 and from the DBA's laptop; moving the database out of the cluster later changes one hosts
  entry, no policy.
- **Costs:** the Gateway's Envoy sits in the path, so the DB pod sees `reserved:ingress`, not the backend — the
  backend's identity is enforced on the backend's egress (R4), and the DB's own policy admits the Gateway on 5432
  and nothing else. The hop is measured in demo 38 (Hubble shows `backend → db-gw` as `toFQDNs`-allowed egress and
  `reserved:ingress → shop-db` as the DB's ingress). A pod in poc1 could also reach the Gateway's address by its
  Service path; the policy names the FQDN, so the path does not matter to it.

### 3.2 Workloads

| Namespace | Workload | Image | Where | Service / route | Probes | HPA |
|---|---|---|---|---|---|---|
| shop-edge | api-gateway (nginx reverse proxy) | nginx + ConfigMap | poc1, poc2 | global, affinity local; behind `shop-gw` (HTTPRoute `api.shop.poc.local`) which adds `X-Served-By: <cluster>` | `/healthz`, `/ready` (proxies catalog `/healthz`) | CPU 60 %, 1–3 |
| shop-core | catalog, orders | nginx + ConfigMap | poc1, poc2 | global, affinity local | `/healthz`, `/ready` | CPU 60 %, 1–3 |
| shop-core | **backend** (Go, `shopapi`) | built here, `kind load` into both | poc1, poc2 | global, affinity local; `DB_URL=postgres://…@db-service.poc.local:5432/shop` | `/healthz`; `/ready` = `SELECT 1` | CPU 60 %, 1–3 |
| shop-core | **shop-db** (PostgreSQL) | postgres:16-alpine (on the nodes) | **poc1 only** | ClusterIP for the TCPRoute only; `db-gw` Gateway, listener 5432, address `172.18.255.244`, name `db-service.poc.local` | `pg_isready` | none |
| shop-payments | payment-gateway | nginx + ConfigMap | poc1, poc2 | global, affinity local | as above | 1–3 |
| shop-merchant | merchant | nginx + ConfigMap | poc1, poc2 | global, affinity local | as above | 1–3 |
| shop-reviews | reviews, ratings | nginx + ConfigMap; alpine caller | poc1, poc2 | global, affinity local | as above | 1–3 |
| shop-clients | shopper, stranger | alpine callers | poc1, poc2 | — | — | — |
| vendor | customer | nginx + ConfigMap | poc1, poc2 (LB IP `172.18.255.243` / `.143`); **poc5** (egress IP) | LB IPAM static address | as above | — |

`shopapi` is the one workload that must be a program: it opens a PostgreSQL connection to `db-service.poc.local`,
so the DB policy is measured on a real query. It is a small Go service (`/orders` reads a table, `/ready` runs
`SELECT 1`, `/healthz` answers), one static binary like demo 09's `routedemo`.

### 3.3 The external clients

Two implementations of one contract, so a customer with either toolchain can run it:

| | `demos/37-…/client/go/shopctl` | `demos/37-…/client/python/shopctl.py` |
|---|---|---|
| runtime | Go, one static binary for macOS/Linux | Python 3.9+, standard library only (`urllib`, `ssl`, `threading`) |
| `probe` | every path once, status and `X-Served-By` per path | same |
| `load --rate N --duration M` | N requests/s for M seconds, per-second success/failure and which cluster served, a latency histogram at the end | same |
| `--url https://api.shop.poc.local` | the only address it knows | same |
| `--cacert docs/root-ca.crt` | trust the enterprise root | same |
| `--insecure` / `-k` | skip CA verification (the operator's flag) | same |
| exit code | the number of failed checks / non-2xx seconds | same |

Neither client knows there are two clusters; `X-Served-By` is only reported, never used.

### 3.4 Policy matrix (what cf2cnp generates from the observed flows)

| Subject | Ingress from | Egress to |
|---|---|---|
| api-gateway (shop-edge) | `reserved:ingress` (the Gateway), shopper | catalog, orders, reviews, payment-gateway (local by affinity), kube-dns |
| catalog (shop-core) | orders, api-gateway (shop-edge), merchant (shop-merchant), reviews (shop-reviews) — **from both clusters** once S2 has produced the cross-cluster flows, so the remote peers carry `io.cilium.k8s.policy.cluster` | kube-dns |
| orders (shop-core) | api-gateway | catalog, payment-gateway, backend, kube-dns |
| **backend** (shop-core) | orders (both clusters) | **`toFQDNs: db-service.poc.local` on TCP/5432** and the kube-dns DNS rule — nothing else, measured with a call to catalog that must be dropped |
| **shop-db** (shop-core, poc1) | **`reserved:ingress` on TCP/5432** (the `db-gw` Envoy) — nothing else | none |
| payment-gateway, merchant, reviews | as demo 35, both clusters | as demo 35 |
| customer (vendor) | `reserved:world` on its LB IP (the MacBook) | the external receiver only (poc5), through the egress gateway |

## 4. Phases, demos, and the scripts each one adds

| Phase | Demo | What it delivers | Scripts / files it adds | Reqs |
|---|---|---|---|---|
| 0 — poc2 catches up, the tooling | 36 | Gateway API CRDs v1.6.1, `gatewayAPI.enabled`, `l2announcements`, LB pools on poc2 (`172.18.255.100–127` services, `.128–159` gateways; the VIP `.160` in a pool present in **both** clusters), a wildcard certificate from the enterprise root on poc2; metrics-server on both; the platform manifests parameterised for both contexts; `shopapi` built and loaded into both clusters; both clients built | `demos/36/apply-poc2-prereqs.sh`, `demos/36/metrics-server.sh`, `demos/36/build.sh` (shopapi image, shopctl binaries), `clusters/poc2-lb-ippool.yaml` | R1, R5, R7 |
| 1 — the platform, global, one URL | 37 | The platform in both clusters (`apply-both.sh`), every stateless Service `global` + `affinity: local`; `shop-gw` in both with the VIP and a per-cluster address, HTTPRoute `api.shop.poc.local`, the `X-Served-By` header; the hosts block; `shopctl probe` from the MacBook (Go and Python); observe-first in both clusters, one `/generate` per cluster, descriptions reviewed, audit, enforce; the dashboards per cluster | `demos/37/apply-both.sh`, `demos/37/audit-both.sh`, `demos/37/flows-both.sh`, `demos/37/generate-both.sh`, `scripts/hosts-entries.sh` extended (the four names), `demos/37/client/{go,python}` | R1, R2, R5, R6, R10 |
| 2 — the external database | 38 | `shop-db` in poc1; `db-gw` with the TCPRoute and the pinned address; CoreDNS `hosts` entries in both clusters; `backend` configured with the FQDN; the DBA's `psql` from the MacBook; the backend's flows show the world IP first (no names) → `--dns-visibility` → the next flows carry `db-service.poc.local` → `toFQDNs`; the DB's policy (`reserved:ingress` on 5432); a backend call to catalog dropped; poc2's backend reaching the DB across the bridge with a real query | `demos/38/db.yaml` (StatefulSet, ClusterIP), `demos/38/db-gateway.yaml` (Gateway + TCPRoute + ReferenceGrant), `demos/38/coredns-hosts.sh`, `demos/38/db-check.sh` (psql from the MacBook and from each backend) | R3, R4 |
| 3 — the vendor: LB IP and egress IP | 39 | `customer` with a pinned LB IP in both mesh clusters (the MacBook calls it); `poc5` created (`clusters/poc5.yaml`, network `kind-lab`, `egressGateway.enabled`), the vendor namespace deployed there, an external receiver container, the source IP measured **without** and **with** the `CiliumEgressGatewayPolicy` (`cilium-dbg bpf egress list`), `poc5` deleted; gotcha: egress gateway and Cluster Mesh | `demos/39/vendor.yaml`, `demos/39/poc5-up.sh`, `demos/39/receiver.sh` (the container), `demos/39/egress-policy.yaml`, `demos/39/poc5-down.sh` | R8 |
| 4 — load, health, autoscaling | 40 | `shopctl load` from the MacBook (both clients); HPA scaling catalog / orders / api-gateway up and back (`kubectl get hpa -w` recorded in both clusters); readiness taking a backend out of the endpoints when the DB is unreachable; verdicts staying forwarded through the scale events | `demos/40/hpa.yaml`, `demos/40/load.sh` (wraps the clients), `demos/40/watch.sh` | R7 |
| 5 — failures and DR | 41 | The scenario table below, each with the clients' per-second view and Hubble's | `demos/41/scenario.sh <S1..S7>`, `scripts/vip-takeover.sh <cluster>` (applies / removes the L2 policy for the VIP), `scripts/cluster-pause.sh` (exists) | R9 |

Every demo keeps the house rules: `scripts/record.sh` on every command into `output/transcript.txt`, `evidence.json`
captures, a README with the enterprise case, a GUIDE with exercises, a cleanup script.

### 4.1 Failure and DR scenarios (demo 41)

| # | Scenario | Action | Expected, to be measured (client + Hubble) |
|---|---|---|---|
| S1 | A pod dies | `kubectl delete pod` of catalog in poc1 (HPA min 2 for this demo) | the other replica serves; the clients' success stays 100 % |
| S2 | A service is gone in one cluster | `kubectl scale deploy/catalog --replicas=0` in poc1 | **affinity fallback**: poc1's api-gateway reaches catalog in poc2 (`destination.cluster_name: poc2` in Hubble, `X-Served-By` still poc1); no client error; scale back → local again |
| S3 | A node is drained | `kubectl drain poc1-worker2` | pods reschedule; the L2 lease for the VIP moves to another poc1 node (gratuitous ARP; the clients see at most a pause); failover counter 0 |
| S4 | A whole cluster is paused — **DR** | `scripts/cluster-pause.sh poc1`, then `scripts/vip-takeover.sh poc2` | the VIP stops answering; after the takeover the **same URL and IP** answer from poc2 (`X-Served-By: poc2`); everything serves **except** the DB path (the DB is in poc1 — `backend /ready` fails, orders that need it degrade): the honest picture of a single-site database, and the argument for a replica in poc2 as a follow-up |
| S5 | The mesh link is cut | scale `clustermesh-apiserver` to 0 in poc1 (or a policy on 2379) | each cluster keeps serving locally (affinity local); on restore the remote endpoints return |
| S6 | The database is lost | scale shop-db to 0 | backend `/ready` fails in both clusters, orders degrade, everything else serves; the readiness probe keeps the gateway from routing to a backend that cannot answer |
| S7 | Everything back | resume poc1, `vip-takeover.sh poc1`, scale up | the VIP back on poc1 (`X-Served-By: poc1`), the DB path back, verdicts on the local paths |

## 5. Decision log

| # | Decision | Outcome |
|---|---|---|
| D1 + D2 | The database as an **external database**: a TCPRoute on a Gateway, a pinned address, the name `db-service.poc.local`, the backend on the FQDN, the policy auto-generated as `toFQDNs` | **Taken** (operator, 2026-09-13). The DB's own policy admits the Gateway's identity; the backend's identity is enforced on its egress (§3.1) |
| D1 (egress IP) | The vendor namespace's egress IP on a throwaway cluster, since the feature is documented as incompatible with Cluster Mesh | **Taken** |
| D3 | The backend as a Go service with a real PostgreSQL query | **Taken** |
| D4 | The client knows only the URL; failover is the mesh's business | **Taken** — the public VIP is announced by poc1 and taken over by poc2 in DR (L2 announcements); two clients, Go and Python, with `--insecure` |
| D5 | Demos 36–41, scripts per demo, steps a junior can follow | **Taken** |

## 6. Stack facts the plan relies on

| Fact | Source |
|---|---|
| Global services: identical name + namespace in each cluster; `shared: "false"` keeps backends local | [docs.cilium.io — Global Services](https://docs.cilium.io/en/stable/network/clustermesh/global-services/) |
| `affinity: local` uses remote endpoints only when every local backend is unavailable or unhealthy | [docs.cilium.io — Service Affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/) |
| Egress gateway: not compatible with Cluster Mesh; BPF masquerade + KPR; CRD identities; cluster-external destinations; `cilium-dbg bpf egress list` | [docs.cilium.io — Egress Gateway 1.20.1](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/) |
| Gateway addresses from LB IPAM; a static address via `spec.addresses`; TCPRoute supported | [docs.cilium.io — Gateway API](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/), demo 09 |
| L2 announcements: leases per service, gratuitous ARP on takeover | [docs.cilium.io — L2 Announcements](https://docs.cilium.io/en/v1.20/network/l2-announcements/) |
| `toFQDNs` needs the DNS proxy (an L7 DNS rule); names come from the DNS answers the proxy sees | [layer3.rst v1.20.1](https://raw.githubusercontent.com/cilium/cilium/v1.20.1/Documentation/security/policy/layer3.rst), demo 31 |
| A request through a Cilium Gateway reaches the pod as `reserved:ingress` | demo 33 Part 2 (measured) |
| A selector without the cluster label matches the local cluster only (1.19+) | [policy.rst v1.20.1](https://raw.githubusercontent.com/cilium/cilium/v1.20.1/Documentation/network/clustermesh/policy.rst), demo 29 |
| poc1: KPR, VXLAN, BPF masquerade, L2, Gateway API, pools `.200–239` / `.240–250`, gateways at `.240`/`.241`; poc2: KPR, VXLAN, BPF masquerade, no Gateway API/L2/pool; no metrics-server; the MacBook reaches the bridge | measured 2026-09-13 |

## 7. Risks

- **Memory.** Seven kind nodes plus the observability stack already run on the Docker Desktop VM; `poc5` exists for
  one demo and is deleted after. HPA maxima stay at 3.
- **Two L2 announcers on one bridge.** The pools are disjoint; the VIP is in both clusters' Gateways but announced by
  one at a time — the takeover script applies one cluster's L2 policy and removes the other's, in that order, and
  the demo measures the ARP change from the MacBook (`arp -n`).
- **`.poc.local` inside the clusters.** The name is served by a CoreDNS `hosts` entry; the DNS proxy sees the answer,
  which is what `toFQDNs` needs. Checked in demo 38 before any policy.
- **A Gateway on poc2** needs the CRDs, the feature flag and a certificate — phase 0 exists for them.
- **Egress gateway on a fresh cluster** is a new install path; the phase measures it rather than assuming.
