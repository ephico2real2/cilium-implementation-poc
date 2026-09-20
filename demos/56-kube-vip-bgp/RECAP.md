# Demo 56 — kube-vip in BGP mode, doors on the routed block

This page migrates `eg-poc1` from L2 kube-vip (demo 54) to BGP. kube-vip
(a DaemonSet that peers with the fabric) advertises the Envoy Gateway
doors as `/32`s in `10.98.0.0/26`. `client0` behind the edge reaches them
through the fabric. Demo 54's doors at `.100` / `.101` stop answering
when the active-active setting lands; cleanup restores L2.

## What you get

- kube-vip AS **65021** peers with both leaves; `SERVERS Established on
  both leaves after 3s`; check.sh later reads `4/4 Established`.
- Election first (received-routes for `.10` and `.11` from
  `172.19.0.3` only), then active-active (`leaf1 node_paths=2` while
  ETP is still Local); the spine holds two nexthops (`10.200.1.10`,
  `10.200.1.2`).
- Doors `bgp-http-gw` at `10.98.0.10` and `bgp-grpc-gw` at
  `10.98.0.11`; `externalTrafficPolicy: Cluster` after Local.
- From `client0`: HTTP `200` and `X-Served-By: eg-poc1`; the gRPC
  matrix, `14` PASS (`gRPC matrix: 0 FAIL`).
- Failure A: `withdrawal_s=0 ok=12 fail=0 recovery_s=2`. Failure B:
  `bgp_withdraw_s=13 node_notready_s=51 first_ok_after_s=none
  post_notready ok=0 fail=4 recovery_s=7
  eg_controller_node=eg-poc1-worker` — BGP withdrew at 13 s; the node
  went `Ready=Unknown` at 51 s (the 50 s default grace period,
  measured); the shopapi endpoint was pruned; and not one of the four
  probes after that succeeded, because the envoy-gateway controller's
  single replica was on the paused node — the surviving Envoy never
  learned of the pruned endpoint; the door came back 7 s after
  unpause.
- `check.sh` at `2026-09-20T06:19:04Z`: 16 PASS, 0 FAIL. Demo 54's
  `.100` is silent (`replies=0`) until cleanup restores
  [`clusters/eg/kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml).

## Architecture

The fabric with both Envoy Gateway clusters. eg-poc1 is solid (both
nodes dial both leaves; doors `.10` / `.11`); eg-poc2 is dashed (demo
57). From [enhancement 006 §9.0](../../enhancements/006-bgp-tutorial.md):

```text
 MacBook
 curl / grpcurl / browser
 route 10.98.0.0/24 → 192.168.64.2     (optional, D18 — not recorded)
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
        |   172.19.0.2 ── both leaves   - MetalLB FRR-K8s (57) -
        |   172.19.0.3 ── both leaves   - 172.19.0.4 / .5     -
        |   10.98.0.10 / .11            - 10.98.0.74 / .75    -
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.eg-poc1.poc.local` | `10.98.0.10` | HTTP door on the routed block | both nodes (ECMP) |
| `grpc.eg-poc1.poc.local` | `10.98.0.11` | gRPC door on the routed block | both nodes (ECMP) |
| `http-gw` (demo 54) | `172.19.255.100` | L2 door — same hostnames | unannounced after 10b |
| `grpc-gw` (demo 54) | `172.19.255.101` | L2 door | unannounced after 10b |

kube-vip cannot keep the L2 doors announced while running
active-active BGP (`vip_arp=false`). The speaker sends no MD5 (sheet
row 3: this VM's kernel refuses `TCP_MD5SIG`).

## Prerequisites

- Demo 46 applied (leaves healthy at `172.19.254.11` / `.12` on
  `kind-eg`).
- Demo 54 applied (`http-gw` / `grpc-gw` Programmed at `.100` / `.101`).
- Image `grpcdemo:local` already on the VM (kind load, not a build).
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  kube-vip `v1.2.4`, FRR `10.5.3`, netshoot `v0.16`.
- The Mac route was absent (`Mac route absent — the client0 half is
  the record`). apply.sh prints the two lines and does not add the Mac
  route:

```bash
demos/46-bgp-fabric/apply.sh
demos/54-eg-poc1-kube-vip/apply.sh
scripts/fabric-vm-route.sh --apply
```

```text
VM:  docker run --rm --privileged --pid=host --net=host alpine:3.20 nsenter -t 1 -m -n -- ip route replace 10.98.0.0/24 via 172.19.254.11
Mac: sudo route -n add -net 10.98.0.0/24 192.168.64.2
Mac route absent — the client0 half is the record
```

## Steps

Do these in order from the repo root (apply.sh records them):

### 1. Start from demo 54

The BEFORE state: ARP on `.100`, no SERVERS peers.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
```

Result: 3/3 from `fa:1f:d6:0f:1e:ae`; `leaf1 SERVERS_peers=0` and
`leaf2 SERVERS_peers=0`.

```text
Received 3 response(s) (0 request(s), 0 broadcast(s))
leaf1 SERVERS_peers=0
leaf2 SERVERS_peers=0
```

### 2. Switch kube-vip to BGP with the election on

Apply [`10a-kube-vip-ds-bgp-election.yaml`](10a-kube-vip-ds-bgp-election.yaml)
(`vip_arp=false`, `svc_election=true`). Only the leader advertises.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10a-kube-vip-ds-bgp-election.yaml
```

Result: Established on both leaves after 3 s; the worker
(`172.19.0.3`) advertised `.10` and `.11`.

```text
SERVERS Established on both leaves after 3s
 *> 10.98.0.10/32    172.19.0.3                             0 65021 i
 *> 10.98.0.11/32    172.19.0.3                             0 65021 i
```

### 3. Create the BGP doors and the app

Apply the ETP Local doors, grpcdemo, shopapi HA and the routes. Nobody
ARPs for a routed address.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20a-gateways-bgp-etp-local.yaml \
  -f demos/56-kube-vip-bgp/40-grpcdemo.yaml \
  -f demos/56-kube-vip-bgp/41-shopapi-ha.yaml \
  -f demos/56-kube-vip-bgp/50-routes-bgp.yaml
```

Result: both Gateways Programmed; shopapi rolled out on two nodes;
routes Accepted; `Received 0 response(s)` for `10.98.0.10`.

```text
gateway.gateway.networking.k8s.io/bgp-http-gw condition met
gateway.gateway.networking.k8s.io/bgp-grpc-gw condition met
Waiting for deployment "shopapi" rollout to finish: 1 out of 2 new replicas have been updated...
deployment "shopapi" successfully rolled out
kind-eg-poc1 httproute/shop-api-bgp: all parents Accepted+ResolvedRefs
kind-eg-poc1 grpcroute/orders-bgp: all parents Accepted+ResolvedRefs
bgp-http-gw nodes: eg-poc1-worker eg-poc1-control-plane unique=2
shopapi nodes: eg-poc1-control-plane eg-poc1-worker unique=2
Received 0 response(s) (0 request(s), 0 broadcast(s))
```

### 4. Reach the door from the outside world

`client0` (netshoot, `10.200.100.10`) is the outside world. The path is
edge → spine → leaf → node.

```bash
docker exec bgp-fabric-client0-1 \
  curl --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  http://api.eg-poc1.poc.local/healthz
docker exec bgp-fabric-client0-1 \
  tcptraceroute -n -m 8 10.98.0.10 80
```

Result: `200` and `X-Served-By: eg-poc1`; five hops, the door `[open]`.

```text
http://api.eg-poc1.poc.local/healthz @ 10.98.0.10:80 → 200 X-Served-By=eg-poc1 curl_rc=0
10.98.0.10 via 10.200.100.2 dev eth0 src 10.200.100.10 uid 0
 1  10.200.100.2  0.105 ms  0.010 ms  0.064 ms
 2  10.200.1.18  0.120 ms  0.097 ms  0.105 ms
 3  10.200.1.10  0.288 ms  0.117 ms  0.092 ms
 4  10.98.0.10  0.175 ms  0.151 ms  0.133 ms
 5  10.98.0.10 [open]  0.120 ms  0.147 ms  0.143 ms
```

### 5. Switch to active-active

Apply [`10b-kube-vip-ds-bgp-active-active.yaml`](10b-kube-vip-ds-bgp-active-active.yaml)
(`vip_arp=false`, `svc_election=false`). Demo 54's doors stop answering.
One leaf may keep a third path — the door bounced back from the spine,
on whichever leaf the spine did not pick as best (recorded on leaf1 as
`65100 65102 65021`); judges count node paths only (nexthop in
`172.19.0.0/17`).

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10b-kube-vip-ds-bgp-active-active.yaml
```

Result: `leaf1 node_paths=2` while ETP is still Local; the spine's two
nexthops are `10.200.1.10` (leaf2) and `10.200.1.2` (leaf1).

```text
leaf1 node_paths=2 (want >= 1 nodes) after 3s
10.98.0.10 nhid 27 proto bgp metric 20
```

### 6. Measure ETP Local then Cluster

Forty curls from `client0` under Local, then
[`20-gateways-bgp.yaml`](20-gateways-bgp.yaml)
(`externalTrafficPolicy: Cluster`) and the same loop.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20-gateways-bgp.yaml
```

Result: both loops `ok=40 fail=0`; `x-pod` names both shopapi pods;
`leaf1 node_paths=2` after Cluster.

```text
leaf1 node_paths=2 (want >= 2 nodes) after 1s
final ETP=Cluster
eg-poc1-control-plane 24
eg-poc1-worker 23
eg-poc1-control-plane 25
eg-poc1-worker 15
```

### 7. Run the gRPC matrix from client0

Demo 52's 14 tests, hostname `grpc.eg-poc1.poc.local`, CA copied into
`client0`. T12 isolates against `10.98.0.10`.

```bash
docker exec bgp-fabric-client0-1 grpcurl --version
```

Result: the recorded summary table, 14 PASS.

```text
==== gRPC matrix summary ====
TEST EXPECTED                                         OBSERVED                     RESULT
T1   four RPCs via reflection                         ListOrders GetOrder WatchOrders SlowOrder PASS
T2   3 orders version v1 served_by grpcdemo-v1-       v1 + three rows              PASS
T3   TLS ListOrders v1                                v1 rc=0                      PASS
T4   GetOrder id=2 version v2                         v2                           PASS
T5   x-version v2 then default v1                     v2 then v1                   PASS
T6   5 streamed events                                events=5                     PASS
T7   Code: NotFound                                   NotFound                     PASS
T8a  Code: Unimplemented + unknown method             Unimplemented unknown method PASS
T8b  Code: Unimplemented + empty Message              Unimplemented empty Message  PASS
T9   Code: DeadlineExceeded                           DeadlineExceeded             PASS
T10  metadata x-served-by + x-version                 both present                 PASS
T11  TLS fails with bogus CA                          Failed to dial target host "10.98.0.11:443": tls: failed to verify certificate:  rc=1 PASS
T12  grpc@.10 not served; curl@.11 → 404            grpcurl_rc=1 http=404        PASS
T13  {"status": "SERVING"} for "" and shop.v1.Orders  SERVING SERVING              PASS
gRPC matrix: 0 FAIL
```

### 8. Break it two ways

(A) delete the worker's kube-vip pod — the DaemonSet restarts it.
(B) pause the worker for 75 s. BGP withdrew at 13 s; the node went
`Ready=Unknown` at 51 s (the 50 s default grace period, measured); the
shopapi endpoint was pruned; and not one of the four probes after that
succeeded, because the envoy-gateway controller's single replica was
on the paused node — the surviving Envoy never learned of the pruned
endpoint; the door came back 7 s after unpause. A silent node needs
BGP, the grace period AND a live control plane for the door.

```bash
kubectl --context kind-eg-poc1 -n kube-system delete pod \
  "$(kubectl --context kind-eg-poc1 -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds \
    --field-selector spec.nodeName=eg-poc1-worker \
    -o jsonpath='{.items[0].metadata.name}')"
docker pause eg-poc1-worker
```

Result: A `withdrawal_s=0 ok=12 fail=0 recovery_s=2`; B
`bgp_withdraw_s=13 node_notready_s=51 first_ok_after_s=none
post_notready ok=0 fail=4 recovery_s=7
eg_controller_node=eg-poc1-worker`.

```text
A summary: withdrawal_s=0 ok=12 fail=0 recovery_s=2
t+13s code=200 rc=0 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=True lastTransitionTime=2026-09-20T05:25:45Z ready_eps=2 door_eps=2
t+51s code=000 rc=28 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=Unknown lastTransitionTime=2026-09-20T06:17:30Z ready_eps=1 door_eps=1
t+74s code=000 rc=28 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=Unknown lastTransitionTime=2026-09-20T06:17:30Z ready_eps=1 door_eps=1
B summary: bgp_withdraw_s=13 node_notready_s=51 first_ok_after_s=none post_notready ok=0 fail=4 recovery_s=7 eg_controller_node=eg-poc1-worker
```

## Verify

```bash
demos/56-kube-vip-bgp/check.sh
```

Result: 16 PASS, `demo 56 check: 0 FAIL`.

```text
  PASS   kube-vip DS ready with BGP env                                         ready=2/2 bgp_enable=true bgp_as=65021               10b — ready N/N, bgp_enable=true, bgp_as=65021
  PASS   4 SERVERS sessions Established                                         4/4 Established (172.19.0.2 172.19.0.3)              both nodes × both leaves — JSON state == Established
  PASS   leaf1 2 node paths for 10.98.0.10/32 (both nodes)                      node_paths=2                                         active-active — both nodes advertise to each leaf
  PASS   leaf1 2 node paths for 10.98.0.11/32 (both nodes)                      node_paths=2                                         active-active — both nodes advertise to each leaf
  PASS   bgp-http-gw class + ingress + ETP Cluster                              class=kube-vip.io/kube-vip-class ingress=10.98.0.10 etp=Cluster D11 — class kube-vip, ingress=10.98.0.10, ETP Cluster
  PASS   bgp-grpc-gw class + ingress + ETP Cluster                              class=kube-vip.io/kube-vip-class ingress=10.98.0.11 etp=Cluster D11 — class kube-vip, ingress=10.98.0.11, ETP Cluster
  PASS   Envoy replicas spread: one per node                                    bgp-http-gw ready=2 nodes=eg-poc1-control-plane,eg-poc1-worker 2 ready Envoy pods, distinct nodeName
  PASS   Envoy replicas spread: one per node                                    bgp-grpc-gw ready=2 nodes=eg-poc1-control-plane,eg-poc1-worker 2 ready Envoy pods, distinct nodeName
  PASS   shopapi replicas spread + rollout complete                             ready=2 updated=2/2 nodes=eg-poc1-control-plane,eg-poc1-worker 2 ready shopapi pods, distinct nodeName, updated == replicas == spec
  PASS   client0 http://api.eg-poc1.poc.local 200 + X-Served-By                 http_code=200 X-Served-By=eg-poc1                    R8 — 200 and X-Served-By=eg-poc1 from client0
  PASS   client0 ListOrders v1                                                  v1 + three rows                                      demo 52 T2 — 3 orders version v1 served_by grpcdemo-v1-
  PASS   client0 GetOrder v2                                                    v2                                                   demo 52 T4 — GetOrder id=2 version v2 served_by grpcdemo-v2-
  PASS   client0 x-version v2                                                   v2                                                   demo 52 T5 — x-version v2 → version v2 served_by grpcdemo-v2-
  PASS   arping routed door 10.98.0.10 → 0 replies                            replies=0                                            routed door — nobody ARPs for a routed address / L2 door unannounced
  PASS   arping demo 54 L2 door 172.19.255.100 → 0 replies                    replies=0                                            demo 54 L2 door — nobody ARPs for a routed address / L2 door unannounced
  PASS   SERVERS-IN seq 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0         seq10_invoked=90                                     sheet row 4 — EG-POC1-VIPS 10.98.0.0/26 ge 32 le 32 + as-path ^65021$
demo 56 check: 0 FAIL
```

## Reference

| env | 10a (election) | 10b (active-active) |
|---|---|---|
| `vip_arp` | `false` | `false` |
| `svc_election` | `true` | `false` |
| `vip_leaderelection` | `true` | `false` |
| `bgp_enable` | `true` | `true` |
| `bgp_as` | `65021` | `65021` |
| `bgp_peers` | `172.19.254.11:65101::false,172.19.254.12:65102::false` | same (no password) |

| Door | Address | class | pin | ETP (final) | Envoy |
|---|---|---|---|---|---|
| `bgp-http-gw` | `10.98.0.10` | `kube-vip.io/kube-vip-class` | `kube-vip.io/loadbalancerIPs` | Cluster | replicas 2 + anti-affinity |
| `bgp-grpc-gw` | `10.98.0.11` | `kube-vip.io/kube-vip-class` | `kube-vip.io/loadbalancerIPs` | Cluster | replicas 2 + anti-affinity |

[`41-shopapi-ha.yaml`](41-shopapi-ha.yaml): replicas 2, required
anti-affinity on `app: shopapi`, `maxSurge: 0` / `maxUnavailable: 1`.
Certificate: Secret `eg-poc1-tls`
from demo 54 (unchanged). Probe descriptors:
[`demos/52-eg-poc2-metallb/probe/`](../52-eg-poc2-metallb/probe/).
Sheet: [NETWORK-TEAM-SHEET.md](../46-bgp-fabric/NETWORK-TEAM-SHEET.md)
Envoy lab rows — eg-poc1 ASN **65021**, block `10.98.0.0/26`, doors
`.10` / `.11`, peers `172.19.254.11` / `.12`, no password on this
kernel.

GRPCRoute rules ([`50-routes-bgp.yaml`](50-routes-bgp.yaml), most
specific first):

| Match | Backend |
|---|---|
| `shop.v1.Orders` + header `x-version: v2` | `grpc-v2:9090` |
| `shop.v1.Orders` / `GetOrder` | `grpc-v2:9090` |
| `shop.v1.Orders` (service default) | `grpc-v1:9090` |
| `grpc.health.v1.Health` | `grpc-v1:9090` |
| `grpc.reflection.v1alpha.ServerReflection` | `grpc-v1:9090` |
| `grpc.reflection.v1.ServerReflection` | `grpc-v1:9090` |

```bash
docker exec bgp-fabric-client0-1 \
  curl --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  http://api.eg-poc1.poc.local/healthz
docker exec bgp-fabric-client0-1 grpcurl -plaintext \
  -authority grpc.eg-poc1.poc.local \
  10.98.0.11:80 shop.v1.Orders/ListOrders
docker exec bgp-fabric-client0-1 grpcurl -plaintext \
  -authority grpc.eg-poc1.poc.local \
  -d '{"id":2}' 10.98.0.11:80 shop.v1.Orders/GetOrder
docker exec bgp-fabric-client0-1 grpcurl -plaintext \
  -authority grpc.eg-poc1.poc.local \
  -H 'x-version: v2' 10.98.0.11:80 shop.v1.Orders/ListOrders
```

## Troubleshooting

- A SERVERS session stuck `ACTIVE` → a password in `bgp_peers` on this
  kernel (gobgp sets `TCP_MD5SIG`; the VM refuses it).
- A door with one path after 10b → `svc_election` or
  `vip_leaderelection` still true.
- A paused node and a dead door → one replica per node, plus
  Kubernetes' node grace period (B: withdraw 13 s, `Ready=Unknown` at
  51 s) and a live envoy-gateway controller.

## Clean up

```bash
demos/56-kube-vip-bgp/cleanup.sh
```

The fabric stays. Demo 54's doors answer ARP again.

## What's next

- Demo 57 — MetalLB FRR-K8s BGP on `eg-poc2` (the same fabric,
  `10.98.0.64/26`).
- The dashboard (D17 phase 2) reads the routers over the fabric.
- Demos 47–49 — Cilium on the same fabric (`kind` overlay).
