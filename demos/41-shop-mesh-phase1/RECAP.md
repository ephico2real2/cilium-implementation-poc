# Demo 41 — the shop platform behind the doors, one URL, policies from the flows

This page puts the shop platform in both clusters behind demo 40's
doors. The manifest is byte-identical; the only per-cluster value is
ConfigMap `shop-cluster` (`data.name=poc1` / `poc2`). Every stateless
Service is a clustermesh global Service with affinity local (remote
backends known, local ones preferred while healthy). HTTPRoutes attach
`api-gateway` to every door. CiliumNetworkPolicies (Cilium's
per-endpoint allow list) are generated from observed Hubble flows, then
enforced. `/ready` and `/orders` answer 503 until phase 2
([enhancement 002](../../enhancements/002-shop-platform-clustermesh.md)
R3 — no database).

## What you get

- The same seven Deployments in both clusters: `api-gateway`,
  `catalog`, `orders`, `backend`, `payment-gateway`, `merchant`,
  `reviews` — `7/7` Available.
- Catalog under affinity local: `known=2 (clustermesh=1) selected=1
  local` on both clusters (`10.10.0.46` local on poc1,
  `10.20.0.135` local on poc2).
- One URL: `https://api.shop.poc.local` at `172.18.255.16` → `200` and
  `X-Served-By=poc1` (the door). `.242` → `poc1`; `.177` → `poc2`.
- `:80` with the hostname → `301`
  `Location=https://api.shop.poc.local:443/`.
- Seven generated policies per cluster (`7/7 exact names`,
  `managed-by=cf2cnp`); `8/8 policy-enabled,
  PolicyAuditMode=Disabled`.
- `/healthz` → `200`; `/ready` and `/orders` → `503` (R3).
- `check.sh` at `2026-09-18T14:32:18Z`: 33 PASS, 0 FAIL, 0 WARN.

## Architecture

A request from the Mac takes this path:

```text
                         MacBook
                         curl
                              │
                              │  https://api.shop.poc.local
                              ▼
                   172.18.255.16  shop-vip-gw
                   L2 announcement (poc1)
              ┌───────────────┴───────────────┐
              ▼                               ▼
           poc1                            poc2
      shop-gw 172.18.255.242         shop-gw 172.18.255.177
      shop-vip-gw (announces)        shop-vip-gw (present, silent)
              │                               │
              ▼                               ▼
         api-gateway                     api-gateway
              │                               │
         catalog  orders                 catalog  orders
         reviews  payment-gateway        reviews  payment-gateway
         backend                         backend
         X-Served-By: poc1               X-Served-By: poc2
              │
              └─ clustermesh: poc2's catalog
                 known, not selected while
                 poc1's is Active
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.shop.poc.local` | `172.18.255.16` | shared VIP door — `shop-vip-gw` in both clusters | poc1 (L2 announcement: one node answers ARP for the address, a lease per Service) |
| `api.poc1.shop.poc.local` | `172.18.255.242` | poc1's own door — `shop-gw` | poc1 |
| `api.poc2.shop.poc.local` | `172.18.255.177` | poc2's own door — `shop-gw` | poc2 |

The VIP address comes from the LB IPAM pool `shared-vip-pool`
(`.16–.31`). Each Gateway is Cilium's front-door object, listeners in
the node's shared Envoy. `X-Served-By` names the door the request
entered, not whether the pod behind `api-gateway` was local or remote.

## Prerequisites

- poc1 and poc2 up, [demo 40](../40-shop-mesh-phase0/README.md)
  applied: both doors, `shopapi:local` on the nodes, both `shopctl`s
  built. This phase does not build (gotcha #118).
- Pins from
  [`scripts/bootstrap/versions.env`](../../scripts/bootstrap/versions.env):
  kind `v0.33.0`, Cilium `1.20.2`.
- The hosts block (the script only prints it; the `tee` writes it).
  `probe.sh` needs the lines; `check.sh` pins the name and does not:

```bash
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
```

## Steps

Do these in order from the repo root (apply-both.sh records the
platform, the routes, the saved policies and the check; observe-and-enforce.sh
is how the saved set is regenerated):

### 1. Apply the platform

The manifest is the same in both clusters. ConfigMap `shop-cluster`
holds the cluster name for `backend`.

```bash
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/output/shop-cluster-poc1.yaml
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/10-platform.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/output/shop-cluster-poc2.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/10-platform.yaml
```

Result: every Deployment `condition met`; catalog ClusterIP
`10.11.58.134` (poc1) / `10.21.123.1` (poc2); annotations
`global=true affinity=local`; the selected backend is the local one.

```text
deployment.apps/api-gateway condition met
deployment.apps/catalog condition met
deployment.apps/backend condition met
-- kind-poc1 catalog ClusterIP=10.11.58.134
-- annotations global=true affinity=local
172   10.11.58.134:80/TCP       ClusterIP      1 => 10.10.0.46:80/TCP (active)
-- kind-poc2 catalog ClusterIP=10.21.123.1
95   10.21.123.1:80/TCP       ClusterIP      1 => 10.20.0.135:80/TCP (active)
```

### 2. Attach the HTTPRoutes

One file per cluster. `shop-api` parents both doors; a
`ResponseHeaderModifier` sets `X-Served-By`. `shop-redirect` is
`:80` → 301.

```bash
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/20-routes-poc1.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/20-routes-poc2.yaml
```

Result: both routes `Accepted+ResolvedRefs` on both doors; each door
answers `200` and names itself.

```text
kind-poc1 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-poc2 httproute/shop-api: all parents Accepted+ResolvedRefs
HTTP/2 200
x-served-by: poc1
x-served-by: poc2
```

### 3. Apply the saved policies

`apply-both.sh` lands demo 35's default-deny and the reviewed
`policies/<cluster>/cnp-shop-intent.yaml` so a fresh lab is enforcing
before anyone regenerates.

```bash
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/20-default-deny-ingress.yaml
kubectl --context kind-poc1 apply \
  -f demos/41-shop-mesh-phase1/policies/poc1/cnp-shop-intent.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/20-default-deny-ingress.yaml
kubectl --context kind-poc2 apply \
  -f demos/41-shop-mesh-phase1/policies/poc2/cnp-shop-intent.yaml
```

Result: `7/7 exact names` and `8/8 policy-enabled,
PolicyAuditMode=Disabled` on both clusters.

```text
  PASS   poc1 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc1 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
  PASS   poc2 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc2 shop endpoints enforce ingress policy                             8/8 policy-enabled, PolicyAuditMode=Disabled         every service endpoint and ratings enforces policy with audit disabled
```

### 4. Observe the flows

Audit mode on, default-deny on, then real traffic (the three doors and
the in-mesh shopper). `flows-both.sh` captures Hubble with
`--cluster <name>`.

```bash
demos/41-shop-mesh-phase1/audit-both.sh Enabled
demos/41-shop-mesh-phase1/flows-both.sh 400
```

Result: `policies/poc1/flows-audit.ndjson` 151 lines, all
`node_name` `poc1/…`; `policies/poc2/flows-audit.ndjson` 140 lines, all
`poc2/…` ([docs/REVIEW_DEMO41.md](../../docs/REVIEW_DEMO41.md)).

### 5. Generate the policies

One `/generate` per cluster (cf2cnp on poc1). Selectors carry no
cluster label: Cilium 1.19+ treats that as this cluster only, and
phase 1's flows stay inside their cluster.

```bash
demos/41-shop-mesh-phase1/generate-both.sh
```

Result: seven CiliumNetworkPolicies per cluster. api-gateway admits
`reserved:ingress` and shopper; the stranger is not in any selector.

### 6. Enforce the policies

Audit mode off on every shop endpoint.

```bash
demos/41-shop-mesh-phase1/audit-both.sh Disabled
```

Result: `8/8 policy-enabled, PolicyAuditMode=Disabled` on both
clusters; `/healthz` through the VIP stays `200` `X-Served-By=poc1`.

```text
  PASS   VIP /healthz still 200 after policies                                  http_code=200 X-Served-By=poc1                       probe /healthz is 200 with the header
```

### 7. Verify enforcement

`verify_enforcement` is the measurement: the stranger is not a catalog
caller; `api-gateway` is.

```bash
demos/41-shop-mesh-phase1/observe-and-enforce.sh
```

Result: stranger → catalog `wget: download timed out` (`rc=1`); Hubble
`DROPPED` / `FORWARDED` on both clusters.

```text
stranger -> catalog: expected failure rc=1 output=wget: download timed out
  DROPPED stranger -> catalog-5799bdf56f-qbv7m shop-core DROPPED
  FORWARDED api-gateway-c448767bb-sljk4 -> catalog-5799bdf56f-qsd4p FORWARDED
kind-poc1: DROPPED stranger->catalog and FORWARDED api-gateway->catalog observed
kind-poc2: DROPPED stranger->catalog and FORWARDED api-gateway->catalog observed
```

### 8. Run the checks

```bash
demos/41-shop-mesh-phase1/check.sh
```

Result: 33 PASS, 0 FAIL, 0 WARN (`2026-09-18T14:32:18Z`). The final
table from apply-both.sh:

```text
CLUSTER  DEPLOYMENTS    HTTPROUTES             VIP                          POC1_DOOR                    POC2_DOOR
poc1     7/7            2/2 accepted, 2/2 resolved 200 X-Served-By=poc1         200 X-Served-By=poc1         200 X-Served-By=poc2
poc2     7/7            2/2 accepted, 2/2 resolved 200 X-Served-By=poc1         200 X-Served-By=poc1         200 X-Served-By=poc2
```

## Verify

From the Mac:

```bash
curl -sk --resolve api.shop.poc.local:443:172.18.255.16 \
  https://api.shop.poc.local/ -D - -o /dev/null
```

Expect `200` and `x-served-by: poc1`.

```bash
curl -sk --resolve api.poc2.shop.poc.local:443:172.18.255.177 \
  https://api.poc2.shop.poc.local/ -D - -o /dev/null
```

Expect `200` and `x-served-by: poc2`.

```bash
demos/41-shop-mesh-phase1/check.sh
```

Recorded `2026-09-18T14:32:18Z`: 33 PASS, 0 FAIL, 0 WARN.

```text
== demo 41 — the shop platform on the mesh, phase 1 (the platform behind the doors)
  PASS   VIP https://api.shop.poc.local @ 172.18.255.16                         http_code=200 X-Served-By=poc1 announcer=poc1        200 and X-Served-By equals vip-takeover.sh --status
  PASS   https://api.poc1.shop.poc.local @ 172.18.255.242                       http_code=200 X-Served-By=poc1                       200 and X-Served-By=poc1
  PASS   https://api.poc2.shop.poc.local @ 172.18.255.177                       http_code=200 X-Served-By=poc2                       200 and X-Served-By=poc2
  PASS   poc1 catalog backends under affinity:local                             known=2 (clustermesh=1) selected=1 local             affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)
  PASS   poc2 catalog backends under affinity:local                             known=2 (clustermesh=1) selected=1 local             affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)
  PASS   poc1 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   poc2 has exactly the seven generated shop policies                     7/7 exact names                                      exact generated policy inventory, managed-by=cf2cnp
  PASS   VIP /healthz still 200 after policies                                  http_code=200 X-Served-By=poc1                       probe /healthz is 200 with the header
```

## Reference

Addresses ([enhancement 002 §8.1](../../enhancements/002-shop-platform-clustermesh.md)):

| Address | Name | Door |
|---|---|---|
| `172.18.255.16` | `api.shop.poc.local` | `shop-vip-gw` (shared VIP; announced by one cluster) |
| `172.18.255.242` | `api.poc1.shop.poc.local` | poc1 `shop-gw` |
| `172.18.255.177` | `api.poc2.shop.poc.local` | poc2 `shop-gw` |

Catalog backends (statedb + BPF map, [docs/REVIEW_DEMO41.md](../../docs/REVIEW_DEMO41.md)):
poc1 statedb holds `10.10.0.46` (`k8s`) and `10.20.0.135`
(`clustermesh`); `bpf lb` for `10.11.58.134:80` selects
`10.10.0.46`. poc2 is the mirror (`10.21.123.1:80` → `10.20.0.135`).
Cilium `pkg/clustermesh/selectbackends.go` sets
`useRemote = localActiveBackends == 0`.

Generated policies (same descriptions on both clusters):

| Namespace | Name | Admits |
|---|---|---|
| `shop-edge` | `api-gateway` | shopper on TCP/80; `reserved:ingress` on TCP/80 |
| `shop-core` | `backend` | orders, api-gateway on TCP/8080 |
| `shop-core` | `catalog` | orders, api-gateway, merchant, reviews on TCP/80 |
| `shop-core` | `orders` | api-gateway on TCP/80 |
| `shop-payments` | `payment-gateway` | orders, api-gateway on TCP/80 |
| `shop-reviews` | `reviews` | api-gateway, ratings on TCP/80 |
| `shop-merchant` | `merchant` | payment-gateway on TCP/80 |

| File | What |
|---|---|
| [`10-platform.yaml`](10-platform.yaml) | namespaces, Deployments, global Services, `backend` |
| [`20-routes-poc1.yaml`](20-routes-poc1.yaml) / [`20-routes-poc2.yaml`](20-routes-poc2.yaml) | HTTPRoute on both doors, `X-Served-By`, `:80` → 301 |
| [`20-default-deny-ingress.yaml`](20-default-deny-ingress.yaml) | demo 35's default-deny |
| [`policies/poc1/`](policies/poc1/) / [`policies/poc2/`](policies/poc2/) | generated CNPs and the AUDIT flows |
| [`apply-both.sh`](apply-both.sh) / [`observe-and-enforce.sh`](observe-and-enforce.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, regenerate, prove, remove |

Resources vs the plan's §8 baseline (17.0 GiB, ~1.1 cores): four nodes
sum `1007m` CPU / `19395` Mi (~18.9 GiB); the four kind-node containers
summed to `18.894` GiB (+1.9 GiB, CPU around one core).

## Troubleshooting

- `probe.sh` exits non-zero: it talks to the URL without pinning the
  address, so a stale hosts line misses the live VIP — compare with
  the printed hosts block under *Prerequisites*; `check.sh` does not
  depend on hosts.
- Shopper → catalog ClusterIP times out (`wget: download timed out`):
  shopper is not a catalog caller; it goes through `api-gateway`.
- `/ready` and `/orders` are 503: there is no database until phase 2
  (R3).

## Clean up

```bash
demos/41-shop-mesh-phase1/cleanup.sh
```

Removes the HTTPRoutes, the generated policies, and the platform.
Demo 40's doors stay (`shop-gw`, `shop-vip-gw`, `shop-tls`,
`shop-vip-announce`, `shared-vip-pool`, namespace `shop-edge`).

## What's next

- Demo 42 gives the shop its database: PostgreSQL in poc1 only,
  published on a Gateway with a TCPRoute as `db-service.poc.local`
  ([enhancement 002](../../enhancements/002-shop-platform-clustermesh.md)
  R3).
- Then `/ready` and `/orders` through the public URL become 200, and
  the backend's policy is regenerated as `toFQDNs`.
- Phase 5 scenario S2 scales catalog to 0 in one cluster and watches
  affinity fail over.
