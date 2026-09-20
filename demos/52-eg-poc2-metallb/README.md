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

The third apply (`2026-09-19T22:21:32Z`, transcript lines 1482–2074). The
lab build is at `2026-09-19T21:30:41Z` (transcript lines 1–264).

### 1. Build the lab

The up script creates the cluster, the standard-channel CRDs, Envoy Gateway,
`GatewayClass eg`, cert-manager, and this lab's root. apply.sh then records the
`kind-eg` bridge, the two nodes, and stock networking (kindnet + kube-proxy
`iptables`; no Cilium).

```bash
scripts/eg-net.sh
scripts/eg-up.sh eg-poc2
```

Recorded (lab build):

```text
eg-poc2-control-plane 172.19.0.4
eg-poc2-worker 172.19.0.5
gateway.networking.k8s.io CRDs: 10 (want 10)
gateway.envoyproxy.io CRDs: 8 (want 8)
gatewayclass.gateway.networking.k8s.io/eg condition met
eg-poc2  eg-poc2-control-plane=172.19.0.4 eg-poc2-worker=172.19.0.5  iptables   10@v1.6.2    8        Accepted=True 1/1            Available=True A3:D7:73:DE:6C:2B:8F:BA:28:7C:D3:3A:F8:B5:52:10:F6:F8:0A:6A:25:C6:BE:2C:B5:82:64:6C:25:8F:08:EE
```

Recorded (third apply):

```text
---- kind-eg IPv4 (IPv6 IPRange prints invalid Prefix; skip that block) ----
Subnet=172.19.0.0/16 IPRange=172.19.0.0/17 Gateway=172.19.0.1
---- eg-poc2 nodes on kind-eg (IPv4 + MAC) ----
eg-poc2-worker Up 50 minutes
eg-poc2-control-plane Up 50 minutes
eg-poc2-worker 172.19.0.5 36:20:3a:e4:50:8d
eg-poc2-control-plane 172.19.0.4 96:06:5c:96:19:0b
---- kubectl get nodes -o wide ----
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION            CONTAINER-RUNTIME
eg-poc2-control-plane   Ready    control-plane   50m   v1.36.4   172.19.0.4    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg-poc2-worker          Ready    <none>          50m   v1.36.4   172.19.0.5    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
---- stock networking: kube-proxy mode + kindnet DS ----
    mode: iptables
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kindnet      2         2         2       2            2           kubernetes.io/os=linux   50m
kube-proxy   2         2         2       2            2           kubernetes.io/os=linux   50m
```

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

Recorded (third apply):

```text
"metallb" has been added to your repositories
Release "metallb" has been upgraded. Happy Helming!
NAME: metallb
LAST DEPLOYED: Sat Sep 19 17:21:33 2026
NAMESPACE: metallb-system
STATUS: deployed
REVISION: 3
DESCRIPTION: Upgrade complete
deployment.apps/metallb-controller condition met
daemon set "metallb-speaker" successfully rolled out
          - --lb-class=metallb.io/metallb
          - --lb-class=metallb.io/metallb
ipaddresspool.metallb.io/eg-poc2-services unchanged
ipaddresspool.metallb.io/eg-poc2-doors unchanged
l2advertisement.metallb.io/eg-poc2-l2 unchanged
```

### 3. Issue the certificate

One `Certificate` covers both names (the CN is the HTTP name). Gateways live in
`shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg-poc2 apply \
  -f demos/52-eg-poc2-metallb/20-certificate.yaml
kubectl --context kind-eg-poc2 -n shop wait certificate/eg-poc2-tls \
  --for=condition=Ready --timeout=90s
```

Recorded (third apply):

```text
certificate.cert-manager.io/eg-poc2-tls unchanged
certificate.cert-manager.io/eg-poc2-tls condition met
subject=CN=api.eg-poc2.poc.local
    DNS:api.eg-poc2.poc.local, DNS:grpc.eg-poc2.poc.local
notAfter=Dec 18 21:32:16 2026 GMT
sha256=92:B0:EF:5D:BA:EB:38:93:45:F3:59:FA:3D:4B:27:AE:9B:70:82:20:6B:39:D7:AF:54:B1:93:95:1F:01:B8:85
```

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

Recorded (third apply):

```text
envoyproxy.gateway.envoyproxy.io/http-gw-proxy unchanged
gateway.gateway.networking.k8s.io/http-gw configured
envoyproxy.gateway.envoyproxy.io/grpc-gw-proxy unchanged
gateway.gateway.networking.k8s.io/grpc-gw configured
gateway.gateway.networking.k8s.io/http-gw condition met
gateway.gateway.networking.k8s.io/grpc-gw condition met
  PASS   http-gw Programmed at 172.19.255.150                                   addr=172.19.255.150 svcIngress=172.19.255.150 Programmed=True R5 / R8 — Gateway address and Service ingress both equal 172.19.255.150
  PASS   grpc-gw Programmed at 172.19.255.151                                   addr=172.19.255.151 svcIngress=172.19.255.151 Programmed=True R5 / R8 — Gateway address and Service ingress both equal 172.19.255.151
```

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

Recorded (third apply):

```text
configmap/shop-db-init unchanged
deployment.apps/shop-db unchanged
service/shop-db unchanged
deployment "shop-db" successfully rolled out
deployment.apps/shopapi unchanged
service/shopapi unchanged
deployment.apps/shopapi condition met
deployment.apps/grpcdemo-v1 unchanged
service/grpc-v1 unchanged
deployment.apps/grpcdemo-v2 unchanged
service/grpc-v2 unchanged
deployment.apps/grpcdemo-v1 condition met
deployment.apps/grpcdemo-v2 condition met
httproute.gateway.networking.k8s.io/shop-api configured
grpcroute.gateway.networking.k8s.io/orders configured
kind-eg-poc2 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg-poc2 grpcroute/orders: all parents Accepted+ResolvedRefs
```

### 6. Prove the announcement

MetalLB answers ARP for the door; it does not add the address to the node's
`eth0`. kube-proxy delivers the packet. That is the visible difference from
demo 54.
Why the worker and not the control-plane: the Envoy Services are
`externalTrafficPolicy: Local` (Envoy Gateway's default; both door Services
are Local, measured), and MetalLB v0.16.0's L2 election keeps only nodes
with a serving endpoint of the Service (`speaker/layer2_controller.go:83-129`
`ShouldAnnounce`: `nodesWithEndpoint`) before the sha256(node#ip) ordering —
both Envoy pods run on `eg-poc2-worker`, so the election has one candidate
and the hash never decides. `internal/layer2/arp.go:73-118` replies to ARP
with the node's own MAC; nothing in layer2 calls netlink AddrAdd, so nothing
lands on eth0. Delivery is kube-proxy's iptables on the worker
(`KUBE-SERVICES -d 172.19.255.150/32 → KUBE-EXT-… → KUBE-SVL → KUBE-SEP
10.80.1.10:10080`); the control-plane's filter table DROPs it ("has no local
endpoints"). Move the pod and the announcement moves with it; `check.sh`
ties the two.

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.150
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.151
```

Recorded (third apply):

```text
---- arping -b -c 3 172.19.255.150 ----
ARPING 172.19.255.150 from 172.19.0.6 eth0
Unicast reply from 172.19.255.150 [36:20:3a:e4:50:8d] 0.081ms
Unicast reply from 172.19.255.150 [36:20:3a:e4:50:8d] 0.305ms
Unicast reply from 172.19.255.150 [36:20:3a:e4:50:8d] 0.071ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
MAC 36:20:3a:e4:50:8d → node eg-poc2-worker
---- ServiceL2Status / speaker (whole log, --tail=-1 --prefix) ----
CRD servicel2statuses.metallb.io: present
NAME       SERVICE                       NAMESPACE              NODE
l2-c4857   envoy-shop-grpc-gw-8c4f0319   envoy-gateway-system   eg-poc2-worker
l2-htcxz   envoy-shop-http-gw-fccf2727   envoy-gateway-system   eg-poc2-worker
---- Service events IPAllocated / announcing from node (172.19.255.150) ----
49m         Normal   IPAllocated         service/envoy-shop-http-gw-fccf2727                 Assigned IP ["172.19.255.150"]
49m         Normal   IPAllocated         service/envoy-shop-grpc-gw-8c4f0319                 Assigned IP ["172.19.255.151"]
49m         Normal   nodeAssigned        service/envoy-shop-grpc-gw-8c4f0319                 announcing from node "eg-poc2-worker" with protocol "layer2"
49m         Normal   nodeAssigned        service/envoy-shop-http-gw-fccf2727                 announcing from node "eg-poc2-worker" with protocol "layer2"
---- docker exec eg-poc2-worker ip -4 addr show eth0 (MetalLB does NOT add 172.19.255.150) ----
11: eth0@if125: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65535 qdisc noqueue state UP group default  link-netnsid 0
    inet 172.19.0.5/16 brd 172.19.255.255 scope global eth0
       valid_lft forever preferred_lft forever
172.19.255.150 NOT on eg-poc2-worker eth0 — MetalLB answers ARP for it, kube-proxy delivers it
```

Recorded (third apply):

```text
---- arping -b -c 3 172.19.255.151 ----
ARPING 172.19.255.151 from 172.19.0.6 eth0
Unicast reply from 172.19.255.151 [36:20:3a:e4:50:8d] 0.067ms
Unicast reply from 172.19.255.151 [36:20:3a:e4:50:8d] 0.110ms
Unicast reply from 172.19.255.151 [36:20:3a:e4:50:8d] 0.139ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
MAC 36:20:3a:e4:50:8d → node eg-poc2-worker
---- ServiceL2Status / speaker (whole log, --tail=-1 --prefix) ----
CRD servicel2statuses.metallb.io: present
NAME       SERVICE                       NAMESPACE              NODE
l2-c4857   envoy-shop-grpc-gw-8c4f0319   envoy-gateway-system   eg-poc2-worker
l2-htcxz   envoy-shop-http-gw-fccf2727   envoy-gateway-system   eg-poc2-worker
---- Service events IPAllocated / announcing from node (172.19.255.151) ----
49m         Normal   IPAllocated         service/envoy-shop-http-gw-fccf2727                 Assigned IP ["172.19.255.150"]
49m         Normal   IPAllocated         service/envoy-shop-grpc-gw-8c4f0319                 Assigned IP ["172.19.255.151"]
49m         Normal   nodeAssigned        service/envoy-shop-grpc-gw-8c4f0319                 announcing from node "eg-poc2-worker" with protocol "layer2"
49m         Normal   nodeAssigned        service/envoy-shop-http-gw-fccf2727                 announcing from node "eg-poc2-worker" with protocol "layer2"
---- docker exec eg-poc2-worker ip -4 addr show eth0 (MetalLB does NOT add 172.19.255.151) ----
11: eth0@if125: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65535 qdisc noqueue state UP group default  link-netnsid 0
    inet 172.19.0.5/16 brd 172.19.255.255 scope global eth0
       valid_lft forever preferred_lft forever
172.19.255.151 NOT on eg-poc2-worker eth0 — MetalLB answers ARP for it, kube-proxy delivers it
```

### 7. Run the gRPC matrix from the Mac

Fourteen cases through `grpcurl` v1.9.4 on the Mac: reflection, ListOrders on
h2c and TLS, GetOrder by method, ListOrders by metadata, a five-event stream,
NotFound, Unimplemented (T8a missing method on `Orders`, T8b unrouted
`Nope/Do`), DeadlineExceeded, response metadata, a bogus CA, door isolation,
Health. HTTPS and the Mac curls run first.
T8a reaches grpcdemo (the service-default rule routes it; the server's
`unknown method` is in `grpc-message`); T8b stops at Envoy, which answers a
gRPC request with no matching route as `HTTP/2 200` + `grpc-status: 12` and
no `grpc-message` — measured with an h2c prior-knowledge curl, not a 404
that grpcurl translates. T9's `DeadlineExceeded` is grpcurl's own deadline;
Envoy forwards `grpc-timeout`, and grpc-go resets the stream at the deadline
(`http2_server.go:600-612`, measured 1.004 s with the header vs 3.008 s
without). The server-side cancellation is real but not what the record
shows.

```bash
curl -s --resolve api.eg-poc2.poc.local:80:172.19.255.150 \
  -D - -o /dev/null http://api.eg-poc2.poc.local/healthz
curl -s --resolve api.eg-poc2.poc.local:443:172.19.255.150 \
  --cacert .tmp/eg-poc2-root-ca.crt \
  -D - -o /dev/null https://api.eg-poc2.poc.local/healthz
curl -s --resolve api.eg-poc2.poc.local:80:172.19.255.150 \
  -D - -H "Accept: application/json" \
  http://api.eg-poc2.poc.local/orders
go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 \
  -plaintext -authority grpc.eg-poc2.poc.local \
  172.19.255.151:80 shop.v1.Orders/ListOrders
```

Recorded (third apply):

```text
172.19             192.168.64.2       UGSc            bridge100
http://api.eg-poc2.poc.local/healthz @ 172.19.255.150:80 → 200 X-Served-By=eg-poc2 curl_rc=0
https://api.eg-poc2.poc.local/healthz @ 172.19.255.150:443 → 200 X-Served-By=eg-poc2 curl_rc=0
http://api.eg-poc2.poc.local/orders @ 172.19.255.150:80 → 200 X-Served-By=eg-poc2 curl_rc=0 body_head:
[{"id":1,"item":"keyboard","amount_cents":4999},{"id":2,"item":"mouse","amount_cents":1999},{"id":3,"item":"monitor","amount_cents":24900}]
T T1 expected=four RPCs via reflection observed=ListOrders GetOrder WatchOrders SlowOrder PASS
T T2 expected=3 orders version v1 served_by grpcdemo-v1- observed=v1 + three rows PASS
T T3 expected=TLS ListOrders v1 observed=v1 rc=0 PASS
T T4 expected=GetOrder id=2 version v2 observed=v2 PASS
T T5 expected=x-version v2 then default v1 observed=v2 then v1 PASS
T T6 expected=5 streamed events observed=events=5 PASS
T T7 expected=Code: NotFound observed=NotFound PASS
T T8a expected=Code: Unimplemented + unknown method observed=Unimplemented unknown method PASS
T T8b expected=Code: Unimplemented + empty Message observed=Unimplemented empty Message PASS
T T9 expected=Code: DeadlineExceeded observed=DeadlineExceeded PASS
T T10 expected=metadata x-served-by + x-version observed=both present PASS
T T11 expected=TLS fails with bogus CA observed=Failed to dial target host "172.19.255.151:443": tls: failed to verify certifica rc=1 PASS
T T12 expected=grpc@.150 not served; curl@.151 → 404 observed=grpcurl_rc=1 http=404 PASS
T T13 expected={"status": "SERVING"} for "" and shop.v1.Orders observed=SERVING SERVING PASS
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

The `:80` listener has a hostname and no redirect, so the browser works over
plain http. Chrome maps the name; no hosts file is needed for the shot. The
wait is for the PNG (size stable across two polls); the artefact on disk is
the result (gotcha [#121](../../docs/GOTCHAS.md#121)).

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --window-size=1000,500 \
  --user-data-dir=<tmp> \
  --host-resolver-rules="MAP api.eg-poc2.poc.local 172.19.255.150" \
  --screenshot=demos/52-eg-poc2-metallb/output/browser.png \
  http://api.eg-poc2.poc.local/orders
```

Recorded (third apply):

```text
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --disable-gpu --no-first-run --window-size=1000,500 --user-data-dir=<tmp> --host-resolver-rules="MAP api.eg-poc2.poc.local 172.19.255.150" --screenshot=/Users/olasumbo/gitRepos/cilium-implementation-poc/demos/52-eg-poc2-metallb/output/browser.png http://api.eg-poc2.poc.local/orders
screenshot written after 5.2 s; chrome_rc=0
demos/52-eg-poc2-metallb/output/browser.png: PNG image data, 1000 x 500, 8-bit/color RGB, non-interlaced
```

![the orders page](output/browser.png)

For a real browser, add the hosts block (the script only prints it; the `tee`
writes it):

```bash
demos/52-eg-poc2-metallb/hosts-entries.sh | sudo tee -a /etc/hosts
```

Recorded (third apply):

```text
# ---- cilium-kind-poc demo52 (generated 2026-09-19T22:21Z by demos/52-eg-poc2-metallb/hosts-entries.sh) ----
172.19.255.150  api.eg-poc2.poc.local
172.19.255.151  grpc.eg-poc2.poc.local
# ---- end cilium-kind-poc demo52 ----
```

Recorded (third apply):

```text
DOOR       ADDRESS          PROG   CLASS                  ANNOUNCED_BY           HTTP_or_GRPC
http-gw    172.19.255.150   True   metallb.io/metallb     eg-poc2-worker         HTTP 200/eg-poc2
grpc-gw    172.19.255.151   True   metallb.io/metallb     eg-poc2-worker         GRPC SERVING
```

## Checks

```bash
demos/52-eg-poc2-metallb/check.sh
```

`check.sh` at `2026-09-19T22:22:03Z`: 21 PASS, 0 FAIL.

Recorded (third apply):

```text
### 2026-09-19T22:22:03Z
$ demos/52-eg-poc2-metallb/check.sh
== demo 52 — one cluster, MetalLB, two Gateways (HTTP isolated from gRPC)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   MetalLB controller Available + speaker DS                              Available=True ready=2/2                             R5 — controller Available, speaker N/N (chart 0.16.0, --lb-class)
  PASS   http-gw Programmed at 172.19.255.150                                   addr=172.19.255.150 svcIngress=172.19.255.150 Programmed=True R5 / R8 — Gateway address and Service ingress both equal 172.19.255.150
  PASS   grpc-gw Programmed at 172.19.255.151                                   addr=172.19.255.151 svcIngress=172.19.255.151 Programmed=True R5 / R8 — Gateway address and Service ingress both equal 172.19.255.151
  PASS   both Envoy Services carry the class                                    http=metallb.io/metallb grpc=metallb.io/metallb      D11 — EnvoyProxy names metallb.io/metallb on both doors
  PASS   ARP http-gw 172.19.255.150 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc2-worker           R5 / R8 — arping -b 3 of 3 from ONE MAC
  PASS   ARP grpc-gw 172.19.255.151 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc2-worker           R5 / R8 — arping -b 3 of 3 from ONE MAC
  PASS   VIP 172.19.255.150 NOT on any node's eth0                              absent on all nodes                                  R5 — MetalLB answers ARP; kube-proxy delivers; no /32 on eth0
  PASS   ServiceL2Status / announcing from node                                 envoy-shop-grpc-gw=eg-poc2-worker envoy-shop-http-gw=eg-poc2-worker R5 — MetalLB names the announcing node for both doors (ETP Local: a node with the Envoy pod)
  PASS   http://api.eg-poc2.poc.local 200 + X-Served-By                         http_code=200 X-Served-By=eg-poc2                    R8 — 200 and X-Served-By=eg-poc2
  PASS   https://api.eg-poc2.poc.local 200                                      http_code=200                                        R8 — 200 against the lab root
  PASS   http://api.eg-poc2.poc.local /orders 200 (the page behind the door)    http_code=200 items=3                                the page behind the door — 200 and a JSON array (≥ 1)
  PASS   gRPC Health "" SERVING                                                 SERVING                                              R10 — exact "status": "SERVING"
  PASS   gRPC ListOrders v1                                                     version=v1                                           R10 — service default → grpc-v1
  PASS   gRPC GetOrder v2                                                       version=v2                                           R10 — method match → grpc-v2
  PASS   gRPC ListOrders x-version v2                                           version=v2                                           R10 — metadata match → grpc-v2
  PASS   gRPC WatchOrders 5 events                                              events=5                                             R10 — streamed OrderEvent × 5
  PASS   gRPC GetOrder NotFound                                                 NotFound                                             R10 — unknown id → Code: NotFound
  PASS   gRPC NoSuchMethod Unimplemented                                        Unimplemented unknown method                         R10 — missing method → Code: Unimplemented + unknown method
  PASS   gRPC unrouted service Unimplemented                                    Unimplemented empty Message                          R10 — unrouted service → Code: Unimplemented + empty Message
  PASS   gRPC SlowOrder DeadlineExceeded                                        DeadlineExceeded                                     R10 — -max-time 1 vs delay_ms 3000
  PASS   gRPC TLS ListOrders                                                    version=v1                                           R10 — TLS ListOrders against the lab root
demo 52 check: 0 FAIL
```

## What is deliberately not here

- Fail cases (the class-less exhibit, the silent-`externalIPs` experiment)
  live in [demo 51](../51-eg-kube-vip/README.md).
- The VIP move lives in [demo 51](../51-eg-kube-vip/README.md).
- kube-vip is demo 54 (the same two-door design on `eg-poc1`).
- MetalLB beside kube-vip on `eg1`/`eg2` (issue #57) is superseded by this
  one-cluster lab.
- The lab has no DNS for `.poc.local`: clients use `--resolve`, `-authority`,
  or Chrome's `--host-resolver-rules`.

## Runs that did not go to plan

The first apply (`2026-09-19T21:31:53Z`) asked T8 through reflection.
grpcurl refused client-side; the committed descriptors in `probe/` send
the RPC. Recorded (first apply):

```text
Error invoking method "shop.v1.Orders/NoSuchMethod": service "shop.v1.Orders" does not include a method named "NoSuchMethod"
```

## Clean up

```bash
demos/52-eg-poc2-metallb/cleanup.sh
scripts/eg-down.sh
```

cleanup.sh removes the routes, Gateways, EnvoyProxies, app, certificate,
waits for the door Services to be gone, empties the pools while their CRDs
still exist (chart 0.16.0 templates them, so the uninstall removes them), then
uninstalls MetalLB and deletes `shop` and `metallb-system`. It leaves
`eg-poc2`, Envoy Gateway, `GatewayClass eg`, cert-manager, and
`.tmp/eg-poc2-root-ca.crt`. eg-down.sh deletes the cluster.
