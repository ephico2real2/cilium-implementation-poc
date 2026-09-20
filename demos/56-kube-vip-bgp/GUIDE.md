# Demo 56 — five things to try

Five exercises against the demo once it is up; nothing here changes the
cluster.

## Prerequisites

- The demo is applied ([README Run it](README.md#run-it)).
- The fabric is up (demo 46). `client0` is `bgp-fabric-client0-1`.
- The CA file `.tmp/eg-poc1-root-ca.crt` is present (never committed).

```bash
test -f .tmp/eg-poc1-root-ca.crt
docker compose -p bgp-fabric ps
```

## Exercises

### 1. Read the four SERVERS sessions

Both nodes dial both leaves. State is the JSON field `state`, not a
substring of the blob.

```bash
docker compose -p bgp-fabric exec -T leaf1 vtysh -c 'show bgp summary json' \
  | python3 scripts/fabric-bgp-summary.py
```

**Expect:** two peers at `172.19.0.2` and `172.19.0.3`, AS 65021,
`Established` on leaf1; the same on leaf2.

```text
<!-- recorded after apply -->
```

### 2. Read two paths on the spine

Active-active: every node advertises the `/32`.

```bash
docker compose -p bgp-fabric exec -T spine vtysh -c 'show ip bgp 10.98.0.10/32'
docker compose -p bgp-fabric exec -T spine ip route show 10.98.0.10
```

**Expect:** two paths on the prefix; two nexthops in the kernel.

```text
<!-- recorded after apply -->
```

### 3. Curl the HTTP door from client0

The outside world reaches `10.98.0.10` through edge → spine → leaf →
node.

```bash
docker exec bgp-fabric-client0-1 \
  curl -s --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  -D - -o /dev/null http://api.eg-poc1.poc.local/healthz
```

**Expect:** `200` and `X-Served-By: eg-poc1`.

```text
<!-- recorded after apply -->
```

### 4. Call ListOrders, GetOrder and x-version

Exact judges from demo 52: three v1 orders, GetOrder id=2 is v2, the
header selects v2.

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

**Expect:** v1 + three rows; v2 for GetOrder; v2 for the header.

```text
<!-- recorded after apply -->
```

### 5. Confirm no ARP for the routed address

A routed `/32` is not on the node LAN. Demo 54's `.100` is silent too
(the honest consequence of `vip_arp=false`).

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 10.98.0.10

docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
```

**Expect:** 0 Unicast replies on both addresses.

```text
<!-- recorded after apply -->
```

## Clean up

[README Clean up](README.md#clean-up).
