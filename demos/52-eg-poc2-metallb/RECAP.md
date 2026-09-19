# Demo 52 — HTTP and gRPC through two MetalLB doors, from the Mac

This page builds one kind cluster, `eg-poc2`, on stock networking — kindnet
and kube-proxy in iptables mode, no Cilium — with Envoy Gateway and MetalLB
(a controller that allocates from an `IPAddressPool` and a speaker that
answers ARP for a Service address). Two Gateways isolate the protocols:
`http-gw` at `172.19.255.150` serves HTTP and HTTPS for
`api.eg-poc2.poc.local`; `grpc-gw` at `172.19.255.151` serves h2c and TLS
for `grpc.eg-poc2.poc.local`. Behind the gRPC door is a real `Orders`
service with method and metadata routing. The Mac reaches both doors
over one static route to `172.19/16`.

## What you get

- One cluster `eg-poc2`: kindnet + kube-proxy `iptables`, `GatewayClass`
  Accepted, its own root `A3:D7:73…`.
- Two isolated doors: `http-gw` at `172.19.255.150`, `grpc-gw` at
  `172.19.255.151`, both Programmed at their pinned address.
- MetalLB L2 announces both from `eg-poc2-worker` (`36:20:3a:e4:50:8d`);
  neither address is on `eth0`.
- From the Mac: `http`/`https` `/healthz` → `200` and
  `X-Served-By: eg-poc2`; `/orders` → `200` and three rows.
- From the Mac: the fourteen-case gRPC matrix, every row PASS.
- Chrome writes `output/browser.png` (`1000 x 500`) of
  `http://api.eg-poc2.poc.local/orders`.
- `check.sh` at `2026-09-19T22:22:03Z`: 21 PASS, 0 FAIL.

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
         eg-poc2-worker eth0
         172.19.0.5  36:20:3a:e4:50:8d
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
| `api.eg-poc2.poc.local` | `172.19.255.150` | HTTP door — `/healthz`, `/orders`, the browser | `eg-poc2-worker` (`36:20:3a:e4:50:8d`) |
| `grpc.eg-poc2.poc.local` | `172.19.255.151` | gRPC door — `shop.v1.Orders`, Health, reflection | `eg-poc2-worker` (`36:20:3a:e4:50:8d`) |

Nodes `172.19.0.4` (control-plane) and `172.19.0.5` (worker) on the
bridge `172.19.0.0/16` (Docker allocates from the lower `/17`). No
HTTPRoute attaches to the gRPC door and no GRPCRoute to the HTTP door.
There is no DNS for `.poc.local`: clients use `--resolve`, `-authority`, or
Chrome's `--host-resolver-rules`. MetalLB answers ARP and does not add the door to `eth0`; kube-proxy
delivers the packet — the visible difference from
[demo 54](../54-eg-poc1-kube-vip/RECAP.md). The worker answers because the
Envoy Services are `externalTrafficPolicy: Local` and MetalLB's L2 election
keeps only nodes with a serving endpoint (`speaker/layer2_controller.go`
`nodesWithEndpoint`); both Envoy pods run there. The reserved block is
`172.19.255.128/26`
([enhancement 007 §3.1](../../enhancements/007-envoy-gateway-lab.md)):
services `.136–.143`; doors `.150–.160`.

## Prerequisites

- On the Mac: kind, helm, kubectl, Go (so grpcurl v1.9.4 in
  [`apply.sh`](apply.sh) runs without installing a binary), Chrome at
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
- Image `shopapi:local` already on the machine. `grpcdemo:local` is built
  by `grpcdemo/build.sh` (the only docker build on this lab).
- A route on the Mac to the lab bridge (recorded:
  `172.19  192.168.64.2  UGSc  bridge100`):

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

Result: nodes `.0.4` / `.0.5`; kube-proxy `iptables`; 10 standard CRDs; 8
EG CRDs; `GatewayClass` Accepted; root `A3:D7:73…`.

```text
eg-poc2  eg-poc2-control-plane=172.19.0.4 eg-poc2-worker=172.19.0.5  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True A3:D7:73:DE:6C:2B:8F:BA:28:7C:D3:3A:F8:B5:52:10:F6:F8:0A:6A:25:C6:BE:2C:B5:82:64:6C:25:8F:08:EE
```

### 2. Install MetalLB

The Helm chart is pinned at `0.16.0`. `loadBalancerClass` becomes
`--lb-class=` on both controller and speaker. L2-only needs FRR off. Then
the two pools and one `L2Advertisement`.

```bash
helm repo add metallb https://metallb.github.io/metallb --force-update
helm upgrade --install metallb metallb/metallb --version 0.16.0 \
  -n metallb-system --create-namespace \
  --set loadBalancerClass=metallb.io/metallb \
  --set speaker.frr.enabled=false --set frrk8s.enabled=false
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/10-metallb-pool.yaml
```

Result: controller Available; speaker rolled out; `--lb-class` on both;
pools `eg-poc2-services` / `eg-poc2-doors` and `eg-poc2-l2`.

```text
          - --lb-class=metallb.io/metallb
          - --lb-class=metallb.io/metallb
ipaddresspool.metallb.io/eg-poc2-services unchanged
ipaddresspool.metallb.io/eg-poc2-doors unchanged
l2advertisement.metallb.io/eg-poc2-l2 unchanged
```

### 3. Issue the certificate

One `Certificate` covers both names (the CN is the HTTP name). Gateways live
in `shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/20-certificate.yaml
kubectl --context kind-eg-poc2 -n shop wait certificate/eg-poc2-tls \
  --for=condition=Ready --timeout=90s
```

Result: Ready; CN `api.eg-poc2.poc.local`; both SANs;
`notAfter=Dec 18 21:32:16 2026 GMT`.

```text
certificate.cert-manager.io/eg-poc2-tls condition met
subject=CN=api.eg-poc2.poc.local
    DNS:api.eg-poc2.poc.local, DNS:grpc.eg-poc2.poc.local
notAfter=Dec 18 21:32:16 2026 GMT
```

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

Result: `http-gw` Programmed at `172.19.255.150`; `grpc-gw` Programmed at
`172.19.255.151` (`addr` = `svcIngress` = the pin, `Programmed=True`).

```text
  PASS   http-gw Programmed at 172.19.255.150                                   addr=172.19.255.150 svcIngress=172.19.255.150 Programmed=True R5 / R8 — Gateway address and Service ingress both equal 172.19.255.150
  PASS   grpc-gw Programmed at 172.19.255.151                                   addr=172.19.255.151 svcIngress=172.19.255.151 Programmed=True R5 / R8 — Gateway address and Service ingress both equal 172.19.255.151
```

### 5. Deploy the apps and routes

`shop-db` is this demo's postgres (emptyDir). `shopapi:local` and two
`grpcdemo:local` Deployments (`VERSION=v1` / `v2`) sit behind it. The
HTTPRoute parents `http-gw` only; the GRPCRoute parents `grpc-gw` only.

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

Result: kind-eg-poc2 httproute/shop-api: all parents Accepted+ResolvedRefs;
kind-eg-poc2 grpcroute/orders: all parents Accepted+ResolvedRefs.

```text
kind-eg-poc2 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg-poc2 grpcroute/orders: all parents Accepted+ResolvedRefs
```

### 6. Prove the announcement

MetalLB's speaker answers ARP. The address is not configured on the node's
`eth0`. `ServiceL2Status` names the announcing node. The worker answers
because the Envoy Services are `externalTrafficPolicy: Local` and MetalLB
v0.16.0's L2 election keeps only nodes with a serving endpoint
(`speaker/layer2_controller.go` `ShouldAnnounce`: `nodesWithEndpoint`)
before the sha256 ordering; both Envoy pods run there, so the hash never
decides.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.150
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.151
```

Result: MAC `36:20:3a:e4:50:8d` → `eg-poc2-worker` (3/3 both doors); the
address is not on `eth0`.

```text
MAC 36:20:3a:e4:50:8d → node eg-poc2-worker
NAME       SERVICE                       NAMESPACE              NODE
l2-c4857   envoy-shop-grpc-gw-8c4f0319   envoy-gateway-system   eg-poc2-worker
l2-htcxz   envoy-shop-http-gw-fccf2727   envoy-gateway-system   eg-poc2-worker
172.19.255.150 NOT on eg-poc2-worker eth0 — MetalLB answers ARP for it, kube-proxy delivers it
172.19.255.151 NOT on eg-poc2-worker eth0 — MetalLB answers ARP for it, kube-proxy delivers it
```

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

Result: the recorded summary table, every row PASS.

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
T11  TLS fails with bogus CA                          Failed to dial target host "172.19.255.151:443": tls: failed to verify certifica rc=1 PASS
T12  grpc@.150 not served; curl@.151 → 404          grpcurl_rc=1 http=404        PASS
T13  {"status": "SERVING"} for "" and shop.v1.Orders  SERVING SERVING              PASS
gRPC matrix: 0 FAIL
```

### 8. Open it in the browser

The `:80` listener has a hostname and no redirect, so the browser works
over plain http. Chrome maps the name; no hosts file is needed for the
shot.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --window-size=1000,500 \
  --user-data-dir=<tmp> \
  --host-resolver-rules="MAP api.eg-poc2.poc.local 172.19.255.150" \
  --screenshot=demos/52-eg-poc2-metallb/output/browser.png \
  http://api.eg-poc2.poc.local/orders
```

Result: screenshot written after 5.2 s; `chrome_rc=0`; PNG `1000 x 500`.

```text
screenshot written after 5.2 s; chrome_rc=0
demos/52-eg-poc2-metallb/output/browser.png: PNG image data, 1000 x 500, 8-bit/color RGB, non-interlaced
```

![the orders page](output/browser.png)

For a real browser, add the hosts block (the script only prints it; the
`tee` writes it):

```bash
demos/52-eg-poc2-metallb/hosts-entries.sh | sudo tee -a /etc/hosts
```

Result: two lines in `/etc/hosts`, then `http://api.eg-poc2.poc.local/orders`
opens the same page.

```text
172.19.255.150  api.eg-poc2.poc.local
172.19.255.151  grpc.eg-poc2.poc.local
```

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

Recorded `2026-09-19T22:22:03Z`:

```text
== demo 52 — one cluster, MetalLB, two Gateways (HTTP isolated from gRPC)
  PASS   MetalLB controller Available + speaker DS                              Available=True ready=2/2
  PASS   http-gw Programmed at 172.19.255.150                                   addr=172.19.255.150 svcIngress=172.19.255.150 Programmed=True
  PASS   grpc-gw Programmed at 172.19.255.151                                   addr=172.19.255.151 svcIngress=172.19.255.151 Programmed=True
  PASS   both Envoy Services carry the class                                    http=metallb.io/metallb grpc=metallb.io/metallb
  PASS   ARP http-gw 172.19.255.150 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc2-worker
  PASS   ARP grpc-gw 172.19.255.151 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc2-worker
  PASS   VIP 172.19.255.150 NOT on any node's eth0                              absent on all nodes
  PASS   ServiceL2Status / announcing from node                                 envoy-shop-grpc-gw=eg-poc2-worker envoy-shop-http-gw=eg-poc2-worker R5 — MetalLB names the announcing node for both doors (ETP Local: a node with the Envoy pod)
  PASS   http://api.eg-poc2.poc.local 200 + X-Served-By                         http_code=200 X-Served-By=eg-poc2
  PASS   https://api.eg-poc2.poc.local 200                                      http_code=200
  PASS   http://api.eg-poc2.poc.local /orders 200 (the page behind the door)    http_code=200 items=3
  PASS   gRPC Health "" SERVING                                                 SERVING
  PASS   gRPC ListOrders v1                                                     version=v1
  PASS   gRPC GetOrder v2                                                       version=v2
  PASS   gRPC ListOrders x-version v2                                           version=v2
  PASS   gRPC WatchOrders 5 events                                              events=5
  PASS   gRPC GetOrder NotFound                                                 NotFound
  PASS   gRPC NoSuchMethod Unimplemented                                        Unimplemented unknown method
  PASS   gRPC unrouted service Unimplemented                                    Unimplemented empty Message
  PASS   gRPC SlowOrder DeadlineExceeded                                        DeadlineExceeded
  PASS   gRPC TLS ListOrders                                                    version=v1
demo 52 check: 0 FAIL
```

## Reference

Certificate spec ([`20-certificate.yaml`](20-certificate.yaml)):

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

Issued leaf: `subject=CN=api.eg-poc2.poc.local`,
`DNS:api.eg-poc2.poc.local, DNS:grpc.eg-poc2.poc.local`,
`notAfter=Dec 18 21:32:16 2026 GMT`,
`sha256=92:B0:EF:5D:BA:EB:38:93:45:F3:59:FA:3D:4B:27:AE:9B:70:82:20:6B:39:D7:AF:54:B1:93:95:1F:01:B8:85`.
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
| [`grpcdemo/`](grpcdemo/) | Go module `grpcdemo`: proto, generated `pb.go`, unit tests, `Containerfile` |
| [`probe/`](probe/) | T8a / T8b descriptors (not served by grpcdemo) |
| [`apply.sh`](apply.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, prove, remove |

Address block `172.19.255.128/26` (enhancement 007 §3.1): services
`.136–.143`; doors `.150–.160` — HTTP `.150`, gRPC `.151`.

GRPCRoute rules (most specific first):

| Match | Backend |
|---|---|
| `shop.v1.Orders` / `GetOrder` | `grpc-v2:9090` |
| `shop.v1.Orders` + header `x-version: v2` | `grpc-v2:9090` |
| `shop.v1.Orders` (service default) | `grpc-v1:9090` |
| `grpc.health.v1.Health` | `grpc-v1:9090` |
| `grpc.reflection.v1alpha.ServerReflection` | `grpc-v1:9090` |
| `grpc.reflection.v1.ServerReflection` | `grpc-v1:9090` |

Backends listen on port 9090 ([`50-routes.yaml`](50-routes.yaml)).

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/ListOrders
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  -d '{"id":2}' 172.19.255.151:80 shop.v1.Orders/GetOrder
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  -H 'x-version: v2' \
  172.19.255.151:80 shop.v1.Orders/ListOrders
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -import-path demos/52-eg-poc2-metallb/probe -proto probe.proto \
  -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/NoSuchMethod
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -import-path demos/52-eg-poc2-metallb/probe -proto nope.proto \
  -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Nope/Do
```

## Troubleshooting

- Every client on the Mac times out while `check.sh` passes in the
  cluster: the `172.19` route is missing (it does not survive a reboot) —
  [gotcha #120](../../docs/GOTCHAS.md#120); add it with the command under
  *Prerequisites*.
- A door stays `<pending>` or the pin is ignored: a requested address
  must be inside a pool — MetalLB's rule (the pin belongs in
  `eg-poc2-doors`, `.150–.160`).
- Chrome hangs after writing the screenshot —
  [gotcha #121](../../docs/GOTCHAS.md#121); the PNG on disk is the result.

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
