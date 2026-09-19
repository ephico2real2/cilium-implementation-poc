# Demo 54 — one cluster, kube-vip, two Gateways

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

This is the one-cluster proof on `eg-poc1`: stock networking, Envoy Gateway,
kube-vip, HTTP and gRPC through two isolated doors, reached from the Mac and
the browser. Demo 51 is the two-cluster lab with the fail cases. The operator,
2026-09-19: *"We only want to show that it works and document what we did in
docker and proof that kube-vip can do the L2 announcements and that the
application is accessible externally from our clients running on the macbook
and in the browser."* Tracking: [enhancement 007](../../enhancements/007-envoy-gateway-lab.md)
revision 2, §3.1 / §4 row 2b, issue
[#53](https://github.com/ephico2real2/cilium-implementation-poc/issues/53).

## Summary context — the enterprise case

One kind cluster, stock networking (kindnet + kube-proxy iptables, no Cilium), Envoy Gateway, kube-vip.
Two doors: `http-gw` at `172.19.255.100` (HTTP/HTTPS for `api.eg-poc1.poc.local`); `grpc-gw` at
`172.19.255.101` (h2c/TLS for `grpc.eg-poc1.poc.local`). No HTTPRoute on the gRPC door, no GRPCRoute
on the HTTP door. Each `EnvoyProxy` names `loadBalancerClass: kube-vip.io/kube-vip-class` and pins
`kube-vip.io/loadbalancerIPs` (D11) in the same file before its Gateway. The HTTP `:80` has a hostname
and no redirect. The lab root is `.tmp/eg-poc1-root-ca.crt`. The path a request takes is in the
[RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`clusters/eg/kube-vip-rbac.yaml`](../../clusters/eg/kube-vip-rbac.yaml), [`kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml), [`kube-vip-cloud-provider.yaml`](../../clusters/eg/kube-vip-cloud-provider.yaml) | **one source of truth** — not copied |
| [`10-kubevip-cm.yaml`](10-kubevip-cm.yaml) | the `kubevip` ConfigMap (`range-envoy-gateway-system` `.100–.110`, `range-default` `.72–.79`) |
| [`00-namespace.yaml`](00-namespace.yaml) | namespace `shop` |
| [`20-certificate.yaml`](20-certificate.yaml) | `Certificate` `eg-poc1-tls`, CN `api.eg-poc1.poc.local`, two dnsNames, 90d/30d |
| [`30-gateways.yaml`](30-gateways.yaml) | EnvoyProxy then Gateway, twice: `http-gw` `.100`, `grpc-gw` `.101` |
| [`40-app.yaml`](40-app.yaml) | `shopapi` + `grpc` (`routedemo:local -mode grpc`, `appProtocol: kubernetes.io/h2c`) |
| [`45-shop-db.yaml`](45-shop-db.yaml) | `shop-db` (postgres:16-alpine, emptyDir; local to this demo — not enhancement 002 R3) |
| [`50-routes.yaml`](50-routes.yaml) | `HTTPRoute` shop-api → http-gw only; `GRPCRoute` grpc → grpc-gw only |
| [`apply.sh`](apply.sh) | idempotent; every step through `scripts/record.sh` |
| [`check.sh`](check.sh) | at most 15 PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | doors, app, kube-vip, `shop` — leaves the cluster |
| [`hosts-entries.sh`](hosts-entries.sh) | the two names from live Gateway addresses; never writes `/etc/hosts` |
| [`GUIDE.md`](GUIDE.md) | hosts-block prerequisite (the one sudo step) and five read-only exercises |

The lab root PEM is **`.tmp/eg-poc1-root-ca.crt`** (gitignored, issue #60).

## Run it

From the repo root. poc1/poc2 stay paused. Bring the cluster up first:

```bash
scripts/eg-up.sh eg-poc1
demos/54-eg-poc1-kube-vip/apply.sh
demos/54-eg-poc1-kube-vip/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never truncate).

## What was recorded

The fourth apply (`2026-09-19T15:12:28Z`, transcript lines 997–1271).

### 1. Build the lab

The up script creates the cluster, the standard-channel CRDs, Envoy Gateway,
`GatewayClass eg`, cert-manager, and this lab's root. apply.sh then records the
`kind-eg` bridge, the two nodes, and stock networking (kindnet + kube-proxy
`iptables`; no Cilium).

```bash
scripts/eg-net.sh
scripts/eg-up.sh eg-poc1
```

Recorded (fourth apply):

```text
---- kind-eg IPv4 (IPv6 IPRange prints invalid Prefix; skip that block) ----
Subnet=172.19.0.0/16 IPRange=172.19.0.0/17 Gateway=172.19.0.1
---- eg-poc1 nodes on kind-eg (IPv4 + MAC) ----
eg-poc1-control-plane Up 2 hours
eg-poc1-worker Up 2 hours
eg-poc1-control-plane 172.19.0.2 e6:61:1d:ac:15:3a
eg-poc1-worker 172.19.0.3 fa:1f:d6:0f:1e:ae
---- kubectl get nodes -o wide ----
NAME                    STATUS   ROLES           AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION            CONTAINER-RUNTIME
eg-poc1-control-plane   Ready    control-plane   122m   v1.36.4   172.19.0.2    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg-poc1-worker          Ready    <none>          122m   v1.36.4   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
---- stock networking: kube-proxy mode + kindnet DS ----
    mode: iptables
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kindnet      2         2         2       2            2           kubernetes.io/os=linux   122m
kube-proxy   2         2         2       2            2           kubernetes.io/os=linux   122m
```

### 2. Install kube-vip

The DaemonSet, cloud-provider and RBAC live under `clusters/eg/` (one source of
truth, not copied). The ConfigMap gives the doors `.100–.110` and services
`.72–.79`; kube-vip runs class-only.

```bash
kubectl --context kind-eg-poc1 apply \
  -f clusters/eg/kube-vip-rbac.yaml \
  -f clusters/eg/kube-vip-ds.yaml \
  -f clusters/eg/kube-vip-cloud-provider.yaml \
  -f demos/54-eg-poc1-kube-vip/10-kubevip-cm.yaml
```

Recorded (fourth apply):

```text
serviceaccount/kube-vip unchanged
clusterrole.rbac.authorization.k8s.io/system:kube-vip-role unchanged
clusterrolebinding.rbac.authorization.k8s.io/system:kube-vip-binding unchanged
daemonset.apps/kube-vip-ds unchanged
serviceaccount/kube-vip-cloud-controller unchanged
clusterrole.rbac.authorization.k8s.io/system:kube-vip-cloud-controller-role unchanged
clusterrolebinding.rbac.authorization.k8s.io/system:kube-vip-cloud-controller-binding unchanged
deployment.apps/kube-vip-cloud-provider unchanged
configmap/kubevip unchanged
daemon set "kube-vip-ds" successfully rolled out
deployment.apps/kube-vip-cloud-provider condition met
```

### 3. Issue the certificate

One `Certificate` covers both names (the CN is the HTTP name). Gateways live in
`shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/20-certificate.yaml
kubectl --context kind-eg-poc1 -n shop wait certificate/eg-poc1-tls \
  --for=condition=Ready --timeout=90s
```

Recorded (fourth apply):

```text
certificate.cert-manager.io/eg-poc1-tls unchanged
certificate.cert-manager.io/eg-poc1-tls condition met
subject=CN=api.eg-poc1.poc.local
    DNS:api.eg-poc1.poc.local, DNS:grpc.eg-poc1.poc.local
notAfter=Dec 18 13:14:14 2026 GMT
sha256=15:4B:20:78:0E:BD:71:EB:C4:18:AF:B0:6C:68:53:C3:A6:54:75:B5:55:7C:7F:DF:8B:7C:38:A8:84:6A:4E:2D
```

### 4. Create the two doors

Each EnvoyProxy names `loadBalancerClass: kube-vip.io/kube-vip-class` and pins
the address; it sits in the same file before its Gateway because the class is
immutable.

```bash
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/30-gateways.yaml
kubectl --context kind-eg-poc1 -n shop wait --for=condition=Programmed \
  gateway/http-gw --timeout=180s
kubectl --context kind-eg-poc1 -n shop wait --for=condition=Programmed \
  gateway/grpc-gw --timeout=180s
```

Recorded (fourth apply):

```text
envoyproxy.gateway.envoyproxy.io/http-gw-proxy unchanged
gateway.gateway.networking.k8s.io/http-gw configured
envoyproxy.gateway.envoyproxy.io/grpc-gw-proxy unchanged
gateway.gateway.networking.k8s.io/grpc-gw configured
gateway.gateway.networking.k8s.io/http-gw condition met
gateway.gateway.networking.k8s.io/grpc-gw condition met
```

### 5. Deploy the apps and routes

`shop-db` is this demo's postgres (emptyDir). `shopapi:local` and
`routedemo:local -mode grpc` sit behind the doors. The HTTPRoute parents
`http-gw` only; the GRPCRoute parents `grpc-gw` only.

```bash
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/45-shop-db.yaml
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/40-app.yaml
kubectl --context kind-eg-poc1 apply -f demos/54-eg-poc1-kube-vip/50-routes.yaml
```

Recorded (fourth apply):

```text
configmap/shop-db-init unchanged
deployment.apps/shop-db unchanged
service/shop-db unchanged
deployment "shop-db" successfully rolled out
deployment.apps/shopapi unchanged
service/shopapi unchanged
deployment.apps/grpc unchanged
service/grpc unchanged
deployment.apps/shopapi condition met
deployment.apps/grpc condition met
httproute.gateway.networking.k8s.io/shop-api configured
grpcroute.gateway.networking.k8s.io/grpc configured
kind-eg-poc1 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg-poc1 grpcroute/grpc: all parents Accepted+ResolvedRefs
```

### 6. Prove the announcement

For each door, apply.sh records a broadcast arping from `busybox:1.36` on
`kind-eg`, maps the reply MAC to a node, shows the `/32` on that node's
`eth0`, and reads the kube-vip DaemonSet log (`--tail=-1 --prefix`). Why both
VIPs sit on `eg-poc1-worker` and why `ip` prints `deprecated` is in
[`docs/REVIEW_DEMO54.md`](../../docs/REVIEW_DEMO54.md).

```bash
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.100
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -b -c 3 -I eth0 172.19.255.101
docker exec eg-poc1-worker ip -4 addr show eth0
```

Recorded (fourth apply):

```text
---- arping -b -c 3 172.19.255.100 ----
ARPING 172.19.255.100 from 172.19.0.4 eth0
Unicast reply from 172.19.255.100 [fa:1f:d6:0f:1e:ae] 0.005ms
Unicast reply from 172.19.255.100 [fa:1f:d6:0f:1e:ae] 0.014ms
Unicast reply from 172.19.255.100 [fa:1f:d6:0f:1e:ae] 0.010ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
MAC fa:1f:d6:0f:1e:ae → node eg-poc1-worker
---- docker exec eg-poc1-worker ip -4 addr show eth0 ----
11: eth0@if21: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65535 qdisc noqueue state UP group default  link-netnsid 0
    inet 172.19.0.3/16 brd 172.19.255.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet 172.19.255.100/32 scope global deprecated eth0
       valid_lft forever preferred_lft forever
    inet 172.19.255.101/32 scope global deprecated eth0
       valid_lft forever preferred_lft forever
---- kube-vip DS logs for 172.19.255.100 (adding VIP / successful add IP; whole log, pod-prefixed) ----
[pod/kube-vip-ds-lm6zw/kube-vip] 2026-09-19T13:14:15.362709375Z 2026/09/19 13:14:15 INFO new instance namespace=envoy-gateway-system service=envoy-shop-http-gw-fccf2727 addresses=[172.19.255.100] hostnames=[]
[pod/kube-vip-ds-lm6zw/kube-vip] 2026-09-19T13:14:15.362905875Z 2026/09/19 13:14:15 INFO (svcs) adding VIP ip=172.19.255.100 interface=eth0 namespace=envoy-gateway-system name=envoy-shop-http-gw-fccf2727
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:15.362849167Z 2026/09/19 13:14:15 INFO new instance namespace=envoy-gateway-system service=envoy-shop-http-gw-fccf2727 addresses=[172.19.255.100] hostnames=[]
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:15.363006000Z 2026/09/19 13:14:15 INFO (svcs) adding VIP ip=172.19.255.100 interface=eth0 namespace=envoy-gateway-system name=envoy-shop-http-gw-fccf2727
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:26.716945797Z 2026/09/19 13:14:26 INFO successful add IP address=172.19.255.100
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:26.716946422Z 2026/09/19 13:14:26 INFO layer 2 broadcaster starting IP=172.19.255.100 device=eth0
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:26.716946922Z 2026/09/19 13:14:26 INFO [ARP manager] inserting ARP/NDP instance name=172.19.255.100/32-eth0
adding VIP for 172.19.255.100: present
successful add IP for 172.19.255.100: present
layer 2 broadcaster starting for 172.19.255.100: present
```

Recorded (fourth apply):

```text
---- arping -b -c 3 172.19.255.101 ----
ARPING 172.19.255.101 from 172.19.0.4 eth0
Unicast reply from 172.19.255.101 [fa:1f:d6:0f:1e:ae] 0.006ms
Unicast reply from 172.19.255.101 [fa:1f:d6:0f:1e:ae] 0.026ms
Unicast reply from 172.19.255.101 [fa:1f:d6:0f:1e:ae] 0.015ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
MAC fa:1f:d6:0f:1e:ae → node eg-poc1-worker
---- docker exec eg-poc1-worker ip -4 addr show eth0 ----
11: eth0@if21: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65535 qdisc noqueue state UP group default  link-netnsid 0
    inet 172.19.0.3/16 brd 172.19.255.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet 172.19.255.100/32 scope global deprecated eth0
       valid_lft forever preferred_lft forever
    inet 172.19.255.101/32 scope global deprecated eth0
       valid_lft forever preferred_lft forever
---- kube-vip DS logs for 172.19.255.101 (adding VIP / successful add IP; whole log, pod-prefixed) ----
[pod/kube-vip-ds-lm6zw/kube-vip] 2026-09-19T13:14:15.561115792Z 2026/09/19 13:14:15 INFO new instance namespace=envoy-gateway-system service=envoy-shop-grpc-gw-8c4f0319 addresses=[172.19.255.101] hostnames=[]
[pod/kube-vip-ds-lm6zw/kube-vip] 2026-09-19T13:14:15.561421625Z 2026/09/19 13:14:15 INFO (svcs) adding VIP ip=172.19.255.101 interface=eth0 namespace=envoy-gateway-system name=envoy-shop-grpc-gw-8c4f0319
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:15.561219334Z 2026/09/19 13:14:15 INFO new instance namespace=envoy-gateway-system service=envoy-shop-grpc-gw-8c4f0319 addresses=[172.19.255.101] hostnames=[]
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:15.561319334Z 2026/09/19 13:14:15 INFO (svcs) adding VIP ip=172.19.255.101 interface=eth0 namespace=envoy-gateway-system name=envoy-shop-grpc-gw-8c4f0319
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:26.727077672Z 2026/09/19 13:14:26 INFO successful add IP address=172.19.255.101
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:26.727190839Z 2026/09/19 13:14:26 INFO layer 2 broadcaster starting IP=172.19.255.101 device=eth0
[pod/kube-vip-ds-xm9rf/kube-vip] 2026-09-19T13:14:26.727198047Z 2026/09/19 13:14:26 INFO [ARP manager] inserting ARP/NDP instance name=172.19.255.101/32-eth0
adding VIP for 172.19.255.101: present
successful add IP for 172.19.255.101: present
layer 2 broadcaster starting for 172.19.255.101: present
```

### 7. Reach it from the Mac

HTTPS verifies the leaf against `.tmp/eg-poc1-root-ca.crt` and does not skip
verification. grpcurl runs on the Mac via Go; there is no binary to install.
Isolation is one call each way: grpcurl at `.100` and curl of the API host at
`.101`.

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

Recorded (fourth apply):

```text
172.19             192.168.64.2       UGSc            bridge100
http://api.eg-poc1.poc.local/healthz @ 172.19.255.100:80 → 200 X-Served-By=eg-poc1 curl_rc=0
https://api.eg-poc1.poc.local/healthz @ 172.19.255.100:443 → 200 X-Served-By=eg-poc1 curl_rc=0
http://api.eg-poc1.poc.local/orders @ 172.19.255.100:80 → 200 X-Served-By=eg-poc1 curl_rc=0 body_head:
[{"id":1,"item":"keyboard","amount_cents":4999},{"id":2,"item":"mouse","amount_cents":1999},{"id":3,"item":"monitor","amount_cents":24900}]
-- gRPC h2c grpc.eg-poc1.poc.local 172.19.255.101:80
{
  "status": "SERVING"
}
grpcurl_h2c_rc=0
-- gRPC TLS grpc.eg-poc1.poc.local 172.19.255.101:443
{
  "status": "SERVING"
}
grpcurl_tls_rc=0
-- gRPC list (reflection) grpc.eg-poc1.poc.local 172.19.255.101:80
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
grpcurl_list_rc=0
-- isolation: grpcurl against HTTP door 172.19.255.100:80 with grpc authority (expect not SERVING)
Error invoking method "grpc.health.v1.Health/Check": failed to query for service descriptor "grpc.health.v1.Health": server does not support the reflection API
exit status 1
isolation_grpcurl_rc=1
-- isolation: curl http://api.eg-poc1.poc.local/healthz at gRPC door 172.19.255.101:80 (expect not 200)
isolation_http_code=404 curl_rc=0
DOOR       ADDRESS          PROG   CLASS                        ANNOUNCED_BY           HTTP_or_GRPC
http-gw    172.19.255.100   True   kube-vip.io/kube-vip-class   eg-poc1-worker         HTTP 200/eg-poc1
grpc-gw    172.19.255.101   True   kube-vip.io/kube-vip-class   eg-poc1-worker         GRPC SERVING
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
  --host-resolver-rules="MAP api.eg-poc1.poc.local 172.19.255.100" \
  --screenshot=demos/54-eg-poc1-kube-vip/output/browser.png \
  http://api.eg-poc1.poc.local/orders
```

Recorded (fourth apply):

```text
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --disable-gpu --no-first-run --window-size=1000,500 --user-data-dir=<tmp> --host-resolver-rules="MAP api.eg-poc1.poc.local 172.19.255.100" --screenshot=/Users/olasumbo/gitRepos/cilium-implementation-poc/demos/54-eg-poc1-kube-vip/output/browser.png http://api.eg-poc1.poc.local/orders
screenshot written after 2.0 s; chrome_rc=0
demos/54-eg-poc1-kube-vip/output/browser.png: PNG image data, 1000 x 500, 8-bit/color RGB, non-interlaced
```

![the orders page](output/browser.png)

For a real browser, add the hosts block (the script only prints it; the `tee`
writes it):

```bash
demos/54-eg-poc1-kube-vip/hosts-entries.sh | sudo tee -a /etc/hosts
```

Recorded (fourth apply):

```text
# ---- cilium-kind-poc demo54 (generated 2026-09-19T15:12Z by demos/54-eg-poc1-kube-vip/hosts-entries.sh) ----
172.19.255.100  api.eg-poc1.poc.local
172.19.255.101  grpc.eg-poc1.poc.local
# ---- end cilium-kind-poc demo54 ----
```

## Checks

`check.sh` at `2026-09-19T15:12:49Z`: 15 PASS, 0 FAIL.

Recorded (fourth apply):

```text
### 2026-09-19T15:12:49Z
$ demos/54-eg-poc1-kube-vip/check.sh
== demo 54 — one cluster, kube-vip, two Gateways (HTTP isolated from gRPC)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   kube-vip DS ready                                                      ready=2/2                                            R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)
  PASS   kube-vip-cloud-provider Available                                      Available=True                                       R4 — cloud-provider v0.0.12 Available
  PASS   http-gw Programmed at 172.19.255.100                                   addr=172.19.255.100 svcIngress=172.19.255.100 Programmed=True R4 / R8 — Gateway address and Service ingress both equal 172.19.255.100
  PASS   grpc-gw Programmed at 172.19.255.101                                   addr=172.19.255.101 svcIngress=172.19.255.101 Programmed=True R4 / R8 — Gateway address and Service ingress both equal 172.19.255.101
  PASS   both Envoy Services carry the class                                    http=kube-vip.io/kube-vip-class grpc=kube-vip.io/kube-vip-class D11 — EnvoyProxy names kube-vip.io/kube-vip-class on both doors
  PASS   ARP http-gw 172.19.255.100 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc1-worker           R4 / R8 — arping 3 of 3 from ONE MAC
  PASS   ARP grpc-gw 172.19.255.101 one responder 3/3                           replies=3 unique_mac=1 node=eg-poc1-worker           R4 / R8 — arping 3 of 3 from ONE MAC
  PASS   VIP 172.19.255.100 on the elected node's eth0                          node=eg-poc1-worker /32                              R4 — kube-vip announces the /32 on the elected node's eth0
  PASS   VIP 172.19.255.101 on the elected node's eth0                          node=eg-poc1-worker /32                              R4 — kube-vip announces the /32 on the elected node's eth0
  PASS   http://api.eg-poc1.poc.local 200 + X-Served-By                         http_code=200 X-Served-By=eg-poc1                    R8 — 200 and X-Served-By=eg-poc1
  PASS   https://api.eg-poc1.poc.local 200                                      http_code=200                                        R8 — 200 against the lab root
  PASS   http://api.eg-poc1.poc.local /orders 200 (the page behind the door)    http_code=200 items=3                                the page behind the door — 200 and a JSON array (≥ 1)
  PASS   gRPC h2c grpc.eg-poc1.poc.local @ 172.19.255.101:80                    SERVING                                              R10 — grpcurl -plaintext Health/Check → SERVING
  PASS   gRPC TLS grpc.eg-poc1.poc.local @ 172.19.255.101:443                   SERVING                                              R10 — grpcurl -cacert Health/Check → SERVING
  PASS   stock networking                                                       kube-proxy=iptables cilium_ds=0 cilium_crd=0         R2 — kube-proxy iptables, 0 Cilium DS/CRD
demo 54 check: 0 FAIL
```

## What is deliberately not here

- Fail cases (the class-less exhibit, the silent-`externalIPs` experiment) live in [demo 51](../51-eg-kube-vip/README.md).
- The VIP move lives in [demo 51](../51-eg-kube-vip/README.md).
- MetalLB is demo 52 (enhancement 007 §4).
- The lab has no DNS for `.poc.local`: clients use `--resolve`, `-authority`, or Chrome's `--host-resolver-rules`.

## Runs that did not go to plan

The first apply (`2026-09-19T13:14Z`) found no `172.19` route on the Mac.
Every client timed out while the cluster was healthy — [gotcha #120](../../docs/GOTCHAS.md#120).
Recorded (first apply):

```text
no 172.19 route on this Mac — the clients below will fail until:
```

The second apply (`2026-09-19T14:09Z`) had the route. `/healthz` and gRPC
worked; `/orders` returned the body below because shopapi's default `DB_URL`
points at the mesh lab's database. [`45-shop-db.yaml`](45-shop-db.yaml) is this
demo's postgres. Recorded (second apply):

```text
failed to connect to `user=shop database=shop`: hostname resolving error: lookup db-service.poc.local on 10.71.0.10:53: dial udp 10.71.0.10:53: i/o timeout
```

The third apply (`2026-09-19T14:17Z`) wrapped Chrome in `timeout 60`. Chrome
wrote the PNG and did not exit — [gotcha #121](../../docs/GOTCHAS.md#121).
Recorded (third apply):

```text
timeout 60 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --disable-gpu --no-first-run --window-size=1000,500 --user-data-dir=<tmp> --host-resolver-rules="MAP api.eg-poc1.poc.local 172.19.255.100" --screenshot=/Users/olasumbo/gitRepos/cilium-implementation-poc/demos/54-eg-poc1-kube-vip/output/browser.png http://api.eg-poc1.poc.local/orders
chrome_rc=124 (124 = killed by the timeout after writing the file)
```

## Clean up

```bash
demos/54-eg-poc1-kube-vip/cleanup.sh
scripts/eg-down.sh
```

cleanup.sh removes the routes, app, Gateways + EnvoyProxies, certificate +
secret, kube-vip, and namespace `shop`. It leaves `eg-poc1`, Envoy Gateway,
`GatewayClass eg`, cert-manager, and `.tmp/eg-poc1-root-ca.crt`. eg-down.sh
deletes the cluster.
