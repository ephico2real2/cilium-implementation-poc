# Demo 52 — HTTP and gRPC through two MetalLB doors, from the Mac

This page builds one kind cluster, `eg-poc2`, on stock networking — kindnet
and kube-proxy in iptables mode, no Cilium — with Envoy Gateway and MetalLB
(a controller that allocates from an `IPAddressPool` and a speaker that
answers ARP for a Service address). Two Gateways isolate the protocols:
`http-gw` at `172.19.255.150` serves HTTP and HTTPS for
`api.eg-poc2.poc.local`; `grpc-gw` at `172.19.255.151` serves h2c and TLS
for `grpc.eg-poc2.poc.local`. Behind the gRPC door is a real `Orders`
service with method and metadata routing. The Mac reaches both doors over
one static route to `172.19/16`.

## What you get

- One cluster `eg-poc2`: kindnet + kube-proxy `iptables`, no Cilium.
- Two isolated doors: `http-gw` at `172.19.255.150`, `grpc-gw` at
  `172.19.255.151`.
- MetalLB L2 announces both; the address is not on any node's `eth0`.
- From the Mac: HTTP `/healthz` and `/orders` through the HTTP door.
- From the Mac: a fourteen-case gRPC matrix (reflection, method, metadata,
  stream, T8a missing method / T8b unrouted service, TLS, isolation,
  Health).
- `check.sh` with at most 21 PASS/FAIL rows.

## Architecture

A request from the Mac takes this path:

```text
                    MacBook
           curl / grpcurl / Chrome
                    │
                    │  route 172.19/16 → 192.168.64.2
                    ▼
              kind-eg bridge
              172.19.0.0/16
                    │
                    ▼
         MetalLB speaker (ARP)
         .150 / .151  — not on eth0
              │                    │
              ▼                    ▼
         Envoy http-gw        Envoy grpc-gw
         :80 / :443           h2c :80 / TLS :443
              │                    │
              ▼                    ▼
         shopapi + shop-db    grpcdemo-v1 / grpcdemo-v2
         X-Served-By: eg-poc2 shop.v1.Orders
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.eg-poc2.poc.local` | `172.19.255.150` | HTTP door — `/healthz`, `/orders`, the browser | the node MetalLB elects |
| `grpc.eg-poc2.poc.local` | `172.19.255.151` | gRPC door — `shop.v1.Orders`, Health, reflection | the node MetalLB elects |

The reserved block is `172.19.255.128/26`
([enhancement 007 §3.1](../../enhancements/007-envoy-gateway-lab.md)):
services `.136–.143` (autoAssign); doors `.150–.160` (autoAssign: false).
No HTTPRoute attaches to the gRPC door and no GRPCRoute attaches to the
HTTP door. The lab has no DNS for `.poc.local`: clients use `--resolve`,
`-authority`, or Chrome's `--host-resolver-rules`. MetalLB answers ARP for
the door and does not add it to `eth0`; kube-proxy delivers the packet —
the visible difference from demo 54.

## Prerequisites

- On the Mac: kind, helm, kubectl, Go (so grpcurl v1.9.4 runs without
  installing a binary), Chrome at
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
- Image `shopapi:local` already on the machine. `grpcdemo:local` is built
  by `grpcdemo/build.sh` (the only docker build on this lab).
- A route on the Mac to the lab bridge:

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  Gateway API `v1.6.2`, Envoy Gateway `v1.9.1`, cert-manager `v1.21.1`,
  MetalLB `v0.16.0` (chart `0.16.0`), node image
  `kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`.

## Steps

Do these in order from the repo root (apply.sh records steps 2–8 after the
lab is up):

### 1. Build the lab

The up script for `eg-poc2` creates the cluster, the standard-channel CRDs,
Envoy Gateway, `GatewayClass eg`, cert-manager, and this lab's root
(exported as `.tmp/eg-poc2-root-ca.crt`).

```bash
scripts/eg-net.sh
scripts/eg-up.sh eg-poc2
```

Result: <!-- recorded after apply -->

### 2. Install MetalLB

The Helm chart is pinned at `0.16.0`. `loadBalancerClass` becomes
`--lb-class=` on both controller and speaker. L2-only needs FRR off.

```bash
helm repo add metallb https://metallb.github.io/metallb --force-update
helm upgrade --install metallb metallb/metallb --version 0.16.0 \
  -n metallb-system --create-namespace \
  --set loadBalancerClass=metallb.io/metallb \
  --set speaker.frr.enabled=false --set frrk8s.enabled=false
```

Result: <!-- recorded after apply -->

### 3. Issue the certificate

One `Certificate` covers both names (the CN is the HTTP name). Gateways live
in `shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/20-certificate.yaml
kubectl --context kind-eg-poc2 -n shop wait certificate/eg-poc2-tls \
  --for=condition=Ready --timeout=90s
```

Result: <!-- recorded after apply -->

### 4. Create the two doors

Each EnvoyProxy names `loadBalancerClass: metallb.io/metallb` and pins the
address; it sits in the same file before its Gateway because the class is
immutable. MetalLB requires the pin to sit inside `eg-poc2-doors`.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/30-gateways.yaml
kubectl --context kind-eg-poc2 -n shop wait --for=condition=Programmed \
  gateway/http-gw --timeout=180s
kubectl --context kind-eg-poc2 -n shop wait --for=condition=Programmed \
  gateway/grpc-gw --timeout=180s
```

Result: <!-- recorded after apply -->

### 5. Deploy the apps and routes

`shop-db` is this demo's postgres (emptyDir). `shopapi:local` and two
`grpcdemo:local` Deployments (`VERSION=v1` / `v2`,
`appProtocol: kubernetes.io/h2c`) sit behind it. The HTTPRoute parents
`http-gw` only. The GRPCRoute parents `grpc-gw` only and matches most
specific first: metadata, then method, then service.

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

Result: <!-- recorded after apply -->

### 6. Prove the announcement

MetalLB's speaker answers ARP. The address is not configured on the node's
`eth0`. `ServiceL2Status` (or the speaker log) names the announcing node.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.150
kubectl --context kind-eg-poc2 -n envoy-gateway-system get servicel2status
```

Result: <!-- recorded after apply -->

### 7. Run the gRPC matrix from the Mac

HTTPS and gRPC-TLS verify the leaf against `.tmp/eg-poc2-root-ca.crt` and
do not skip verification. grpcurl runs on the Mac via Go.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/ListOrders
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -cacert .tmp/eg-poc2-root-ca.crt -authority grpc.eg-poc2.poc.local \
  172.19.255.151:443 shop.v1.Orders/ListOrders
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  -d '{"id":2}' 172.19.255.151:80 shop.v1.Orders/GetOrder
```

Result: <!-- recorded after apply -->

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

Result: <!-- recorded after apply -->

For a real browser, add the hosts block (the script only prints it; the
`tee` writes it):

```bash
demos/52-eg-poc2-metallb/hosts-entries.sh | sudo tee -a /etc/hosts
```

Result: <!-- recorded after apply -->

## Verify

From the Mac, with the route present:

```bash
curl -s --resolve api.eg-poc2.poc.local:80:172.19.255.150 \
  -D - -o /dev/null http://api.eg-poc2.poc.local/healthz
```

Expect `200` and `X-Served-By: eg-poc2`.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/ListOrders
```

Expect three orders and `version` `v1`.

```bash
demos/52-eg-poc2-metallb/check.sh
```

<!-- recorded after apply -->

## Reference

Certificate spec (`20-certificate.yaml`):

```yaml
kind: Certificate
spec:
  secretName: eg-poc2-tls
  commonName: api.eg-poc2.poc.local
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - api.eg-poc2.poc.local
    - grpc.eg-poc2.poc.local
  issuerRef: {kind: ClusterIssuer, name: eg-ca-issuer}
```

Issuer `eg-ca-issuer` signs from CA secret `eg-root-ca`
(`.tmp/eg-poc2-root-ca.crt`).

| File | What |
|---|---|
| [`10-metallb-pool.yaml`](10-metallb-pool.yaml) | two `IPAddressPool`s + one `L2Advertisement` |
| [`20-certificate.yaml`](20-certificate.yaml) | `Certificate` `eg-poc2-tls` |
| [`30-gateways.yaml`](30-gateways.yaml) | EnvoyProxy then Gateway, twice: `http-gw` `.150`, `grpc-gw` `.151` |
| [`40-app.yaml`](40-app.yaml) | `shopapi` |
| [`41-grpcdemo.yaml`](41-grpcdemo.yaml) | `grpcdemo-v1` / `v2` |
| [`45-shop-db.yaml`](45-shop-db.yaml) | `shop-db` (postgres:16-alpine, emptyDir) |
| [`50-routes.yaml`](50-routes.yaml) | HTTPRoute → http-gw; GRPCRoute → grpc-gw |
| [`probe/`](probe/) | T8a / T8b descriptors (not served by grpcdemo) |
| [`apply.sh`](apply.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, prove, remove |

Address block `172.19.255.128/26` (enhancement 007 §3.1): services
`.136–.143`; doors `.150–.160` — HTTP `.150`, gRPC `.151`.

## Troubleshooting

- Every client on the Mac times out while `check.sh` passes in the
  cluster: the `172.19` route is missing (it does not survive a reboot) —
  [gotcha #120](../../docs/GOTCHAS.md#120); add it with the command under
  *Prerequisites*.
- Chrome hangs after writing the screenshot —
  [gotcha #121](../../docs/GOTCHAS.md#121); the PNG on disk is the result.
- `eg-up.sh eg-poc2` exits 2 if kind cluster `eg2` exists: they share
  `172.19.255.128/26`.

## Clean up

```bash
demos/52-eg-poc2-metallb/cleanup.sh
scripts/eg-down.sh
```

cleanup.sh removes the doors, app, MetalLB and `shop`. eg-down.sh deletes
the cluster.

## What's next

- Demo 54 is the same two-door design with kube-vip on `eg-poc1`.
- The fail cases and the VIP move stay in
  [demo 51](../51-eg-kube-vip/README.md).
- The Envoy Gateway vs Cilium comparison write-up is phase 4 of
  [enhancement 007](../../enhancements/007-envoy-gateway-lab.md) (issue #59).
