# Demo 54 — HTTP and gRPC through two kube-vip doors, from the Mac

This page builds one kind cluster, `eg-poc1`, on stock networking — kindnet
and kube-proxy in iptables mode, no Cilium — with Envoy Gateway and kube-vip
(a DaemonSet that answers ARP for a Service address). Two Gateways isolate
the protocols: `http-gw` at `172.19.255.100` serves HTTP and HTTPS for
`api.eg-poc1.poc.local`; `grpc-gw` at `172.19.255.101` serves h2c and TLS
for `grpc.eg-poc1.poc.local`. kube-vip announces both from `eg-poc1-worker`.
The Mac reaches them over one static route to `172.19/16`.

## What you get

- One cluster `eg-poc1`: kindnet + kube-proxy `iptables`, `cilium_ds=0
  cilium_crd=0`.
- Two isolated doors: `http-gw` at `172.19.255.100`, `grpc-gw` at
  `172.19.255.101`.
- kube-vip announces both from `eg-poc1-worker` (`fa:1f:d6:0f:1e:ae`, both
  `/32` on eth0).
- From the Mac: `http`/`https` `/healthz` → `200` and `X-Served-By: eg-poc1`;
  `/orders` → `200` and three rows.
- From the Mac: gRPC `SERVING` on h2c `:80` and TLS `:443`; `list` names
  Health and both reflection services.
- Chrome writes `output/browser.png` (`1000 x 500`) of
  `http://api.eg-poc1.poc.local/orders`.
- `check.sh` at `2026-09-19T15:12:49Z`: 15 PASS, 0 FAIL.

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
         eg-poc1-worker eth0
         172.19.0.3  fa:1f:d6:0f:1e:ae
         .100/32              .101/32
              │                    │
              ▼                    ▼
         Envoy http-gw        Envoy grpc-gw
         :80 / :443           h2c :80 / TLS :443
              │                    │
              ▼                    ▼
         shopapi + shop-db    grpc (routedemo -mode grpc)
         X-Served-By: eg-poc1
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.eg-poc1.poc.local` | `172.19.255.100` | HTTP door — `/healthz`, `/orders`, the browser | `eg-poc1-worker` (`fa:1f:d6:0f:1e:ae`) |
| `grpc.eg-poc1.poc.local` | `172.19.255.101` | gRPC door — Health, both reflection services | `eg-poc1-worker` (`fa:1f:d6:0f:1e:ae`) |

The bridge is `Subnet=172.19.0.0/16 IPRange=172.19.0.0/17
Gateway=172.19.0.1`. The control-plane sits at `172.19.0.2`, the worker at
`172.19.0.3`. No HTTPRoute attaches to the gRPC door and no GRPCRoute
attaches to the HTTP door. The lab has no DNS for `.poc.local`: clients
use `--resolve`, `-authority`, or Chrome's `--host-resolver-rules`.

## Prerequisites

- On the Mac (recorded): kind `v0.33.0`, helm `v4.3.0`, kubectl client
  `v1.37.0`, Go `1.27.1` (so grpcurl v1.9.4 runs without installing a
  binary), Chrome `153.0.8010.52` at
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
- Images `shopapi:local` and `routedemo:local` already on the machine
  (load them onto a node if it lacks them; this is not a docker build).
- A route on the Mac to the lab bridge (recorded:
  `172.19  192.168.64.2  UGSc  bridge100`):

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  Gateway API `v1.6.2`, Envoy Gateway `v1.9.1`, cert-manager `v1.21.1`,
  kube-vip `v1.2.4`, kube-vip cloud-provider `v0.0.12`, node image
  `kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`.

## Steps

Do these in order from the repo root (apply.sh records steps 2–8 after the
lab is up):

### 1. Build the lab

The up script for `eg-poc1` creates the cluster, the standard-channel CRDs,
Envoy Gateway, `GatewayClass eg`, cert-manager, and this lab's root
(exported as `.tmp/eg-poc1-root-ca.crt`).

```bash
scripts/eg-net.sh
scripts/eg-up.sh eg-poc1
```

Result: nodes `.0.2` / `.0.3`; kube-proxy `iptables`; 10 standard CRDs; 8
EG CRDs; `GatewayClass` Accepted; root `91:84:DE…`.

```text
eg-poc1  eg-poc1-control-plane=172.19.0.2 eg-poc1-worker=172.19.0.3  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True 91:84:DE:7D:65:FE:12:9A:35:23:0A:E1:17:24:BD:C3:E5:67:78:8E:56:34:A1:6A:64:6E:BB:1D:AF:7E:E3:81
```

### 2. Install kube-vip

The DaemonSet, cloud-provider and RBAC live under `clusters/eg/` (one source
of truth, not copied). The ConfigMap gives the doors `.100–.110` and
services `.72–.79`; kube-vip runs class-only.

```bash
kubectl --context kind-eg-poc1 apply \
  -f clusters/eg/kube-vip-rbac.yaml \
  -f clusters/eg/kube-vip-ds.yaml \
  -f clusters/eg/kube-vip-cloud-provider.yaml \
  -f demos/54-eg-poc1-kube-vip/10-kubevip-cm.yaml
```

Result: kube-vip DS `ready=2/2`; kube-vip-cloud-provider `Available=True`.

### 3. Issue the certificate

One `Certificate` covers both names (the CN is the HTTP name). Gateways live
in `shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/20-certificate.yaml
kubectl --context kind-eg-poc1 -n shop wait certificate/eg-poc1-tls \
  --for=condition=Ready --timeout=90s
```

Result: Ready; CN `api.eg-poc1.poc.local`; both SANs;
`notAfter=Dec 18 13:14:14 2026 GMT`.

```text
certificate.cert-manager.io/eg-poc1-tls condition met
subject=CN=api.eg-poc1.poc.local
DNS:api.eg-poc1.poc.local, DNS:grpc.eg-poc1.poc.local
notAfter=Dec 18 13:14:14 2026 GMT
```

### 4. Create the two doors

Each EnvoyProxy names `loadBalancerClass: kube-vip.io/kube-vip-class` and
pins the address; it sits in the same file before its Gateway because the
class is immutable.

```bash
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/30-gateways.yaml
kubectl --context kind-eg-poc1 -n shop wait --for=condition=Programmed \
  gateway/http-gw --timeout=180s
kubectl --context kind-eg-poc1 -n shop wait --for=condition=Programmed \
  gateway/grpc-gw --timeout=180s
```

Result: `http-gw` Programmed at `172.19.255.100`; `grpc-gw` Programmed at
`172.19.255.101` (`addr` = `svcIngress` = the pin, `Programmed=True`).

### 5. Deploy the apps and routes

`shop-db` is this demo's postgres (emptyDir); `shopapi:local` and
`routedemo:local -mode grpc` (`appProtocol: kubernetes.io/h2c`) sit behind
it. The HTTPRoute parents `http-gw` only; the GRPCRoute parents `grpc-gw`
only.

```bash
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/45-shop-db.yaml
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/40-app.yaml
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/50-routes.yaml
```

Result: kind-eg-poc1 httproute/shop-api: all parents Accepted+ResolvedRefs;
kind-eg-poc1 grpcroute/grpc: all parents Accepted+ResolvedRefs.

### 6. Prove the announcement

kube-vip runs `svc_election` against Services with
`externalTrafficPolicy: Local`, so only a node with a ready Envoy endpoint
can answer, and the `deprecated` flag is kube-vip's `PreferedLft=0` so the
VIP is never a source address
([kernel detail](../../docs/REVIEW_DEMO54.md)).

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.101
docker exec eg-poc1-worker ip -4 addr show eth0
```

Result: MAC `fa:1f:d6:0f:1e:ae` → `eg-poc1-worker`; both `/32`s on eth0;
kube-vip log lines present.

```text
MAC fa:1f:d6:0f:1e:ae → node eg-poc1-worker
inet 172.19.255.100/32 scope global deprecated eth0
inet 172.19.255.101/32 scope global deprecated eth0
adding VIP for 172.19.255.100: present
successful add IP for 172.19.255.100: present
layer 2 broadcaster starting for 172.19.255.100: present
adding VIP for 172.19.255.101: present
successful add IP for 172.19.255.101: present
layer 2 broadcaster starting for 172.19.255.101: present
```

### 7. Reach it from the Mac

HTTPS verifies the leaf against `.tmp/eg-poc1-root-ca.crt` and does not skip
verification. grpcurl runs on the Mac via Go; there is no binary to
install.

```bash
curl -s --resolve api.eg-poc1.poc.local:80:172.19.255.100 \
  -D - -o /dev/null http://api.eg-poc1.poc.local/healthz
curl -s --resolve api.eg-poc1.poc.local:443:172.19.255.100 \
  --cacert .tmp/eg-poc1-root-ca.crt \
  -D - -o /dev/null https://api.eg-poc1.poc.local/healthz
curl -s --resolve api.eg-poc1.poc.local:80:172.19.255.100 \
  -D - -H "Accept: application/json" \
  http://api.eg-poc1.poc.local/orders
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.101:80 grpc.health.v1.Health/Check
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -cacert .tmp/eg-poc1-root-ca.crt -authority grpc.eg-poc1.poc.local \
  172.19.255.101:443 grpc.health.v1.Health/Check
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.101:80 list
```

Result: `200` + `X-Served-By=eg-poc1` on http and https; `/orders` `200`
three rows; gRPC `SERVING` on h2c and TLS; `list` names three services.

```text
http://api.eg-poc1.poc.local/healthz @ 172.19.255.100:80 → 200 X-Served-By=eg-poc1 curl_rc=0
https://api.eg-poc1.poc.local/healthz @ 172.19.255.100:443 → 200 X-Served-By=eg-poc1 curl_rc=0
http://api.eg-poc1.poc.local/orders @ 172.19.255.100:80 → 200 X-Served-By=eg-poc1 curl_rc=0 body_head:
[{"id":1,"item":"keyboard","amount_cents":4999},{"id":2,"item":"mouse","amount_cents":1999},{"id":3,"item":"monitor","amount_cents":24900}]
{"status": "SERVING"}
grpcurl_h2c_rc=0
{"status": "SERVING"}
grpcurl_tls_rc=0
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
```

### 8. Open it in the browser

The `:80` listener has a hostname and no redirect, so the browser works over
plain http. Chrome maps the name; no hosts file is needed for the shot.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --window-size=1000,500 \
  --user-data-dir=<tmp> \
  --host-resolver-rules="MAP api.eg-poc1.poc.local 172.19.255.100" \
  --screenshot=demos/54-eg-poc1-kube-vip/output/browser.png \
  http://api.eg-poc1.poc.local/orders
```

Result: screenshot written after 2.0 s; `chrome_rc=0`; PNG `1000 x 500`.

```text
screenshot written after 2.0 s; chrome_rc=0
demos/54-eg-poc1-kube-vip/output/browser.png: PNG image data, 1000 x 500, 8-bit/color RGB, non-interlaced
```

![the orders page](output/browser.png)

For a real browser, add the hosts block (the script only prints it; the
`tee` writes it):

```bash
demos/54-eg-poc1-kube-vip/hosts-entries.sh | sudo tee -a /etc/hosts
```

Result: two lines in `/etc/hosts`, then `http://api.eg-poc1.poc.local/orders`
opens the same page.

```text
172.19.255.100  api.eg-poc1.poc.local
172.19.255.101  grpc.eg-poc1.poc.local
```

## Verify

From the Mac, with the route present:

```bash
curl -s --resolve api.eg-poc1.poc.local:80:172.19.255.100 \
  -D - -o /dev/null http://api.eg-poc1.poc.local/healthz
```

Expect `200` and `X-Served-By: eg-poc1`.

```bash
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc1.poc.local \
  172.19.255.101:80 grpc.health.v1.Health/Check
```

Expect `{"status": "SERVING"}`.

```bash
demos/54-eg-poc1-kube-vip/check.sh
```

Recorded `2026-09-19T15:12:49Z`:

```text
== demo 54 — one cluster, kube-vip, two Gateways (HTTP isolated from gRPC)
  PASS   kube-vip DS ready                                                      ready=2/2
  PASS   kube-vip-cloud-provider Available                                      Available=True
  PASS   http-gw Programmed at 172.19.255.100                                   addr=172.19.255.100 svcIngress=172.19.255.100 Programmed=True
  PASS   grpc-gw Programmed at 172.19.255.101                                   addr=172.19.255.101 svcIngress=172.19.255.101 Programmed=True
  PASS   both Envoy Services carry the class                                    http=kube-vip.io/kube-vip-class grpc=kube-vip.io/kube-vip-class
  PASS   ARP http-gw 172.19.255.100 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc1-worker
  PASS   ARP grpc-gw 172.19.255.101 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc1-worker
  PASS   VIP 172.19.255.100 on the elected node's eth0                          node=eg-poc1-worker /32
  PASS   VIP 172.19.255.101 on the elected node's eth0                          node=eg-poc1-worker /32
  PASS   http://api.eg-poc1.poc.local 200 + X-Served-By                         http_code=200 X-Served-By=eg-poc1
  PASS   https://api.eg-poc1.poc.local 200                                      http_code=200
  PASS   http://api.eg-poc1.poc.local /orders 200 (the page behind the door)    http_code=200 items=3
  PASS   gRPC h2c grpc.eg-poc1.poc.local @ 172.19.255.101:80                    SERVING
  PASS   gRPC TLS grpc.eg-poc1.poc.local @ 172.19.255.101:443                   SERVING
  PASS   stock networking                                                       kube-proxy=iptables cilium_ds=0 cilium_crd=0
demo 54 check: 0 FAIL
```

## Reference

Certificate spec (`20-certificate.yaml`):

```yaml
kind: Certificate
spec:
  secretName: eg-poc1-tls
  commonName: api.eg-poc1.poc.local
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - api.eg-poc1.poc.local
    - grpc.eg-poc1.poc.local
  issuerRef: {kind: ClusterIssuer, name: eg-ca-issuer}
```

Issued leaf: `subject=CN=api.eg-poc1.poc.local`,
`DNS:api.eg-poc1.poc.local, DNS:grpc.eg-poc1.poc.local`,
`notAfter=Dec 18 13:14:14 2026 GMT`,
`sha256=15:4B:20:78:0E:BD:71:EB:C4:18:AF:B0:6C:68:53:C3:A6:54:75:B5:55:7C:7F:DF:8B:7C:38:A8:84:6A:4E:2D`.
Issuer `eg-ca-issuer` signs from CA secret `eg-root-ca`
(`.tmp/eg-poc1-root-ca.crt`).

| File | What |
|---|---|
| [`clusters/eg/kube-vip-*.yaml`](../../clusters/eg/kube-vip-ds.yaml) | RBAC, DaemonSet, cloud-provider — one source of truth |
| [`10-kubevip-cm.yaml`](10-kubevip-cm.yaml) | `kubevip` ConfigMap (`range-envoy-gateway-system` `.100–.110`, `range-default` `.72–.79`) |
| [`20-certificate.yaml`](20-certificate.yaml) | `Certificate` `eg-poc1-tls` |
| [`30-gateways.yaml`](30-gateways.yaml) | EnvoyProxy then Gateway, twice: `http-gw` `.100`, `grpc-gw` `.101` |
| [`40-app.yaml`](40-app.yaml) | `shopapi` + `grpc` |
| [`45-shop-db.yaml`](45-shop-db.yaml) | `shop-db` (postgres:16-alpine, emptyDir) |
| [`50-routes.yaml`](50-routes.yaml) | HTTPRoute → http-gw; GRPCRoute → grpc-gw |
| [`apply.sh`](apply.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, prove, remove |

Address block `172.19.255.64/26` (enhancement 007 §3.1): services
`.72–.79`; doors `.100–.110` — HTTP `.100`, gRPC `.101`.

## Troubleshooting

- Every client on the Mac times out while `check.sh` passes in the
  cluster: the `172.19` route is missing (it does not survive a reboot) —
  [gotcha #120](../../docs/GOTCHAS.md#120); add it with the command under
  *Prerequisites*.
- Chrome hangs after writing the screenshot —
  [gotcha #121](../../docs/GOTCHAS.md#121); the PNG on disk is the result.

## Clean up

```bash
demos/54-eg-poc1-kube-vip/cleanup.sh
scripts/eg-down.sh
```

cleanup.sh removes the doors, app, kube-vip and `shop`. eg-down.sh deletes
the cluster.

## What's next

- Demo 52 installs MetalLB on the two-cluster lab (enhancement 007 §4).
- The fail cases and the VIP move stay in
  [demo 51](../51-eg-kube-vip/README.md).
- The Envoy Gateway vs Cilium comparison write-up is phase 4 of
  [enhancement 007](../../enhancements/007-envoy-gateway-lab.md) (issue #59).
