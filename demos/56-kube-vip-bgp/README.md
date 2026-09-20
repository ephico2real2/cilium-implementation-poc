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
one path on the spine; active-active is two paths and ECMP. L2 and
active-active BGP cannot run together on this kube-vip (`vip_arp` is
the switch). The path a request takes is in the
[RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`10a-kube-vip-ds-bgp-election.yaml`](10a-kube-vip-ds-bgp-election.yaml) | kube-vip DS, BGP, `vip_arp=true`, `svc_election=true` |
| [`10b-kube-vip-ds-bgp-active-active.yaml`](10b-kube-vip-ds-bgp-active-active.yaml) | the final DS: `vip_arp=false`, `svc_election=false` |
| [`20a-gateways-bgp-etp-local.yaml`](20a-gateways-bgp-etp-local.yaml) | doors at `.10` / `.11`, ETP Local (the experiment) |
| [`20-gateways-bgp.yaml`](20-gateways-bgp.yaml) | the same doors, ETP Cluster |
| [`40-grpcdemo.yaml`](40-grpcdemo.yaml) | grpcdemo v1/v2; image `grpcdemo:local` |
| [`50-routes-bgp.yaml`](50-routes-bgp.yaml) | `shop-api-bgp` → `bgp-http-gw`; `orders-bgp` (demo 52's four rules) |
| [`hosts-entries.sh`](hosts-entries.sh) | prints `api` → `.10`, `grpc` → `.11`; never writes `/etc/hosts` |
| [`apply.sh`](apply.sh) | the ten recorded steps; matrix FAIL count exits 1 at the end |
| [`check.sh`](check.sh) | ≤ 18 PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | BGP objects gone; L2 kube-vip restored; fabric stays |
| Probe descriptors | referenced at [`../52-eg-poc2-metallb/probe/`](../52-eg-poc2-metallb/probe/) |

The cloud-provider is unchanged (static addresses by annotation, outside
its ranges — measured in demos 51/54). The password is inline in
`bgp_peers` (one password per fabric;
[`fabric/.env`](../46-bgp-fabric/fabric/.env)).

## Run it

From the repo root. poc1/poc2 stay paused. The fabric and demo 54 must
already be up.

```bash
demos/46-bgp-fabric/apply.sh
demos/54-eg-poc1-kube-vip/apply.sh
demos/56-kube-vip-bgp/apply.sh
demos/56-kube-vip-bgp/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

## What was recorded

<!-- recorded after apply -->

### 1. Record the L2 baseline

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
```

```text
<!-- recorded after apply -->
```

### 2. Switch kube-vip to BGP with election on

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10a-kube-vip-ds-bgp-election.yaml
```

```text
<!-- recorded after apply -->
```

### 3. Create the BGP doors with ETP Local

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20a-gateways-bgp-etp-local.yaml
```

```text
<!-- recorded after apply -->
```

### 4. Curl the routed door from client0

```bash
docker exec bgp-fabric-client0-1 \
  curl --resolve api.eg-poc1.poc.local:80:10.98.0.10 \
  http://api.eg-poc1.poc.local/healthz
```

```text
<!-- recorded after apply -->
```

### 5. Switch kube-vip to active-active

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/10b-kube-vip-ds-bgp-active-active.yaml
```

```text
<!-- recorded after apply -->
```

### 6. Measure ETP Local then set Cluster

```bash
kubectl --context kind-eg-poc1 apply \
  -f demos/56-kube-vip-bgp/20-gateways-bgp.yaml
```

```text
<!-- recorded after apply -->
```

### 7. Run the gRPC matrix from client0

```bash
docker exec bgp-fabric-client0-1 grpcurl --version
```

```text
<!-- recorded after apply -->
```

### 8. Try the Mac path

```bash
scripts/fabric-vm-route.sh --apply
```

```text
<!-- recorded after apply -->
```

### 9. Pause a worker and measure recovery

```bash
docker pause eg-poc1-worker
```

```text
<!-- recorded after apply -->
```

### 10. Print the final table

```bash
demos/56-kube-vip-bgp/hosts-entries.sh
```

```text
<!-- recorded after apply -->
```

## Checks

```bash
demos/56-kube-vip-bgp/check.sh
```

```text
<!-- recorded after apply -->
```

## What is deliberately not here

- Cilium BGP (demos 47–49) and MetalLB BGP (demo 57).
- A change to the fabric or to `eg-poc2`.
- A Mac `sudo route` — the line is printed; `client0` is the record.
- Demo 54's shopapi, shop-db and L2 Gateways as objects — they stay;
  only the L2 announcement stops.

## Clean up

```bash
demos/56-kube-vip-bgp/cleanup.sh
```

cleanup.sh removes the BGP routes, Gateways, EnvoyProxies and grpcdemo,
restores L2 kube-vip, and waits until demo 54's `.100` answers ARP
again. The fabric stays.
