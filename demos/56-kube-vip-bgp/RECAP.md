# Demo 56 — kube-vip in BGP mode, doors on the routed block

This page migrates `eg-poc1` from L2 kube-vip (demo 54) to BGP. kube-vip
(a DaemonSet that peers with the fabric) advertises the Envoy Gateway
doors as `/32`s in `10.98.0.0/26`. `client0` behind the edge reaches them
through the fabric. Demo 54's doors at `.100` / `.101` stop answering
when the active-active setting lands; cleanup restores L2.

## What you get

- kube-vip AS **65021** peers with both leaves (`172.19.254.11` /
  `.12`); four sessions `"state":"Established"`.
- Election first (one path on the spine), then active-active (two
  paths, two nexthops — ECMP).
- Doors `bgp-http-gw` at `10.98.0.10` and `bgp-grpc-gw` at
  `10.98.0.11`; `externalTrafficPolicy: Cluster` after the Local
  experiment.
- From `client0`: HTTP `200` and `X-Served-By: eg-poc1`; the gRPC
  matrix (14 tests, hostname `grpc.eg-poc1.poc.local`).
- `arping` of `10.98.0.10` gets 0 replies. Demo 54's `.100` is silent
  until cleanup reapplies [`clusters/eg/kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml).
- <!-- recorded after apply -->

## Architecture

The fabric with both Envoy Gateway clusters. eg-poc1 is solid; eg-poc2
is dashed (demo 57, not this run). From
[enhancement 006 §9.0](../../enhancements/006-bgp-tutorial.md):

```text
 MacBook
 curl / grpcurl / browser
 route 10.98.0.0/24 → 192.168.64.2     (optional, D18)
        |
        v
 Docker VM 192.168.64.2
 VM route 10.98.0.0/24 via leaf1 172.19.254.11
        |
        |                      company fabric (demo 46)
        |   client0 10.200.100.10
        |      |  wan 10.200.100.0/24
        |      v
        |   edge  AS 65000   lo 10.200.255.1
        |      |  10.200.1.16/29
        |      v
        |   spine AS 65100   lo 10.200.255.2
        |     / \  10.200.1.0/29            10.200.1.8/29
        |    /   \
        |   v     v
        | leaf1 AS 65101                leaf2 AS 65102
        | lo 10.200.255.11              lo 10.200.255.12
        | kind-eg 172.19.254.11         kind-eg 172.19.254.12
        |        \                     /
        |         \   kind-eg 172.19.0.0/16
        |          v                   v
        |   eg-poc1 AS 65021            - - eg-poc2 AS 65022 - -
        |   kube-vip BGP (this demo)    - MetalLB FRR-K8s (57) -
        |   172.19.0.2 / .3             - 172.19.0.4 / .5     -
        |   10.98.0.10 / .11            - 10.98.0.74 / .75    -
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.eg-poc1.poc.local` | `10.98.0.10` | HTTP door on the routed block | both nodes (ECMP) |
| `grpc.eg-poc1.poc.local` | `10.98.0.11` | gRPC door on the routed block | both nodes (ECMP) |
| `http-gw` (demo 54) | `172.19.255.100` | L2 door — same hostnames | unannounced after 10b |
| `grpc-gw` (demo 54) | `172.19.255.101` | L2 door | unannounced after 10b |

kube-vip cannot keep the L2 doors announced while running
active-active BGP (`vip_arp=false`). The password in `bgp_peers` is the
fabric's password on the router side only — the speaker sends none (sheet row 3: this
VM's kernel refuses `TCP_MD5SIG`; gobgp aborts a connection it cannot sign, FRR continues unsigned).

## Prerequisites

- Demo 46 applied (leaves healthy at `172.19.254.11` / `.12` on
  `kind-eg`).
- Demo 54 applied (`http-gw` / `grpc-gw` Programmed at `.100` / `.101`).
- Image `grpcdemo:local` already on the VM (kind load, not a build).
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  kube-vip `v1.2.4`, FRR `10.5.3`, netshoot `v0.16`.

```bash
demos/46-bgp-fabric/apply.sh
demos/54-eg-poc1-kube-vip/apply.sh
```

## Steps

Do these in order from the repo root (apply.sh records them):

### 1. Record the L2 baseline

Demo 54's ARP and the leaves' SERVERS table before any BGP peer exists.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
```

Result: <!-- recorded after apply -->

### 2. Switch kube-vip to BGP with election on

Apply [`10a-kube-vip-ds-bgp-election.yaml`](10a-kube-vip-ds-bgp-election.yaml)
(`vip_arp=false` — kube-vip refuses two modes at once — and `svc_election=true`). Only the leader advertises.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10a-kube-vip-ds-bgp-election.yaml
```

Result: <!-- recorded after apply -->

### 3. Create the BGP doors with ETP Local

Apply [`20a-gateways-bgp-etp-local.yaml`](20a-gateways-bgp-etp-local.yaml),
grpcdemo, [`41-shopapi-ha.yaml`](41-shopapi-ha.yaml) (2 replicas, one
per node) and the routes. The spine holds one path. Nobody ARPs for a
routed address.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20a-gateways-bgp-etp-local.yaml \
  -f demos/56-kube-vip-bgp/40-grpcdemo.yaml \
  -f demos/56-kube-vip-bgp/41-shopapi-ha.yaml \
  -f demos/56-kube-vip-bgp/50-routes-bgp.yaml
```

Result: <!-- recorded after apply -->

### 4. Curl the routed door from client0

`client0` (netshoot, `10.200.100.10`) is the outside world.

```bash
docker exec bgp-fabric-client0-1 \
  curl --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  http://api.eg-poc1.poc.local/healthz
```

Result: <!-- recorded after apply -->

### 5. Switch kube-vip to active-active

Apply [`10b-kube-vip-ds-bgp-active-active.yaml`](10b-kube-vip-ds-bgp-active-active.yaml)
(`vip_arp=false`, `svc_election=false`). Demo 54's doors stop answering.
leaf1 may hold a third path from the spine; judges count node paths
only (nexthop in `172.19.0.0/17`).

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10b-kube-vip-ds-bgp-active-active.yaml
```

Result: <!-- recorded after apply -->

### 6. Measure ETP Local then set Cluster

Forty curls from `client0` under Local (drops on the node without the
Envoy pod), then [`20-gateways-bgp.yaml`](20-gateways-bgp.yaml)
(`externalTrafficPolicy: Cluster`) and the same loop.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20-gateways-bgp.yaml
```

Result: <!-- recorded after apply -->

### 7. Run the gRPC matrix from client0

Demo 52's 14 tests, hostname `grpc.eg-poc1.poc.local`, CA copied into
`client0`. T12 isolates against `10.98.0.10`. The function returns the
FAIL count; apply exits 1 at the end if any.

```bash
docker exec bgp-fabric-client0-1 grpcurl --version
```

Result: <!-- recorded after apply -->

### 8. Try the Mac path

The VM route is applied; the Mac `sudo` line is printed, never run.

```bash
scripts/fabric-vm-route.sh --apply
```

Result: <!-- recorded after apply -->

### 9. Measure BGP-only failure then a silent node

Two scenarios, in this order. (A) delete the worker's kube-vip pod —
the DaemonSet restarts it. leaf1's node-path count goes 2 → 1 within a
second or two (TCP close → NOTIFICATION, no hold time). `client0`'s
2.5 s loop for 30 s expects ~0 failures (ECMP to the control-plane);
the path returns when the pod is Running. (B) pause the worker for
75 s. BGP withdraws at ≤ 9 s (hold time; the dynamic peer goes
`ABSENT`); the node goes NotReady at ≈ 40 s; the shopapi endpoints
drop; 200s resume. BGP fixes the path in seconds; the cluster's own
endpoints take Kubernetes' node grace period — a silent node needs
BOTH, and a real deployment tunes `node-monitor-grace-period` /
readiness probes.

```bash
kubectl --context kind-eg-poc1 -n kube-system delete pod \
  "$(kubectl --context kind-eg-poc1 -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds \
    --field-selector spec.nodeName=eg-poc1-worker \
    -o jsonpath='{.items[0].metadata.name}')"
docker pause eg-poc1-worker
```

Result: <!-- recorded after apply -->

### 10. Print the final table

Door, address, paths on the spine, nodes advertising, client0
http/grpc.

```bash
demos/56-kube-vip-bgp/hosts-entries.sh
```

Result: <!-- recorded after apply -->

## Verify

```bash
demos/56-kube-vip-bgp/check.sh
```

Result: <!-- recorded after apply -->

## Reference

| Item | Value |
|---|---|
| Cluster ASN | 65021 |
| Peers | `172.19.254.11:65101::false`, `172.19.254.12:65102::false` (no password — measured: with one, gobgp never leaves ACTIVE on this kernel) |
| Password | one per fabric (`FABRIC_BGP_PASSWORD=lab-bgp` in [`fabric/.env`](../46-bgp-fabric/fabric/.env); inline in `bgp_peers`) |
| HTTP door | `10.98.0.10` — class `kube-vip.io/kube-vip-class`, ETP Cluster |
| gRPC door | `10.98.0.11` — same class, ETP Cluster |
| Envoy HA | `envoyDeployment.replicas: 2` + required anti-affinity on `gateway.envoyproxy.io/owning-gateway-name` / `kubernetes.io/hostname` |
| shopapi HA | [`41-shopapi-ha.yaml`](41-shopapi-ha.yaml) — 2 replicas, required anti-affinity on `app: shopapi` |
| Certificate | Secret `eg-poc1-tls` from demo 54 (unchanged) |
| Probe descriptors | [`demos/52-eg-poc2-metallb/probe/`](../52-eg-poc2-metallb/probe/) |
| Sheet | [`NETWORK-TEAM-SHEET.md`](../46-bgp-fabric/NETWORK-TEAM-SHEET.md) Envoy lab rows |
| leaf1 third path | `10.98.0.10/32` nexthops `172.19.0.2`, `172.19.0.3`, and `10.200.1.3` (the door's own prefix learned from the spine via leaf2, AS path `65100 65102 65021`); the leaf keeps it and never prefers it while a direct node path exists |

```bash
docker compose -p bgp-fabric exec -T leaf1 vtysh -c 'show ip bgp 10.98.0.10/32'
```

```text
<!-- recorded after apply -->
```

## Troubleshooting

- Fabric not up → apply exits 1 and names the
  [demo 46 apply](../46-bgp-fabric/apply.sh).
- No `10.98` route on the Mac → apply prints the sudo line and records
  "Mac route absent — the client0 half is the record".
- Demo 54 doors silent after this run → expected; cleanup restores
  [the L2 kube-vip DaemonSet](../../clusters/eg/kube-vip-ds.yaml).

## Clean up

```bash
demos/56-kube-vip-bgp/cleanup.sh
```

The fabric stays. Demo 54's doors answer ARP again (three replies from
one MAC on `.100`).

## What's next

- Demo 57 — MetalLB FRR-K8s BGP on `eg-poc2` (`10.98.0.64/26`).
- Demos 47–49 — Cilium on the same fabric (`kind` overlay).
- [Enhancement 006 §9](../../enhancements/006-bgp-tutorial.md) — the
  attachable fabric.
- [NETWORK-TEAM-SHEET.md](../46-bgp-fabric/NETWORK-TEAM-SHEET.md) — the
  hand-off.
