# Demo 56 — five things to try

Five exercises against the demo once it is up. Exercise 4 restarts a
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

### 3. Read the leaf's three paths

Active-active: both nodes advertise the `/32`. The spine's two
nexthops are the two leaves. leaf1 may also hold the door's own prefix
learned from the spine (`10.200.1.3`, AS path `65100 65102 65021`);
judges count node paths (nexthop in `172.19.0.0/17`) only.

```bash
docker compose -p bgp-fabric exec -T leaf1 vtysh -c 'show ip bgp 10.98.0.10/32'
docker compose -p bgp-fabric exec -T spine ip route show 10.98.0.10
```

**Expect:** two node paths on leaf1; two nexthops on the spine.

```text
leaf1 node_paths=2 (want >= 2 nodes) after 1s
10.98.0.10 nhid 27 proto bgp metric 20
  PASS   leaf1 2 node paths for 10.98.0.10/32 (both nodes)                      node_paths=2                                         active-active — both nodes advertise to each leaf
```

### 4. Kill kube-vip on one node and watch the leaf (changes the cluster)

Delete the worker's kube-vip pod. The DaemonSet restarts it. leaf1
drops to one node path and returns when the pod is Running.

```bash
kubectl --context kind-eg-poc1 -n kube-system delete pod \
  "$(kubectl --context kind-eg-poc1 -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds \
    --field-selector spec.nodeName=eg-poc1-worker \
    -o jsonpath='{.items[0].metadata.name}')"
```

**Expect:** one node path at t+0, two by t+3, no failed curls.

```text
t+0s code=200 rc=0 leaf1 node_paths=1
t+3s code=200 rc=0 leaf1 node_paths=2
A summary: withdrawal_s=0 ok=11 fail=0 recovery_s=3
```

### 5. Run the check

```bash
demos/56-kube-vip-bgp/check.sh
```

**Expect:** 16 PASS, `demo 56 check: 0 FAIL`.

```text
demo 56 check: 0 FAIL
```

## Clean up

[README Clean up](README.md#clean-up).
