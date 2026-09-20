# Demo 56 — six things to try

Six exercises against the demo once it is up. Exercise 5 restarts a
kube-vip pod; the others are read-only.

## Prerequisites

- The fabric is up (demo 46). `client0` is `bgp-fabric-client0-1`.
- The demo is applied ([README Run it](README.md#run-it)).
- The CA file `.tmp/eg-poc1-root-ca.crt` is present (never committed).
- The Mac route was absent. The two lines, if a browser on the Mac is
  wanted:

```bash
test -f .tmp/eg-poc1-root-ca.crt
scripts/fabric-vm-route.sh --apply
```

```text
VM:  docker run --rm --privileged --pid=host --net=host alpine:3.20 nsenter -t 1 -m -n -- ip route replace 10.98.0.0/24 via 172.19.254.11
Mac: sudo route -n add -net 10.98.0.0/24 192.168.64.2
Mac route absent — the client0 half is the record
```

## Exercises

### 1. Curl the HTTP door from client0

The outside world reaches `10.98.0.10` through edge → spine → leaf →
node.

```bash
docker exec bgp-fabric-client0-1 \
  curl --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  http://api.eg-poc1.poc.local/healthz
```

**Expect:** `200` and `X-Served-By: eg-poc1`.

```text
http://api.eg-poc1.poc.local/healthz @ 10.98.0.10:80 → 200 X-Served-By=eg-poc1 curl_rc=0
```

### 2. Route gRPC by method and metadata

ListOrders is the service default (`v1`). GetOrder is a method match
(`v2`). The same ListOrders with header `x-version: v2` is a metadata
match (`v2`).

```bash
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

**Expect:** the recorded T2 / T4 / T5 lines.

```text
T T2 expected=3 orders version v1 served_by grpcdemo-v1- observed=v1 + three rows PASS
T T4 expected=GetOrder id=2 version v2 observed=v2 PASS
T T5 expected=x-version v2 then default v1 observed=v2 then v1 PASS
```

### 3. Read the leaf's node paths

Active-active: both nodes advertise the `/32`. The spine's two
nexthops are the two leaves. Judges count node paths (nexthop in
`172.19.0.0/17`) only.

```bash
docker compose -p bgp-fabric exec -T leaf1 vtysh -c 'show ip bgp 10.98.0.10/32'
docker compose -p bgp-fabric exec -T spine ip route show 10.98.0.10
```

**Expect:** two node paths on leaf1 after Cluster; two nexthops on the
spine.

```text
leaf1 node_paths=2 (want >= 2 nodes) after 1s
10.98.0.10 nhid 18 proto bgp metric 20
```

### 4. Open the dashboard and find this cluster's speakers

The fabric dashboard is at `http://127.0.0.1:8088/?router=leaf1`. Look
for this cluster's two kube-vip speakers (`172.19.0.2` and
`172.19.0.3`) as external peers of both leaves. Do not explain the
page; [demo 46](../46-bgp-fabric/RECAP.md) holds that.

```bash
curl -fsS --max-time 5 http://127.0.0.1:8088/healthz
```

**Expect:** both speakers Established on both leaves (four sessions).

```text
eg-poc1-control-plane 172.19.0.2
eg-poc1-worker 172.19.0.3
      "state":"Established",
recovery: 4 sessions Established; 2 node paths on both leaves after 1s
```

### 5. Kill kube-vip on one node and watch the leaf (changes the cluster)

Delete the worker's kube-vip pod. The DaemonSet restarts it. leaf1
drops to one node path and returns when the pod is Running.

```bash
kubectl --context kind-eg-poc1 -n kube-system delete pod \
  "$(kubectl --context kind-eg-poc1 -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds \
    --field-selector spec.nodeName=eg-poc1-worker \
    -o jsonpath='{.items[0].metadata.name}')"
```

**Expect:** one node path at t+0, two by t+2, no failed curls.

```text
t+0s code=200 rc=0 leaf1 node_paths=1
t+2s code=200 rc=0 leaf1 node_paths=2
A summary: withdrawal_s=0 ok=12 fail=0 recovery_s=2
```

### 6. Run the check

```bash
demos/56-kube-vip-bgp/check.sh
```

**Expect:** 16 rows, 16 PASS, 0 FAIL (recorded at `2026-09-20T19:56:30Z`) — the last
four rows:

```text
  PASS   client0 x-version v2                                                   v2                                                   demo 52 T5 — x-version v2 → version v2 served_by grpcdemo-v2-
  PASS   arping routed door 10.98.0.10 → 0 replies                            replies=0                                            routed door — nobody ARPs for a routed address / L2 door unannounced
  PASS   arping demo 54 L2 door 172.19.255.100 → 0 replies                    replies=0                                            demo 54 L2 door — nobody ARPs for a routed address / L2 door unannounced
  PASS   SERVERS-IN seq 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0         seq10_invoked=24                                     sheet row 4 — EG-POC1-VIPS 10.98.0.0/26 ge 32 le 32 + as-path ^65021$
```

## Clean up

[README Clean up](README.md#clean-up).
