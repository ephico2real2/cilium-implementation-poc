# Demo 52 — one cluster, MetalLB, two Gateways

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

This is the one-cluster proof on `eg-poc2`: stock networking, Envoy Gateway,
MetalLB in L2, HTTP and gRPC through two isolated doors, and a real gRPC
service with a fourteen-case matrix from the Mac. The operator, 2026-09-19:
*"do demo with metallb as well. same design as sample app but i would love to
see more grpc testing"* and *"use eg-poc2"*. Tracking:
[enhancement 007](../../enhancements/007-envoy-gateway-lab.md) revision 2,
§3.1 / §4 row 52.

## Summary context — the enterprise case

One kind cluster, stock networking (kindnet + kube-proxy iptables, no Cilium),
Envoy Gateway, MetalLB. Two doors: `http-gw` at `172.19.255.150` (HTTP/HTTPS
for `api.eg-poc2.poc.local`); `grpc-gw` at `172.19.255.151` (h2c/TLS for
`grpc.eg-poc2.poc.local`). No HTTPRoute on the gRPC door, no GRPCRoute on the
HTTP door. Each `EnvoyProxy` names `loadBalancerClass: metallb.io/metallb` and
pins `metallb.io/loadBalancerIPs` (D11) in the same file before its Gateway.
MetalLB requires that requested address to sit inside a configured pool — the
difference from kube-vip's "even outside the ranges". The HTTP `:80` has a
hostname and no redirect. The lab root is `.tmp/eg-poc2-root-ca.crt`. The path
a request takes is in the [RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`10-metallb-pool.yaml`](10-metallb-pool.yaml) | `eg-poc2-services` `.136–.143` (autoAssign) and `eg-poc2-doors` `.150–.160` (autoAssign: false); one `L2Advertisement` |
| [`00-namespace.yaml`](00-namespace.yaml) | namespace `shop` |
| [`20-certificate.yaml`](20-certificate.yaml) | `Certificate` `eg-poc2-tls`, CN `api.eg-poc2.poc.local`, two dnsNames, 90d/30d |
| [`30-gateways.yaml`](30-gateways.yaml) | EnvoyProxy then Gateway, twice: `http-gw` `.150`, `grpc-gw` `.151` |
| [`40-app.yaml`](40-app.yaml) | `shopapi` |
| [`41-grpcdemo.yaml`](41-grpcdemo.yaml) | `grpcdemo-v1` / `grpcdemo-v2` and Services `grpc-v1` / `grpc-v2` (`appProtocol: kubernetes.io/h2c`) |
| [`45-shop-db.yaml`](45-shop-db.yaml) | `shop-db` (postgres:16-alpine, emptyDir; local to this demo) |
| [`50-routes.yaml`](50-routes.yaml) | `HTTPRoute` shop-api → http-gw only; `GRPCRoute` orders → grpc-gw only |
| [`grpcdemo/`](grpcdemo/) | Go module `grpcdemo`: proto, generated `pb.go`, unit tests, `Containerfile` |
| [`probe/`](probe/) | descriptors for T8a (`probe.proto`) and T8b (`nope.proto`); not served by grpcdemo |
| [`apply.sh`](apply.sh) | idempotent; every step through `scripts/record.sh` |
| [`check.sh`](check.sh) | at most 21 PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | doors, app, wait for Services, then MetalLB, `shop` — leaves the cluster |
| [`hosts-entries.sh`](hosts-entries.sh) | the two names from live Gateway addresses; never writes `/etc/hosts` |
| [`GUIDE.md`](GUIDE.md) | hosts-block prerequisite (the one sudo step) and six read-only exercises |

The lab root PEM is **`.tmp/eg-poc2-root-ca.crt`** (gitignored, issue #60).

## Run it

From the repo root. Bring the cluster up first:

```bash
scripts/eg-up.sh eg-poc2
demos/52-eg-poc2-metallb/apply.sh
demos/52-eg-poc2-metallb/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

## What was recorded

The orchestrator fills these fences from the transcript after apply.

### 1. Build the lab

The up script creates the cluster, the standard-channel CRDs, Envoy Gateway,
`GatewayClass eg`, cert-manager, and this lab's root. apply.sh then records the
`kind-eg` bridge, the two nodes, and stock networking (kindnet + kube-proxy
`iptables`; no Cilium).

```bash
scripts/eg-net.sh
scripts/eg-up.sh eg-poc2
```

<!-- recorded after apply -->

### 2. Install MetalLB

Helm chart `0.16.0` from `METALLB_VERSION` without the `v`. Class
`metallb.io/metallb` on controller and speaker; FRR off. Then the two pools
and one `L2Advertisement`.

```bash
helm repo add metallb https://metallb.github.io/metallb --force-update
helm upgrade --install metallb metallb/metallb --version 0.16.0 \
  -n metallb-system --create-namespace \
  --set loadBalancerClass=metallb.io/metallb \
  --set speaker.frr.enabled=false --set frrk8s.enabled=false
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/10-metallb-pool.yaml
```

<!-- recorded after apply -->

### 3. Issue the certificate

One `Certificate` covers both names (the CN is the HTTP name). Gateways live
in `shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/20-certificate.yaml
kubectl --context kind-eg-poc2 -n shop wait certificate/eg-poc2-tls \
  --for=condition=Ready --timeout=90s
```

<!-- recorded after apply -->

### 4. Create the two doors

Each EnvoyProxy names `loadBalancerClass: metallb.io/metallb` and pins the
address inside `eg-poc2-doors`; it sits in the same file before its Gateway
because the class is immutable.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/30-gateways.yaml
kubectl --context kind-eg-poc2 -n shop wait --for=condition=Programmed \
  gateway/http-gw --timeout=180s
kubectl --context kind-eg-poc2 -n shop wait --for=condition=Programmed \
  gateway/grpc-gw --timeout=180s
```

<!-- recorded after apply -->

### 5. Deploy the apps and routes

`shop-db` is this demo's postgres (emptyDir). `shopapi:local` and
`grpcdemo:local` (v1 and v2) sit behind the doors. The HTTPRoute parents
`http-gw` only; the GRPCRoute parents `grpc-gw` only.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/45-shop-db.yaml
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/40-app.yaml
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/41-grpcdemo.yaml
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/50-routes.yaml
```

<!-- recorded after apply -->

### 6. Prove the announcement

MetalLB answers ARP for the door; it does not add the address to the node's
`eth0`. kube-proxy delivers the packet. That is the visible difference from
demo 54.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.150
kubectl --context kind-eg-poc2 -n envoy-gateway-system get servicel2status
```

<!-- recorded after apply -->

### 7. Run the gRPC matrix from the Mac

Fourteen cases through `grpcurl` v1.9.4 on the Mac: reflection, ListOrders on
h2c and TLS, GetOrder by method, ListOrders by metadata, a five-event stream,
NotFound, Unimplemented (T8a missing method on `Orders`, T8b unrouted
`Nope/Do`), DeadlineExceeded, response metadata, a bogus CA, door isolation,
Health.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/ListOrders
```

<!-- recorded after apply -->

### 8. Open it in the browser

The `:80` listener has a hostname and no redirect, so the browser works over
plain http. Chrome maps the name; no hosts file is needed for the shot.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --window-size=1000,500 \
  --user-data-dir=<tmp> \
  --host-resolver-rules="MAP api.eg-poc2.poc.local 172.19.255.150" \
  --screenshot=demos/52-eg-poc2-metallb/output/browser.png \
  http://api.eg-poc2.poc.local/orders
```

<!-- recorded after apply -->

## Checks

```bash
demos/52-eg-poc2-metallb/check.sh
```

<!-- recorded after apply -->

## What is deliberately not here

- Fail cases (the class-less exhibit, the silent-`externalIPs` experiment)
  live in [demo 51](../51-eg-kube-vip/README.md).
- The VIP move lives in [demo 51](../51-eg-kube-vip/README.md).
- kube-vip is demo 54 (the same two-door design on `eg-poc1`).
- MetalLB beside kube-vip on `eg1`/`eg2` (issue #57) is superseded by this
  one-cluster lab.
- The lab has no DNS for `.poc.local`: clients use `--resolve`, `-authority`,
  or Chrome's `--host-resolver-rules`.

## Clean up

```bash
demos/52-eg-poc2-metallb/cleanup.sh
scripts/eg-down.sh
```

cleanup.sh removes the routes, Gateways, EnvoyProxies, app, certificate,
waits for the door Services to be gone, then uninstalls MetalLB and deletes
`shop`. It leaves `eg-poc2`, Envoy Gateway, `GatewayClass eg`, cert-manager,
and `.tmp/eg-poc2-root-ca.crt`. eg-down.sh deletes the cluster.
