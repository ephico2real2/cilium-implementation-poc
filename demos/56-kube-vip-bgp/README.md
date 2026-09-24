# Demo 56 — kube-vip in BGP mode on eg-poc1

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

This demo migrates `eg-poc1` from L2 kube-vip (demo 54) to BGP. kube-vip
peers with the fabric (demo 46) as AS 65021. Envoy Gateway doors land on
the routed block (`10.98.0.10` / `.11`). The gRPC matrix from demo 52
runs from `client0`. Demo 54's doors (`.100` / `.101`) stop answering
when active-active is on; cleanup restores
[`clusters/eg/kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml).
Tracking: [enhancement 006](../../enhancements/006-bgp-tutorial.md) §9,
[enhancement 007](../../enhancements/007-envoy-gateway-lab.md) §4.

## Summary context — the enterprise case

A cluster that announced LoadBalancer addresses by ARP on the node LAN
moves to BGP. The network team already wrote the sheet (one password per
fabric, listen range, `EG-VIPS` `10.98.0.0/24 le 32`). kube-vip dials
the leaves; the leaves do not list node addresses. Leader-only BGP is
one path per door; active-active is two node paths and ECMP. L2 and
active-active BGP cannot run together on this kube-vip (`vip_arp` is
the switch). The path a request takes is in the
[RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`10a-kube-vip-ds-bgp-election.yaml`](10a-kube-vip-ds-bgp-election.yaml) | kube-vip DS, BGP, `vip_arp=false`, `svc_election=true` |
| [`10b-kube-vip-ds-bgp-active-active.yaml`](10b-kube-vip-ds-bgp-active-active.yaml) | the final DS: `vip_arp=false`, `svc_election=false` |
| [`20a-gateways-bgp-etp-local.yaml`](20a-gateways-bgp-etp-local.yaml) | doors at `.10` / `.11`, ETP Local; Envoy `replicas: 2` + anti-affinity |
| [`20-gateways-bgp.yaml`](20-gateways-bgp.yaml) | the same doors, ETP Cluster; Envoy `replicas: 2` + anti-affinity |
| [`40-grpcdemo.yaml`](40-grpcdemo.yaml) | grpcdemo v1/v2; image `grpcdemo:local` |
| [`41-shopapi-ha.yaml`](41-shopapi-ha.yaml) | shopapi `replicas: 2` + anti-affinity; cleanup restores demo 54 |
| [`50-routes-bgp.yaml`](50-routes-bgp.yaml) | `shop-api-bgp` → `bgp-http-gw`; `orders-bgp` (demo 52's four rules) |
| [`hosts-entries.sh`](hosts-entries.sh) | prints `api` → `.10`, `grpc` → `.11`; never writes `/etc/hosts` |
| [`apply.sh`](apply.sh) | the eight recorded steps; matrix FAIL count exits 1 at the end |
| [`check.sh`](check.sh) | ≤ 18 PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | BGP objects gone; L2 kube-vip restored; fabric stays |
| Probe descriptors | referenced at [`../52-eg-poc2-metallb/probe/`](../52-eg-poc2-metallb/probe/) |

The cloud-provider is unchanged (static addresses by annotation, outside
its ranges — measured in demos 51/54). The password is omitted in
`bgp_peers` on this kernel
([`fabric/.env.example`](../46-bgp-fabric/fabric/.env.example) documents the
one password per fabric; `.env` is untracked).

## Run it

From the repo root. poc1/poc2 stay paused. The fabric and demo 54 must
already be up.

```bash
demos/55-bgp-fabric-desktop/apply.sh
demos/54-eg-poc1-kube-vip/apply.sh
demos/56-kube-vip-bgp/apply.sh
demos/56-kube-vip-bgp/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

## What was recorded

The last apply (`2026-09-20T19:53:33Z`) and the `check.sh` recorded after
it (`2026-09-20T19:56:30Z`).

### 1. Start from demo 54

ARP 3/3 on `.100`, no SERVERS peers.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
```

Recorded:

```text
---- arping -b -c 3 172.19.255.100 ----
ARPING 172.19.255.100 from 172.19.0.6 eth0
Unicast reply from 172.19.255.100 [fa:1f:d6:0f:1e:ae] 0.006ms
Unicast reply from 172.19.255.100 [fa:1f:d6:0f:1e:ae] 0.009ms
Unicast reply from 172.19.255.100 [fa:1f:d6:0f:1e:ae] 0.015ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
leaf1 SERVERS_peers=0
leaf2 SERVERS_peers=0
```

### 2. Switch kube-vip to BGP with the election on

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10a-kube-vip-ds-bgp-election.yaml
```

Recorded:

```text
daemonset.apps/kube-vip-ds configured
daemon set "kube-vip-ds" successfully rolled out
SERVERS Established on both leaves after 3s
eg-poc1-control-plane 172.19.0.2
eg-poc1-worker 172.19.0.3
      "state":"Established",
 *> 10.98.0.11/32    172.19.0.2                             0 65021 i
 *> 10.98.0.10/32    172.19.0.3                             0 65021 i
```

### 3. Create the BGP doors and the app

ETP Local first.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20a-gateways-bgp-etp-local.yaml \
  -f demos/56-kube-vip-bgp/40-grpcdemo.yaml \
  -f demos/56-kube-vip-bgp/41-shopapi-ha.yaml \
  -f demos/56-kube-vip-bgp/50-routes-bgp.yaml
```

Recorded:

```text
envoyproxy.gateway.envoyproxy.io/bgp-http-gw-proxy created
gateway.gateway.networking.k8s.io/bgp-http-gw created
envoyproxy.gateway.envoyproxy.io/bgp-grpc-gw-proxy created
gateway.gateway.networking.k8s.io/bgp-grpc-gw created
gateway.gateway.networking.k8s.io/bgp-http-gw condition met
gateway.gateway.networking.k8s.io/bgp-grpc-gw condition met
deployment.apps/envoy-shop-bgp-http-gw-f5c77ba4 condition met
deployment.apps/envoy-shop-bgp-grpc-gw-c0d4dcca condition met
Waiting for deployment "shopapi" rollout to finish: 1 out of 2 new replicas have been updated...
deployment "shopapi" successfully rolled out
kind-eg-poc1 httproute/shop-api-bgp: all parents Accepted+ResolvedRefs
kind-eg-poc1 grpcroute/orders-bgp: all parents Accepted+ResolvedRefs
bgp-http-gw nodes: eg-poc1-control-plane eg-poc1-worker unique=2
bgp-grpc-gw nodes: eg-poc1-worker eg-poc1-control-plane unique=2
shopapi nodes: eg-poc1-worker eg-poc1-control-plane unique=2
Received 0 response(s) (0 request(s), 0 broadcast(s))
```

### 4. Reach the door from the outside world

`client0` `200` + `X-Served-By`; the path is edge → spine → leaf →
node.

```bash
docker exec bgp-fabric-client0-1 \
  curl --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  http://api.eg-poc1.poc.local/healthz
docker exec bgp-fabric-client0-1 \
  tcptraceroute -n -m 8 10.98.0.10 80
```

Recorded:

```text
grpcurl v1.9.3
http://api.eg-poc1.poc.local/healthz @ 10.98.0.10:80 → 200 X-Served-By=eg-poc1 curl_rc=0
10.98.0.10 via 10.200.100.2 dev eth0 src 10.200.100.10 uid 0
 1  10.200.100.2  0.079 ms  0.023 ms  0.026 ms
 2  10.200.1.18  0.260 ms  0.072 ms  0.029 ms
 3  10.200.1.2  0.095 ms  0.037 ms  0.038 ms
 4  10.98.0.10  0.099 ms  0.042 ms  0.076 ms
 5  10.98.0.10 [open]  0.091 ms  0.079 ms  0.049 ms
```

### 5. Switch to active-active

`leaf1 node_paths=1` after 2 s (`want >= 1`) while ETP is still Local;
the spine's two nexthops are the two leaves. Judges count node paths
only.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10b-kube-vip-ds-bgp-active-active.yaml
```

Recorded:

```text
daemonset.apps/kube-vip-ds configured
daemon set "kube-vip-ds" successfully rolled out
leaf1 node_paths=1 (want >= 1 nodes) after 2s
10.98.0.10 nhid 18 proto bgp metric 20
```

### 6. Measure ETP Local then Cluster

Two 40-curl loops; `x-pod` names both shopapi pods. Both node paths
were up after Cluster.

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20-gateways-bgp.yaml
```

Recorded:

```text
---- ETP-Local: 40 curls from client0 ----
ETP-Local ok=40 fail=0 x-pod=[shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm ]
eg-poc1-control-plane 40
eg-poc1-worker 7
before: uid=a28a317d-f5e5-433d-99f5-72cea2ed5e94 etp=Local
after apply 20: uid=a28a317d-f5e5-433d-99f5-72cea2ed5e94 etp=Cluster
final ETP=Cluster
leaf1 node_paths=2 (want >= 2 nodes) after 1s
---- ETP-Cluster: 40 curls from client0 ----
ETP-Cluster ok=40 fail=0 x-pod=[shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-kbvz8 shopapi-55dd74569b-gtgpm shopapi-55dd74569b-kbvz8 ]
eg-poc1-control-plane 40
eg-poc1-worker 0
```

### 7. Run the gRPC matrix from client0

```bash
docker exec bgp-fabric-client0-1 grpcurl --version
```

Recorded:

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

(A) delete the worker's kube-vip pod (the loop's clock starts once the
delete has returned, so `withdrawal_s=0` means "already gone by then").
(B) pause the worker 75 s. BGP withdrew at 8 s; the node went
`Ready=Unknown` at 51 s; shopapi and the door were pruned
(`ready_eps=1 door_eps=1`); three of the four probes after that
succeeded (`first_ok_after_s=58`); the envoy-gateway controller's
single replica was on the paused node; the door came back 10 s after
unpause. A silent node needs BGP, the grace period AND a live control
plane for the door.

```bash
kubectl --context kind-eg-poc1 -n kube-system delete pod \
  "$(kubectl --context kind-eg-poc1 -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds \
    --field-selector spec.nodeName=eg-poc1-worker \
    -o jsonpath='{.items[0].metadata.name}')"
docker pause eg-poc1-worker
```

Recorded:

```text
---- A: BGP-only — delete kube-vip pod kube-vip-ds-9k47n on eg-poc1-worker ----
A summary: withdrawal_s=0 ok=12 fail=0 recovery_s=2
---- B: silent node — pause eg-poc1-worker (172.19.0.3) for 75 s; envoy-gateway controller on: eg-poc1-worker ----
t+8s code=000 rc=28 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=True lastTransitionTime=2026-09-20T14:04:57Z ready_eps=2 door_eps=2
screenshot written after 2.0 s; chrome_rc=0
demos/56-kube-vip-bgp/output/screenshots/dashboard-silent-node.png: PNG image data, 1200 x 700, 8-bit/color RGB, non-interlaced
t+51s code=000 rc=28 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=Unknown lastTransitionTime=2026-09-20T19:55:53Z ready_eps=1 door_eps=1
t+58s code=200 rc=0 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=Unknown lastTransitionTime=2026-09-20T19:55:53Z ready_eps=1 door_eps=1
t+64s code=200 rc=0 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=Unknown lastTransitionTime=2026-09-20T19:55:53Z ready_eps=1 door_eps=1
t+69s code=200 rc=0 leaf1 node_paths=1 peer 172.19.0.3 state=ABSENT Ready=Unknown lastTransitionTime=2026-09-20T19:55:53Z ready_eps=1 door_eps=1
B summary: bgp_withdraw_s=8 node_notready_s=51 first_ok_after_s=58 post_notready ok=3 fail=1 recovery_s=10 eg_controller_node=eg-poc1-worker
```

![Silent node on leaf1: header `fabric sessions 6/6 · server sessions
2/4`; the paused worker's sessions on both leaves are red
(`Established→Idle` in Events); leaf1 RIB keeps `10.98.0.10/32` and
`10.98.0.11/32` via `172.19.0.2`.](output/screenshots/dashboard-silent-node.png)

## Checks

```bash
demos/56-kube-vip-bgp/check.sh
```

`check.sh` at `2026-09-20T19:56:30Z`, after the run above: 16 rows, 16 PASS, 0 FAIL.

Recorded:

```text
### 2026-09-20T19:56:30Z
$ demos/56-kube-vip-bgp/check.sh
== demo 56 — kube-vip BGP on eg-poc1 (migration from L2)
  STATUS WHAT                                                                   MEASURED                                             RULE
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
  PASS   SERVERS-IN seq 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0         seq10_invoked=24                                     sheet row 4 — EG-POC1-VIPS 10.98.0.0/26 ge 32 le 32 + as-path ^65021$

demo 56 check: 0 FAIL
```

## What is deliberately not here

- No Mac route recorded. apply.sh printed the two lines; the record is
  `Mac route absent — the client0 half is the record`.
- A Kubernetes deploy of the dashboard (demo 46 R7). This apply shot
  demo 46's compose service at `127.0.0.1:8088`.
- Demo 54's L2 doors (`.100` / `.101`) stay as objects and stay dark
  until [`cleanup.sh`](cleanup.sh) restores
  [`clusters/eg/kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml).
- Cilium BGP (demos 47–49) and MetalLB BGP (demo 57).
- A change to the fabric or to `eg-poc2`.

## Runs that did not go to plan

The pages were re-recorded when the fabric moved to FRR 10.7.1 and
gained the dashboard. The last apply is `2026-09-20T19:53:33Z`.

The first apply (`2026-09-20T04:27:40Z`) left ARP on with BGP. The
DaemonSet rolled out then crashed (`ready=0/2`); kube-vip refuses two
modes (`multiple kube-vip modes detected` — kube-vip v1.2.4
cmd/kube-vip.go:390, not in the record: the log grep kept only BGP
lines). Recorded:
`apply.sh: SERVERS not Established on both leaves after 90s`.

The second apply (`2026-09-20T04:31:57Z`) put the fabric MD5 in
`bgp_peers`. Pods were Ready (`ready=2/2`); gobgp stayed ACTIVE (this
kernel refuses `TCP_MD5SIG`). Recorded:
`apply.sh: SERVERS not Established on both leaves after 90s`.

The third apply (`2026-09-20T04:37:17Z`) was killed by the Mac's
low-memory guard during the active-active wait. No lesson.

The fourth apply (`2026-09-20T04:45:19Z`) left
`vip_leaderelection=true` on the active-active DaemonSet. kube-vip
logs `leader election is enabled, only the elected leader will
advertise service VIPs` (kube-vip v1.2.4 pkg/manager/worker/bgp.go:117;
not in the record — the log grep kept only BGP lines). Recorded:
`apply.sh: spine still has paths=0 for 10.98.0.10/32 after 90s`.

The fifth apply (`2026-09-20T04:56:29Z`) judged the spine. Its two
paths were the two leaves, not the two nodes. The judge moved to the
leaf. Recorded:
`apply.sh: leaf1 still has paths=1 for 10.98.0.10/32 after 90s`.

The sixth apply (`2026-09-20T05:00:28Z`) paused the worker while
shopapi was still one replica. Recorded:
`pause loop ok=0 fail=15 first_fail_s=0 idle_at_s=none one_path_at_s=none`.

The seventh apply (`2026-09-20T05:09:48Z`) counted leaf1's spine
bounce as a third path (`leaf1 paths=3`) and ran the check before the
worker's sessions were back. Recorded: `demo 56 check: 1 FAIL`
(`est=2`).

The eighth apply (`2026-09-20T05:18:47Z`) showed the paused node go
`Ready=Unknown`, not `False`. Recorded:
`Ready=Unknown lastTransitionTime=2026-09-20T05:20:54Z`.

The ninth apply (`2026-09-20T05:23:02Z`) applied shopapi HA against
demo 54's still-running pods. The required anti-affinity matches those
too; the default 25%/25% strategy on two replicas is one surge and
zero unavailable, so the new pod never scheduled. apply.sh waited for
Available (the old ReplicaSet keeps it True). Recorded:
`shopapi-55dd74569b-9qm56   0/1     Pending`. The fix is `maxSurge: 0`
/ `maxUnavailable: 1` in
[`41-shopapi-ha.yaml`](41-shopapi-ha.yaml) and `rollout status`.

The tenth apply's first check (`2026-09-20T06:18:07Z`) failed
SERVERS-IN (`vtysh/JSON failed`): FRR 10.5 keys the daemon `bgpd`.
Recorded: `demo 56 check: 1 FAIL`.

FORWARD alone did not isolate the fabric agents. A reviewer's probe
from `client0` read the edge's whole BGP table on `10.200.200.1`
(measured 2026-09-20,
[demo 46 entrypoint](../46-bgp-fabric/fabric/entrypoint.sh),
[`tests/fabric-agent-mgmt-input.sh`](../../tests/fabric-agent-mgmt-input.sh)).
The live gate FAILED on that fabric. Demo 46's `2026-09-20T19:29:04Z`
apply closed it (`client0_rc=28,28,28,28`); this apply ran on those
images.

## Clean up

```bash
demos/56-kube-vip-bgp/cleanup.sh
```

cleanup.sh removes the BGP routes, Gateways, EnvoyProxies and grpcdemo,
restores shopapi to demo 54's 1 replica, restores L2 kube-vip, and waits
until demo 54's `.100` answers ARP again. The fabric stays.
