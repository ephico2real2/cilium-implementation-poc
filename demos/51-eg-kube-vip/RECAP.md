# Demo 51 — two clusters, three kube-vip doors, and a VIP that moves

This page hangs kube-vip (a DaemonSet that answers ARP for a Service
address) on demo 50's two clusters and opens three Envoy Gateway doors.
Each door's `EnvoyProxy` names `kube-vip.io/kube-vip-class` and pins the
IP. A class-less Service stays `<pending>`. The product VIP lives in one
cluster at a time. MetalLB is not installed.

## What you get

- `loadBalancerClass` is mandatory (D11): `probe-noclass` stays
  `<pending>` on both clusters (`class=(none) ingress=(none)
  impl=(none) ann=(none)`, age 2884 s / 2882 s).
- Two clusters, three doors: `eg1-gw` at `172.19.255.240`, `eg2-gw` at
  `172.19.255.176`, product VIP `eg-vip-gw` at `172.19.255.16` in one
  cluster at a time.
- One `Certificate` `eg-tls` per cluster, CN `api.eg.poc.local`, six
  SANs; both Ready.
- gRPC `SERVING` on h2c `:80` and TLS `:443` behind every door; no
  `BackendTrafficPolicy`.
- R7: `spec.addresses` alone writes `externalIPs` (`.245` / `.181`) and
  `Received 0 response(s)`.
- VIP move: probes `samples=33 ok=24 fail=9`, gap `9.368 s` / `9.377 s`;
  kube-vip's window `10.837 s` / `10.909 s`.
- `check.sh` at `2026-09-19T00:42:08Z`: 39 PASS, 0 FAIL. No MetalLB
  (`metallb-system` `NotFound` on both).

## Architecture

The path a request takes:

```text
                         Mac
                         route 172.19/16 → 192.168.64.2
                              │
                         kind-eg  172.19.0.0/16
              ┌───────────────┴───────────────┐
              │                               │
             eg1                             eg2
         eg-vip-gw  172.19.255.16        (eg-vip-gw absent)
         announced by eg1-worker
         eg1-gw     172.19.255.240       eg2-gw  172.19.255.176
         announced by eg1-worker         announced by eg2-worker
              │                               │
              ▼                               ▼
         shopapi + grpc                  shopapi + grpc
         X-Served-By: eg1                X-Served-By: eg2
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.eg.poc.local` / `eg-vip-gw` | `172.19.255.16` | product door — HTTP `200/eg1`, gRPC `SERVING` | `eg1-worker` |
| `api.eg1.poc.local` / `eg1-gw` | `172.19.255.240` | eg1's own door — HTTP `200/eg1`, gRPC `SERVING` | `eg1-worker` |
| `api.eg2.poc.local` / `eg2-gw` | `172.19.255.176` | eg2's own door — HTTP `200/eg2`, gRPC `SERVING` | `eg2-worker` |
| `grpc.eg.poc.local` | `172.19.255.16` | gRPC on the product door | `eg1-worker` |
| `grpc.eg1.poc.local` | `172.19.255.240` | gRPC on eg1 | `eg1-worker` |
| `grpc.eg2.poc.local` | `172.19.255.176` | gRPC on eg2 | `eg2-worker` |

Recorded final table (`2026-09-19T00:40:23Z`):

```text
CLUSTER  DOOR       ADDRESS          PROG   LB_CLASS                     ANNOUNCED_BY           HTTP         GRPC_H2C   GRPC_TLS
eg1      eg1-gw     172.19.255.240   True   kube-vip.io/kube-vip-class   eg1-worker             200/eg1      SERVING    SERVING
eg1      eg-vip-gw  172.19.255.16    True   kube-vip.io/kube-vip-class   eg1-worker             200/eg1      SERVING    SERVING
eg2      eg2-gw     172.19.255.176   True   kube-vip.io/kube-vip-class   eg2-worker             200/eg2      SERVING    SERVING
```

## Prerequisites

- Demo 50's lab: clusters eg1 and eg2, Envoy Gateway, `GatewayClass eg`,
  cert-manager, lab root `.tmp/eg-root-ca.crt`.

```bash
scripts/eg-up.sh eg1 eg2
```

- A route on the Mac to the lab bridge
  ([gotcha #120](../../docs/GOTCHAS.md#120)):

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

- Images `shopapi:local` and `routedemo:local` already on the machine
  (gotcha #118 — this is not a docker build).
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  Gateway API `v1.6.2`, Envoy Gateway `v1.9.1`, cert-manager `v1.21.1`,
  kube-vip `v1.2.4`, kube-vip cloud-provider `v0.0.12`.

## Steps

Do these in order from the repo root:

### 1. Bring up the two-cluster lab

Confirm both APIs are Ready.

```bash
kubectl --context kind-eg1 get --raw /readyz
kubectl --context kind-eg2 get --raw /readyz
```

Result: `ok` on both (`2026-09-19T00:40:23Z`).

```text
ok
```

### 2. Install kube-vip in both clusters

RBAC, DaemonSet and cloud-provider live under `clusters/eg/` (one source
of truth). Each cluster gets its own `kubevip` ConfigMap. kube-vip runs
class-only (`lb_class_only=true`, `KUBEVIP_ENABLE_LOADBALANCERCLASS=true`).

```bash
kubectl --context kind-eg1 apply -f clusters/eg/kube-vip-rbac.yaml
kubectl --context kind-eg1 apply -f demos/51-eg-kube-vip/10-kubevip-cm-eg1.yaml
kubectl --context kind-eg1 apply -f clusters/eg/kube-vip-ds.yaml
kubectl --context kind-eg1 apply -f clusters/eg/kube-vip-cloud-provider.yaml
kubectl --context kind-eg1 -n kube-system rollout status ds/kube-vip-ds --timeout=120s
kubectl --context kind-eg1 -n kube-system wait deploy/kube-vip-cloud-provider \
  --for=condition=Available --timeout=120s
kubectl --context kind-eg2 apply -f clusters/eg/kube-vip-rbac.yaml
kubectl --context kind-eg2 apply -f demos/51-eg-kube-vip/10-kubevip-cm-eg2.yaml
kubectl --context kind-eg2 apply -f clusters/eg/kube-vip-ds.yaml
kubectl --context kind-eg2 apply -f clusters/eg/kube-vip-cloud-provider.yaml
kubectl --context kind-eg2 -n kube-system rollout status ds/kube-vip-ds --timeout=120s
kubectl --context kind-eg2 -n kube-system wait deploy/kube-vip-cloud-provider \
  --for=condition=Available --timeout=120s
```

Result: DS rolled out on both; cloud-provider `condition met` on both.

```text
daemon set "kube-vip-ds" successfully rolled out
deployment.apps/kube-vip-cloud-provider condition met
```

### 3. Issue the certificates

One `Certificate` `eg-tls` per cluster, the same spec in both. Gateways
live in `shop` with the Secret, so no ReferenceGrant.

```bash
kubectl --context kind-eg1 apply -f demos/51-eg-kube-vip/20-certificates.yaml
kubectl --context kind-eg1 -n shop wait certificate/eg-tls \
  --for=condition=Ready --timeout=90s
kubectl --context kind-eg2 apply -f demos/51-eg-kube-vip/20-certificates.yaml
kubectl --context kind-eg2 -n shop wait certificate/eg-tls \
  --for=condition=Ready --timeout=90s
```

Result: Ready on both.

```text
certificate.cert-manager.io/eg-tls condition met
```

### 4. Create the doors

Each `EnvoyProxy` sits in the same file, before its Gateway, because the
class is immutable. The VIP door is created in `VIP_HOME` only (default
eg1).

```bash
kubectl --context kind-eg1 -n shop wait --for=condition=Programmed \
  gateway/eg1-gw --timeout=180s
kubectl --context kind-eg2 -n shop wait --for=condition=Programmed \
  gateway/eg2-gw --timeout=180s
scripts/eg-vip-move.sh kube-vip eg1
```

Result: per-cluster doors Programmed; VIP present in eg1 only;
responder `eg1-worker` (`6e:8c:28:fa:31:1f`).

```text
envoyproxy.gateway.envoyproxy.io/eg1-gw-proxy unchanged
gateway.gateway.networking.k8s.io/eg1-gw configured
gateway.gateway.networking.k8s.io/eg1-gw condition met
envoyproxy.gateway.envoyproxy.io/eg2-gw-proxy unchanged
gateway.gateway.networking.k8s.io/eg2-gw configured
== VIP 172.19.255.16 present in: eg1
  eg-vip-gw: present address=172.19.255.16 Programmed=True
  eg-vip-gw: absent
== responder MAC 6e:8c:28:fa:31:1f → eg1-worker 172.19.0.3/16
```

### 5. Deploy the app and routes

`shopapi:local` and `routedemo:local -mode grpc` sit behind the doors.
Per-cluster routes always; VIP routes only where `eg-vip-gw` is.

```bash
kubectl --context kind-eg1 apply -f demos/51-eg-kube-vip/40-app.yaml
kubectl --context kind-eg1 -n shop wait deploy/shopapi --for=condition=Available --timeout=120s
kubectl --context kind-eg1 -n shop wait deploy/grpc --for=condition=Available --timeout=120s
kubectl --context kind-eg2 apply -f demos/51-eg-kube-vip/40-app.yaml
kubectl --context kind-eg2 -n shop wait deploy/shopapi --for=condition=Available --timeout=120s
kubectl --context kind-eg2 -n shop wait deploy/grpc --for=condition=Available --timeout=120s
```

Result: both Deployments Available; every route
`Accepted+ResolvedRefs`.

```text
deployment.apps/shopapi condition met
deployment.apps/grpc condition met
kind-eg1 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg1 httproute/shop-redirect: all parents Accepted+ResolvedRefs
kind-eg1 grpcroute/grpc: all parents Accepted+ResolvedRefs
kind-eg2 httproute/shop-api: all parents Accepted+ResolvedRefs
kind-eg1 httproute/shop-api-vip: all parents Accepted+ResolvedRefs
```

### 6. Record the R7 experiment

A throwaway Gateway `probe-noproxy` with `spec.addresses` and no
`EnvoyProxy` writes `externalIPs` and nobody answers ARP
([enhancement 007 §3.3](../../enhancements/007-envoy-gateway-lab.md)).

```bash
demos/51-eg-kube-vip/apply.sh
```

Result: `externalIPs` set, `status.loadBalancer={}`,
`Received 0 response(s)`, then `NotFound` on both.

```text
R7 eg1 Service externalIPs=['172.19.255.245'] status.loadBalancer={}
Received 0 response(s) (0 request(s), 0 broadcast(s))
R7 eg1 post-delete gateway/probe-noproxy: NotFound
R7 eg2 Service externalIPs=['172.19.255.181'] status.loadBalancer={}
Received 0 response(s) (0 request(s), 0 broadcast(s))
R7 eg2 post-delete gateway/probe-noproxy: NotFound
```

### 7. Move the VIP and measure

The script deletes the other cluster first, waits for that Envoy Service
to be gone, then creates the VIP door on the target.

```bash
scripts/eg-vip-move.sh kube-vip eg2
scripts/eg-vip-move.sh kube-vip eg1
```

Result:

```text
VIP move eg2: samples=33 ok=24 fail=9
VIP move eg2: first_fail=1789778455.797 last_fail=1789778465.165 gap_s=9.368
VIP move eg2: fail_kinds=000/curl28x6 000/curl7x2 404/curl0x1  (http_code/curl-exit: 28=timeout no responder, 7=refused, 0=answered non-200)
VIP move eg1: samples=33 ok=24 fail=9
VIP move eg1: first_fail=1789778480.456 last_fail=1789778489.833 gap_s=9.377
VIP move eg1: fail_kinds=000/curl28x6 000/curl7x3  (http_code/curl-exit: 28=timeout no responder, 7=refused, 0=answered non-200)
```

The probe gap is the new Envoy pod turning Ready: kube-vip elects among
ready LOCAL endpoints (`externalTrafficPolicy: Local`) and the log
window is 10.837 s / 10.909 s
([docs/REVIEW_DEMO51.md](../../docs/REVIEW_DEMO51.md)).

### 8. Probe every door from the Mac

HTTPS verifies the leaf against `.tmp/eg-root-ca.crt`. gRPC is probed
on h2c and TLS. Each SAN name is checked as a TLS leaf.

```bash
curl -s --resolve api.eg1.poc.local:443:172.19.255.240 \
  --cacert .tmp/eg-root-ca.crt https://api.eg1.poc.local/healthz
curl -s --resolve api.eg2.poc.local:443:172.19.255.176 \
  --cacert .tmp/eg-root-ca.crt https://api.eg2.poc.local/healthz
curl -s --resolve api.eg.poc.local:443:172.19.255.16 \
  --cacert .tmp/eg-root-ca.crt https://api.eg.poc.local/healthz
docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.eg1.poc.local \
  172.19.255.240:80 grpc.health.v1.Health/Check
openssl s_client -connect 172.19.255.240:443 \
  -servername api.eg1.poc.local -verify_hostname api.eg1.poc.local \
  -CAfile .tmp/eg-root-ca.crt -verify_return_error
```

Result: `200` and `X-Served-By` per door; `301` on `:80` for the API
names; gRPC `SERVING`; six TLS leaves `verify=ok`.

```text
https://api.eg1.poc.local @ 172.19.255.240 → 200 X-Served-By=eg1
http://api.eg1.poc.local @ 172.19.255.240 → 301 Location=https://api.eg1.poc.local/healthz
https://api.eg2.poc.local @ 172.19.255.176 → 200 X-Served-By=eg2
https://api.eg.poc.local @ 172.19.255.16 → 200 X-Served-By=eg1
{
  "status": "SERVING"
}
TLS leaf api.eg1.poc.local @ 172.19.255.240: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=api.eg1.poc.local
TLS leaf grpc.eg1.poc.local @ 172.19.255.240: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=grpc.eg1.poc.local
TLS leaf api.eg2.poc.local @ 172.19.255.176: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=api.eg2.poc.local
TLS leaf grpc.eg2.poc.local @ 172.19.255.176: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=grpc.eg2.poc.local
TLS leaf api.eg.poc.local @ 172.19.255.16: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=api.eg.poc.local
TLS leaf grpc.eg.poc.local @ 172.19.255.16: verify=ok subject=api.eg.poc.local issuer=eg-root-ca san=grpc.eg.poc.local
```

## Verify

From the Mac:

```bash
curl -s --resolve api.eg1.poc.local:443:172.19.255.240 \
  --cacert .tmp/eg-root-ca.crt https://api.eg1.poc.local/healthz
```

Expect `200` and `X-Served-By: eg1`.

```bash
docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.eg1.poc.local \
  172.19.255.240:80 grpc.health.v1.Health/Check
```

Expect `{"status": "SERVING"}`.

```bash
scripts/eg-vip-move.sh --status
```

Expect the VIP in eg1, responder `eg1-worker`.

```bash
demos/51-eg-kube-vip/check.sh
```

Recorded `2026-09-19T00:42:08Z`: 39 PASS, 0 FAIL.

```text
demo 51 check: 0 FAIL
```

## Reference

Certificate spec (`20-certificates.yaml`), one per cluster:

```yaml
kind: Certificate
spec:
  secretName: eg-tls
  commonName: api.eg.poc.local
  dnsNames:
    - api.eg.poc.local
    - api.eg1.poc.local
    - api.eg2.poc.local
    - grpc.eg1.poc.local
    - grpc.eg2.poc.local
    - grpc.eg.poc.local
  issuerRef: {kind: ClusterIssuer, name: eg-ca-issuer}
```

Issued leaves: both `subject=CN=api.eg.poc.local`, `issuer=CN=eg-root-ca`,
the six SANs, valid 2026-09-18 23:54:09Z → 2026-12-17 23:54:09Z.

```text
eg1 09:91:08:A6:4C:1B:51:F2:97:16:2E:FF:B9:FA:65:1D:AD:C1:B5:79:DD:F6:18:5C:14:6D:3C:96:4F:30:A2:43
eg2 2C:20:A5:38:46:18:D5:63:3E:44:4B:A2:83:27:60:91:61:05:C6:06:E1:F1:79:F4:12:EA:68:32:05:6D:69:AE
```

| File | What |
|---|---|
| [`clusters/eg/kube-vip-*.yaml`](../../clusters/eg/kube-vip-ds.yaml) | RBAC, DaemonSet, cloud-provider — one source of truth |
| [`10-kubevip-cm-eg1.yaml`](10-kubevip-cm-eg1.yaml) / [`10-kubevip-cm-eg2.yaml`](10-kubevip-cm-eg2.yaml) | `kubevip` ConfigMap per cluster |
| [`15-probe-noclass.yaml`](15-probe-noclass.yaml) | D11 exhibit — class-less LoadBalancer, stays `<pending>` |
| [`20-certificates.yaml`](20-certificates.yaml) | `Certificate` `eg-tls`, six dnsNames |
| [`30-gateways-eg1.yaml`](30-gateways-eg1.yaml) / [`30-gateways-eg2.yaml`](30-gateways-eg2.yaml) | EnvoyProxy then Gateway; VIP pair applied to one cluster |
| [`40-app.yaml`](40-app.yaml) | `shopapi` + `grpc` |
| [`50-routes-eg1.yaml`](50-routes-eg1.yaml) / [`50-routes-eg2.yaml`](50-routes-eg2.yaml) | per-cluster routes; VIP routes only with `eg-vip-gw` |
| [`apply.sh`](apply.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, prove, remove |
| [`scripts/eg-vip-move.sh`](../../scripts/eg-vip-move.sh) | delete-other-first; `--status` prints who has `.16` |

Address blocks ([enhancement 007 §3.1](../../enhancements/007-envoy-gateway-lab.md)):
`172.19.255.192/26` (eg1 — kube-vip doors `.240–.245`),
`172.19.255.128/26` (eg2 — `.176–.181`),
`172.19.255.0/26` (shared — product VIP `.16`).

```bash
scripts/eg-vip-move.sh kube-vip eg1
scripts/eg-vip-move.sh kube-vip eg2
scripts/eg-vip-move.sh --status
```

## Troubleshooting

- Mac clients time out while the cluster is healthy: the `172.19` route
  is missing ([gotcha #120](../../docs/GOTCHAS.md#120)); add it under
  *Prerequisites*.
- Two ARP responders for `.16`: the move script deletes the other
  cluster first.
- A class-less Service stays `<pending>` (D11): kube-vip runs class-only;
  `probe-noclass` is the exhibit.

## Clean up

```bash
demos/51-eg-kube-vip/cleanup.sh
```

Removes the doors, app, kube-vip and `shop`. Demo 50's clusters stay.

## What's next

- Demo 52 installs MetalLB
  ([enhancement 007 §4](../../enhancements/007-envoy-gateway-lab.md)).
- [Demo 54](../54-eg-poc1-kube-vip/RECAP.md) is the one-cluster picture.
- Phase 4 of [enhancement 007](../../enhancements/007-envoy-gateway-lab.md)
  is `docs/EG-VS-CILIUM.md`.
