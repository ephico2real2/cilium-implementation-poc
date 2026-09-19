# Demo 51 — Envoy Gateway with kube-vip, alone

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

**Where this sits in the whole:** [enhancement 007](../../enhancements/007-envoy-gateway-lab.md)
revision 2, §1 R4/R7/R8/R10, §3.1 the address plan, §3.3 the static-address
experiment, §3.4 the doors, §4 row 2, D3/D8/D10/D11; tracking issue
[#56](https://github.com/ephico2real2/cilium-implementation-poc/issues/56)
(parent [#53](https://github.com/ephico2real2/cilium-implementation-poc/issues/53)).
Demo 50 built the clusters and the controller. This demo hangs kube-vip on
them and opens the doors. MetalLB is **not** installed — that is demo 52.

No docker build (gotcha #118 — loading existing `shopapi:local` and
`routedemo:local` onto the nodes is not a build). poc1/poc2 stay paused
(gotcha #119). The `kind` network is not touched.

## Summary context — the enterprise case

The contract a team learns: the `EnvoyProxy` attached to their Gateway names
the load balancer (`envoyService.loadBalancerClass:
kube-vip.io/kube-vip-class`) and pins the address
(`kube-vip.io/loadbalancerIPs`). kube-vip runs class-only, so a Service that
forgets the class stays `<pending>` — `probe-noclass` in `shop` is the
standing exhibit (D11). The class is immutable on the generated Service;
each `EnvoyProxy` is created in the same file, before the Gateway.
`Gateway.spec.addresses` alone writes `externalIPs` and nobody answers ARP
(R7). Both fields are set so `status.addresses` stays honest and the wire
answers.

## Files

| File | What |
|---|---|
| [`clusters/eg/kube-vip-rbac.yaml`](../../clusters/eg/kube-vip-rbac.yaml), [`kube-vip-ds.yaml`](../../clusters/eg/kube-vip-ds.yaml), [`kube-vip-cloud-provider.yaml`](../../clusters/eg/kube-vip-cloud-provider.yaml) | **one source of truth** — phase 0's working objects (v1.2.4 ARP + `svc_election` + `lb_class_only`, no taint; cloud-provider v0.0.12 with the class env). Not copied |
| [`10-kubevip-cm-eg1.yaml`](10-kubevip-cm-eg1.yaml) / [`10-kubevip-cm-eg2.yaml`](10-kubevip-cm-eg2.yaml) | the `kubevip` ConfigMap per cluster (§3.1) |
| [`00-namespaces.yaml`](00-namespaces.yaml) | namespace `shop` |
| [`15-probe-noclass.yaml`](15-probe-noclass.yaml) | D11 standing exhibit — class-less LoadBalancer, stays `<pending>` |
| [`20-certificates.yaml`](20-certificates.yaml) | one `Certificate` `eg-tls` in `shop`, CN `api.eg.poc.local`, six SANs |
| [`30-gateways-eg1.yaml`](30-gateways-eg1.yaml) / [`30-gateways-eg2.yaml`](30-gateways-eg2.yaml) | EnvoyProxy then Gateway, per-cluster door + VIP door. apply.sh / the move script apply the VIP pair to one cluster at a time |
| [`40-app.yaml`](40-app.yaml) | `shopapi` + `grpc` (`routedemo:local -mode grpc`, `appProtocol: kubernetes.io/h2c`) |
| [`50-routes-eg1.yaml`](50-routes-eg1.yaml) / [`50-routes-eg2.yaml`](50-routes-eg2.yaml) | per-cluster routes always; VIP routes only where `eg-vip-gw` is |
| [`apply.sh`](apply.sh) | idempotent; every step through `scripts/record.sh` |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`cleanup.sh`](cleanup.sh) | doors, app, kube-vip, `shop` — leaves demo 50's clusters |
| [`hosts-entries.sh`](hosts-entries.sh) | the six names from live Gateway addresses; never writes `/etc/hosts` |
| [`scripts/eg-vip-move.sh`](../../scripts/eg-vip-move.sh) | delete-other-first; `--status` prints who has `.16` and the ARP responder |
| [`GUIDE.md`](GUIDE.md) | five exercises |
| [`output/transcript.txt`](output/transcript.txt) | every applied command |

The lab root PEM is **`.tmp/eg-root-ca.crt`** (gitignored, issue #60).

## Run it

From the repo root. poc1/poc2 stay paused. eg1 and eg2 are already up.

```bash
demos/51-eg-kube-vip/apply.sh
demos/51-eg-kube-vip/check.sh
```

`VIP_HOME` defaults to `eg1`. Every command is recorded through
`scripts/record.sh` into [`output/transcript.txt`](output/transcript.txt)
(append, never truncate).

## What was recorded

The last apply is `2026-09-19T00:40:23Z` (`VIP_HOME=eg1`). Each step below
quotes that apply.

### 1. Bring up the two-cluster lab

```bash
kubectl --context kind-eg1 get --raw /readyz
kubectl --context kind-eg2 get --raw /readyz
```

Recorded (last apply):

```text
ok
```

### 2. Install kube-vip in both clusters

```bash
kubectl --context kind-eg1 -n kube-system rollout status ds/kube-vip-ds --timeout=120s
kubectl --context kind-eg1 -n kube-system wait deploy/kube-vip-cloud-provider --for=condition=Available --timeout=120s
kubectl --context kind-eg2 -n kube-system rollout status ds/kube-vip-ds --timeout=120s
kubectl --context kind-eg2 -n kube-system wait deploy/kube-vip-cloud-provider --for=condition=Available --timeout=120s
```

Recorded (last apply):

```text
daemon set "kube-vip-ds" successfully rolled out
deployment.apps/kube-vip-cloud-provider condition met
```

### 3. Issue the certificates

```bash
kubectl --context kind-eg1 -n shop wait certificate/eg-tls --for=condition=Ready --timeout=90s
kubectl --context kind-eg2 -n shop wait certificate/eg-tls --for=condition=Ready --timeout=90s
```

Recorded (last apply):

```text
certificate.cert-manager.io/eg-tls condition met
```

### 4. Create the doors

EnvoyProxy is applied before the Gateway. The VIP door is created in
`VIP_HOME` only.

```bash
kubectl --context kind-eg1 -n shop wait --for=condition=Programmed gateway/eg1-gw --timeout=180s
kubectl --context kind-eg2 -n shop wait --for=condition=Programmed gateway/eg2-gw --timeout=180s
scripts/eg-vip-move.sh kube-vip eg1
```

Recorded (last apply):

```text
envoyproxy.gateway.envoyproxy.io/eg1-gw-proxy unchanged
gateway.gateway.networking.k8s.io/eg1-gw configured
gateway.gateway.networking.k8s.io/eg1-gw condition met
deployment.apps/envoy-shop-eg1-gw-33a1903b condition met
envoyproxy.gateway.envoyproxy.io/eg2-gw-proxy unchanged
gateway.gateway.networking.k8s.io/eg2-gw configured
gateway.gateway.networking.k8s.io/eg2-gw condition met
deployment.apps/envoy-shop-eg2-gw-8f1cc50b condition met
== takeover: eg1 will announce 172.19.255.16 (delete eg2 first)
== VIP 172.19.255.16 present in: eg1
  eg-vip-gw: present address=172.19.255.16 Programmed=True
  eg-vip-gw: absent
== responder MAC 6e:8c:28:fa:31:1f → eg1-worker 172.19.0.3/16
```

### 5. Deploy the app and routes

```bash
kubectl --context kind-eg1 apply -f demos/51-eg-kube-vip/40-app.yaml
kubectl --context kind-eg2 apply -f demos/51-eg-kube-vip/40-app.yaml
```

Recorded (last apply):

```text
deployment.apps/shopapi unchanged
service/shopapi unchanged
deployment.apps/grpc unchanged
service/grpc unchanged
deployment.apps/shopapi condition met
deployment.apps/grpc condition met
kind-eg1 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg1 httproute/shop-redirect: all parents Accepted+ResolvedRefs
kind-eg1 grpcroute/grpc: all parents Accepted+ResolvedRefs
kind-eg2 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg2 httproute/shop-redirect: all parents Accepted+ResolvedRefs
kind-eg2 grpcroute/grpc: all parents Accepted+ResolvedRefs
kind-eg1 httproute/shop-api-vip: all parents Accepted+ResolvedRefs
kind-eg1 httproute/shop-redirect-vip: all parents Accepted+ResolvedRefs
kind-eg1 grpcroute/grpc-vip: all parents Accepted+ResolvedRefs
```

### 6. Record the R7 experiment

```bash
demos/51-eg-kube-vip/apply.sh
```

Recorded (last apply):

```text
---- R7 eg1 probe-noproxy addresses=172.19.255.245 (no EnvoyProxy) ----
R7 eg1 Service externalIPs=['172.19.255.245'] status.loadBalancer={}
R7 eg1 arping 172.19.255.245 (expect 0 replies)
Received 0 response(s) (0 request(s), 0 broadcast(s))
R7 eg1 post-delete gateway/probe-noproxy: NotFound
---- R7 eg2 probe-noproxy addresses=172.19.255.181 (no EnvoyProxy) ----
R7 eg2 Service externalIPs=['172.19.255.181'] status.loadBalancer={}
R7 eg2 arping 172.19.255.181 (expect 0 replies)
Received 0 response(s) (0 request(s), 0 broadcast(s))
R7 eg2 post-delete gateway/probe-noproxy: NotFound
```

### 7. Move the VIP and measure

```bash
scripts/eg-vip-move.sh kube-vip eg2
scripts/eg-vip-move.sh kube-vip eg1
```

kube-vip elects among ready LOCAL endpoints (`externalTrafficPolicy:
Local`; kube-vip v1.2.4 `pkg/services/leader.go:102`). The probe gap is
wall-clock between the first and last failed start. kube-vip's own logs
bound the no-announcer window: source `[VIP] Deleting VIP` to target
`successful add IP` is 10.837 s / 10.909 s — the new Envoy pod turning
Ready ([docs/REVIEW_DEMO51.md](../../docs/REVIEW_DEMO51.md)).

Recorded (last apply):

```text
VIP move eg2: samples=33 ok=24 fail=9
VIP move eg2: first_fail=1789778455.797 last_fail=1789778465.165 gap_s=9.368
VIP move eg2: fail_kinds=000/curl28x6 000/curl7x2 404/curl0x1  (http_code/curl-exit: 28=timeout no responder, 7=refused, 0=answered non-200)
== responder MAC 1e:c6:bf:d8:18:97 → eg2-control-plane 172.19.0.4/16
VIP move eg1: samples=33 ok=24 fail=9
VIP move eg1: first_fail=1789778480.456 last_fail=1789778489.833 gap_s=9.377
VIP move eg1: fail_kinds=000/curl28x6 000/curl7x3  (http_code/curl-exit: 28=timeout no responder, 7=refused, 0=answered non-200)
== responder MAC 6e:8c:28:fa:31:1f → eg1-worker 172.19.0.3/16
```

### 8. Probe every door from the Mac

```bash
curl -s --resolve api.eg1.poc.local:443:172.19.255.240 \
  --cacert .tmp/eg-root-ca.crt https://api.eg1.poc.local/healthz
```

Recorded (last apply):

```text
https://api.eg1.poc.local @ 172.19.255.240 → 200 X-Served-By=eg1
http://api.eg1.poc.local @ 172.19.255.240 → 301 Location=https://api.eg1.poc.local/healthz
{
  "status": "SERVING"
}
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
grpc.reflection.v1alpha.ServerReflection
https://api.eg2.poc.local @ 172.19.255.176 → 200 X-Served-By=eg2
http://api.eg2.poc.local @ 172.19.255.176 → 301 Location=https://api.eg2.poc.local/healthz
https://api.eg.poc.local @ 172.19.255.16 → 200 X-Served-By=eg1
http://api.eg.poc.local @ 172.19.255.16 → 301 Location=https://api.eg.poc.local/healthz
TLS leaf api.eg1.poc.local @ 172.19.255.240: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=api.eg1.poc.local
TLS leaf grpc.eg1.poc.local @ 172.19.255.240: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=grpc.eg1.poc.local
TLS leaf api.eg2.poc.local @ 172.19.255.176: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=api.eg2.poc.local
TLS leaf grpc.eg2.poc.local @ 172.19.255.176: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=grpc.eg2.poc.local
TLS leaf api.eg.poc.local @ 172.19.255.16: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=api.eg.poc.local
TLS leaf grpc.eg.poc.local @ 172.19.255.16: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=grpc.eg.poc.local
CLUSTER  DOOR       ADDRESS          PROG   LB_CLASS                     ANNOUNCED_BY           HTTP         GRPC_H2C   GRPC_TLS
eg1      eg1-gw     172.19.255.240   True   kube-vip.io/kube-vip-class   eg1-worker             200/eg1      SERVING    SERVING
eg1      eg-vip-gw  172.19.255.16    True   kube-vip.io/kube-vip-class   eg1-worker             200/eg1      SERVING    SERVING
eg2      eg2-gw     172.19.255.176   True   kube-vip.io/kube-vip-class   eg2-worker             200/eg2      SERVING    SERVING
```

## Checks

The last `check.sh` (`2026-09-19T00:42:08Z`): 39 PASS, 0 FAIL. Recorded:

```text
== demo 51 — Envoy Gateway with kube-vip — alone (enhancement 007 phase 2)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   eg1 kube-vip DS ready                                                  ready=2/2                                            R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)
  PASS   eg1 kube-vip-cloud-provider Available                                  Available=True                                       R4 — cloud-provider v0.0.12 Available (KUBEVIP_ENABLE_LOADBALANCERCLASS=true)
  PASS   eg1 no metallb-system namespace                                        NotFound                                             R4 — MetalLB is demo 52; kubectl get ns metallb-system must not exist
  PASS   eg2 kube-vip DS ready                                                  ready=2/2                                            R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)
  PASS   eg2 kube-vip-cloud-provider Available                                  Available=True                                       R4 — cloud-provider v0.0.12 Available (KUBEVIP_ENABLE_LOADBALANCERCLASS=true)
  PASS   eg2 no metallb-system namespace                                        NotFound                                             R4 — MetalLB is demo 52; kubectl get ns metallb-system must not exist
  PASS   eg1 kubevip range-envoy-gateway-system                                 172.19.255.240-172.19.255.245                        R4 / §3.1 — range-envoy-gateway-system=172.19.255.240-172.19.255.245
  PASS   eg1 kubevip range-default                                              172.19.255.200-172.19.255.205                        R4 / §3.1 — range-default=172.19.255.200-172.19.255.205
  PASS   eg2 kubevip range-envoy-gateway-system                                 172.19.255.176-172.19.255.181                        R4 / §3.1 — range-envoy-gateway-system=172.19.255.176-172.19.255.181
  PASS   eg2 kubevip range-default                                              172.19.255.136-172.19.255.141                        R4 / §3.1 — range-default=172.19.255.136-172.19.255.141
  PASS   eg1/eg1-gw Programmed at 172.19.255.240                                addr=172.19.255.240 svcIngress=172.19.255.240 Programmed=True R4 / R8 — Gateway address and Service ingress both equal 172.19.255.240
  PASS   eg1/eg-vip-gw Programmed at 172.19.255.16                              addr=172.19.255.16 svcIngress=172.19.255.16 Programmed=True R4 / R8 — Gateway address and Service ingress both equal 172.19.255.16
  PASS   eg2/eg2-gw Programmed at 172.19.255.176                                addr=172.19.255.176 svcIngress=172.19.255.176 Programmed=True R4 / R8 — Gateway address and Service ingress both equal 172.19.255.176
  PASS   eg1/eg1-gw Service loadBalancerClass                                   kube-vip.io/kube-vip-class                           D11 — EnvoyProxy names kube-vip.io/kube-vip-class
  PASS   eg1/eg-vip-gw Service loadBalancerClass                                kube-vip.io/kube-vip-class                           D11 — EnvoyProxy names kube-vip.io/kube-vip-class
  PASS   eg2/eg2-gw Service loadBalancerClass                                   kube-vip.io/kube-vip-class                           D11 — EnvoyProxy names kube-vip.io/kube-vip-class
  PASS   eg1 probe-noclass stays pending                                        type=LoadBalancer class=(none) ingress=(none) impl=(none) ann=(none) age=2884s D11 — class-less LoadBalancer Service stays <pending> and unclaimed for ≥ 30s
  PASS   eg2 probe-noclass stays pending                                        type=LoadBalancer class=(none) ingress=(none) impl=(none) ann=(none) age=2882s D11 — class-less LoadBalancer Service stays <pending> and unclaimed for ≥ 30s
  PASS   ARP eg1-gw 172.19.255.240 one responder 3/3                            replies=3 unique_mac=1                               R4 / R8 — arping 3 of 3 from ONE MAC
  PASS   ARP eg2-gw 172.19.255.176 one responder 3/3                            replies=3 unique_mac=1                               R4 / R8 — arping 3 of 3 from ONE MAC
  PASS   ARP eg-vip-gw 172.19.255.16 one responder 3/3                          replies=3 unique_mac=1                               R4 / R8 — arping 3 of 3 from ONE MAC
  PASS   VIP Gateway in exactly one cluster                                     eg1                                                  R4 / §3.4 — shared address lives where it is announced
  PASS   https://api.eg1.poc.local @ 172.19.255.240 200 + X-Served-By           http_code=200 X-Served-By=eg1                        R8 — 200 and X-Served-By present
  PASS   X-Served-By never absent on api.eg1.poc.local                          X-Served-By=eg1                                      R8 — the Gateway filter SET the header
  PASS   https://api.eg2.poc.local @ 172.19.255.176 200 + X-Served-By           http_code=200 X-Served-By=eg2                        R8 — 200 and X-Served-By present
  PASS   X-Served-By never absent on api.eg2.poc.local                          X-Served-By=eg2                                      R8 — the Gateway filter SET the header
  PASS   https://api.eg.poc.local @ 172.19.255.16 200 + X-Served-By             http_code=200 X-Served-By=eg1                        R8 — 200 and X-Served-By present
  PASS   X-Served-By never absent on api.eg.poc.local                           X-Served-By=eg1                                      R8 — the Gateway filter SET the header
  PASS   http://api.eg1.poc.local @ 172.19.255.240 → 301                      http_code=301                                        R8 — shop-redirect on the :80 listener
  PASS   http://api.eg2.poc.local @ 172.19.255.176 → 301                      http_code=301                                        R8 — shop-redirect on the :80 listener
  PASS   http://api.eg.poc.local @ 172.19.255.16 → 301                        http_code=301                                        R8 — shop-redirect on the :80 listener
  PASS   gRPC h2c eg1-gw grpc.eg1.poc.local @ 172.19.255.240:80                 SERVING                                              R10 — grpcurl -plaintext Health/Check → SERVING
  PASS   gRPC TLS eg1-gw grpc.eg1.poc.local @ 172.19.255.240:443                SERVING                                              R10 — grpcurl -cacert .tmp/eg-root-ca.crt Health/Check → SERVING
  PASS   gRPC h2c eg2-gw grpc.eg2.poc.local @ 172.19.255.176:80                 SERVING                                              R10 — grpcurl -plaintext Health/Check → SERVING
  PASS   gRPC TLS eg2-gw grpc.eg2.poc.local @ 172.19.255.176:443                SERVING                                              R10 — grpcurl -cacert .tmp/eg-root-ca.crt Health/Check → SERVING
  PASS   gRPC h2c eg-vip-gw grpc.eg.poc.local @ 172.19.255.16:80                SERVING                                              R10 — grpcurl -plaintext Health/Check → SERVING
  PASS   gRPC TLS eg-vip-gw grpc.eg.poc.local @ 172.19.255.16:443               SERVING                                              R10 — grpcurl -cacert .tmp/eg-root-ca.crt Health/Check → SERVING
  PASS   eg1 certificate eg-tls Ready with six SANs                             Ready=True                                           D8 / R8 — CN api.eg.poc.local, six dnsNames, issuer eg-ca-issuer
  PASS   eg2 certificate eg-tls Ready with six SANs                             Ready=True                                           D8 / R8 — CN api.eg.poc.local, six dnsNames, issuer eg-ca-issuer
demo 51 check: 0 FAIL
```

## What is deliberately not here

- MetalLB — demo 52. `metallb-system` is `NotFound` on both clusters.
- Cilium policy — this lab is stock networking (kindnet + kube-proxy
  iptables).
- A write to `/etc/hosts` — `hosts-entries.sh` prints the block; checks
  use `--resolve` and `-authority`.
- A docker build — gotcha #118.

## Runs that did not go to plan

The apply at `2026-09-18T23:53:53Z` stopped at VIP routes:
`yaml_select` looked for a block-style `name:` and the route files use
compact `metadata: {name: …}`. Recorded:

```text
error: no objects passed to apply
```

The selector now also matches the compact form. The apply at
`2026-09-18T23:54:49Z` completed; the last apply
(`2026-09-19T00:40:23Z`) is the record above.

## Clean up

```bash
demos/51-eg-kube-vip/cleanup.sh
```

Removes the routes, app, Gateways + EnvoyProxies, certificate + secret,
kube-vip, the ConfigMaps, and namespace `shop`. Leaves demo 50's
clusters, Envoy Gateway, `GatewayClass eg`, cert-manager, and
`.tmp/eg-root-ca.crt`. Does not touch poc1, poc2, CRC, or the `kind`
network.
