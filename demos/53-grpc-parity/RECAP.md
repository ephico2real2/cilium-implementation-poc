# Demo 53 — gRPC SERVING on both Cilium doors

This page re-runs demo 09's gRPC test on poc1 and lands poc2's first
GRPCRoute on `shop-gw` (Cilium's front-door object, listeners in the
node's shared Envoy). HTTP already occupies `api.poc2.shop.poc.local` on
`172.18.255.177`. gRPC gets its own name on that address —
`grpc.poc2.shop.poc.local` — a new `https-grpc` listener, plaintext
h2c (HTTP/2 cleartext) on `:80`, and TLS on `:443` through the lab root. Both clusters answer
`SERVING`.

## What you get

- poc1 `grpc.poc.local` at `172.18.255.240`: h2c `:80` and TLS `:443` →
  `{ "status": "SERVING" }`.
- poc2 `grpc.poc2.shop.poc.local` at `172.18.255.177`: the same two
  calls → `SERVING`.
- `shop-gw` has `3/3` listeners Programmed (`https`, `https-grpc`,
  `http`); GRPCRoute `grpc` is `accepted=2/2 resolved=2/2`.
- A CiliumNetworkPolicy (an allow that Cilium enforces at the pod)
  named `grpc` admits the Gateway (`fromEntities: ingress`) on TCP/9090.
  Without it Hubble records `Policy denied DROPPED` from identity 8.
- Leaf `grpc-tls`: CN and SAN `grpc.poc2.shop.poc.local`, issuer
  `CN=clustermesh-root-ca`; `.tmp/root-ca.crt` verifies; `docs/root-ca.crt`
  fails ([issue #60](https://github.com/ephico2real2/cilium-implementation-poc/issues/60)).
- `check.sh` at `2026-09-18T19:37:08Z`: 10 PASS, 0 FAIL, 1 WARN (11
  rows). The WARN is `command -v grpcurl: not found` on the Mac.

## Architecture

A request from a container on the `kind` bridge takes this path:

```text
        grpcurl -authority grpc.poc2.shop.poc.local
                         │
            ┌────────────┴────────────┐
            │ h2c :80                 │ TLS SNI :443
            ▼                         ▼
         shop-gw  172.18.255.177  (poc2)
         http:80   (no hostname)      https-grpc:443  grpc.poc2.shop.poc.local
                                      (grpc-tls)
            │                         │
            └────────────┬────────────┘
                         ▼
                   grpc :9090
                   routedemo -mode grpc
                   CNP grpc → reserved:ingress
```

`https` on the same address still serves `api.poc2.shop.poc.local`
(demo 41's HTTPRoute). A Gateway listener has one hostname, and a route
whose hostnames do not intersect it is not accepted there — Gateway API
v1.6.1, `GRPCRoute.spec.hostnames`: *"If both the Listener and GRPCRoute
have specified hostnames, and none match with the criteria above, then
the GRPCRoute MUST NOT be accepted by the implementation"* — so
`grpc.poc2.shop.poc.local` needs its own listener. Gateway API also
requires exactly one of an HTTPRoute and a GRPCRoute whose hostnames
overlap on one listener; Cilium 1.20.2 evaluates the kinds separately
(read from its code, not measured). This page uses a
distinct name and stays portable.

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `grpc.poc.local` | `172.18.255.240` | demo 09's gRPC name on `routes-gw` | poc1 |
| `grpc.poc2.shop.poc.local` | `172.18.255.177` | gRPC name on `shop-gw` | poc2 (`kind-l2-announce`) |
| `api.poc2.shop.poc.local` | `172.18.255.177` | shop HTTP name, same door, different listener | poc2 (`kind-l2-announce`) |

`.177` comes from poc2's gateway-pool (an LB IPAM pool). L2 announcement
means one node answers ARP for the address, a lease per Service.

The `:80` listener has no hostname and already serves any Host; the
GRPCRoute attaches there as h2c. `:authority` is the HTTP/2
pseudo-header the route's `hostnames` match on. grpcurl's `-authority`
flag sets it and is also the TLS server name — passing `-servername` as
well is an error.

## Prerequisites

- kind `v0.33.0`, kubectl `v1.36.4`, Cilium `1.20.2`, Hubble CLI
  `1.19.4` ([`scripts/bootstrap/versions.env`](../../scripts/bootstrap/versions.env)).
- poc1 and poc2 up; demos 40 and 41 applied; image `routedemo:local`
  already on the nodes (this is not a docker build).
- The live root, not `docs/root-ca.crt`:

```bash
scripts/lab-trust.sh export kind-poc2
```

- Demo 09's apps and routes on poc1 when `grpcroute/grpc` is absent
  (`lab-stack.sh` applies only `01-gateway.yaml`):

```bash
kubectl --context kind-poc1 apply -f demos/09-routes/02-apps.yaml
kubectl --context kind-poc1 apply -f demos/09-routes/03-routes.yaml
```

`apply.sh` does both of those before the poc2 steps.

## Steps

Do these in order from the repo root, after the prerequisites
(`apply.sh` runs and records all five):

### 1. Add the listener and the leaf

`https` is already `api.poc2.shop.poc.local`. The Certificate and the
`https-grpc` listener live in demo 40 so that apply stays the source of
truth.

```bash
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/20-certificates.yaml
kubectl --context kind-poc2 -n shop-edge wait certificate/grpc-tls \
  --for=condition=Ready --timeout=90s
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/30-gateways-poc2.yaml
kubectl --context kind-poc2 -n shop-edge wait --for=condition=Programmed \
  gateway/shop-gw --timeout=120s
```

Result: `certificate.cert-manager.io/grpc-tls condition met`; shop-gw
`3/3` listeners Programmed.

```text
certificate.cert-manager.io/grpc-tls condition met
gateway.gateway.networking.k8s.io/shop-gw condition met
kind-poc2 gateway/shop-gw: 3/3 listeners Programmed
```

### 2. Deploy the app and the CiliumNetworkPolicy

`routedemo:local -mode grpc` in `shop-edge`, Service port 9090 with
`appProtocol: kubernetes.io/h2c` (without it Envoy speaks HTTP/1.1 to
the pod). Demo 41's `default-deny-ingress` selects `part-of: shop` and
`ingress: [{}]` is default-deny ([gotcha #80](../../docs/GOTCHAS.md#80));
the CNP is the explicit allow on TCP/9090. Probes are TCP: the process
speaks HTTP/2 on `:9090`.

```bash
kubectl --context kind-poc2 apply -f demos/53-grpc-parity/10-poc2-grpc-app.yaml
kubectl --context kind-poc2 -n shop-edge wait deploy/grpc \
  --for=condition=Available --timeout=120s
```

Result: `deployment.apps/grpc condition met`;
`ciliumnetworkpolicy.cilium.io/grpc unchanged`.

```text
deployment.apps/grpc unchanged
service/grpc unchanged
ciliumnetworkpolicy.cilium.io/grpc unchanged
deployment.apps/grpc condition met
```

### 3. Attach the GRPCRoute

The GRPCRoute parents `https-grpc` and `http`, hostname
`grpc.poc2.shop.poc.local`, three method matches from demo 09 (Health
and both reflection services).

```bash
kubectl --context kind-poc2 apply -f demos/53-grpc-parity/30-poc2-grpcroute.yaml
```

Result: grpcroute all parents Accepted+ResolvedRefs.

```text
grpcroute.gateway.networking.k8s.io/grpc configured
kind-poc2 grpcroute/grpc: all parents Accepted+ResolvedRefs
```

### 4. Prove the policy drop

Every apply re-proves that CNP `grpc` is what lets `reserved:ingress`
(identity 8) reach `:9090`: without it the endpoint's only realized
ingress allow is Cilium's localhost rule (`allow-localhost-ingress`),
so kubelet's TCP probes (`reserved:host`) pass while Envoy is dropped.

```bash
demos/53-grpc-parity/policy-proof.sh
```

Result: Health/Check hits `DeadlineExceeded`; Hubble
`Policy denied DROPPED` from `(ingress)` identity 8; re-apply restores
`{ "status": "SERVING" }`.

```text
Error invoking method "grpc.health.v1.Health/Check": rpc error: code = DeadlineExceeded desc = failed to query for service descriptor "grpc.health.v1.Health": context deadline exceeded
Sep 18 19:37:18.678: 10.20.0.33:53156 (ingress) <> shop-edge/grpc-c59b4f578-dqr55:9090 (ID:145376) Policy denied DROPPED (TCP Flags: SYN)
source identity 8 (reserved:ingress)
{
  "status": "SERVING"
}
policy-proof: CNP grpc required; Policy denied DROPPED from (ingress) identity 8; SERVING restored
```

### 5. Prove the leaf

`tls-proof.sh` prints the live leaf and which root verifies it.

```bash
demos/53-grpc-parity/tls-proof.sh
```

Result: `subject=CN=grpc.poc2.shop.poc.local`,
`issuer=CN=clustermesh-root-ca`, SAN `DNS:grpc.poc2.shop.poc.local`,
`sha256 Fingerprint=DD:A5:35:55:F6:93:90:9D:B4:BD:22:C1:E2:1D:94:36:E6:53:59:C1:65:AC:F6:86:3B:32:4C:FF:DB:0E:42:CF`,
`notBefore=Sep 18 19:02:42 2026 GMT`,
`notAfter=Dec 17 19:02:42 2026 GMT`; live root OK; docs root failed.

```text
.tmp/grpc-poc2.crt: OK
error 20 at 0 depth lookup: unable to get local issuer certificate
error .tmp/grpc-poc2.crt: verification failed
tls-proof: live root OK; docs/root-ca.crt failed (issue #60)
```

## Verify

From a container on the `kind` network (the Mac has no `grpcurl`):

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
  172.18.255.177:80 grpc.health.v1.Health/Check
```

Expect `{ "status": "SERVING" }`. The same call with
`-authority grpc.poc.local` at `172.18.255.240:80` is poc1. TLS mounts
`.tmp/root-ca.crt` and uses `:443`. A method the route does not match,
and a wrong `:authority`, are [GUIDE.md](GUIDE.md) exercises 1 and 2.

```bash
demos/53-grpc-parity/check.sh
```

Recorded `2026-09-18T19:37:08Z`:

```text
== demo 53 — gRPC parity on the Cilium clusters (poc1 re-run, poc2 first GRPCRoute)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   root CA for TLS rows                                                   .tmp/root-ca.crt (live)                              clustermesh-root-ca via scripts/lab-trust.sh export; docs/root-ca.crt only if fingerprints match
  PASS   poc1 h2c Health/Check @ 172.18.255.240:80                              { "status": "SERVING" }                              grpcurl -plaintext -authority grpc.poc.local 172.18.255.240:80 → {"status":"SERVING"}
  PASS   poc1 TLS Health/Check @ 172.18.255.240:443                             { "status": "SERVING" }                              grpcurl -cacert .tmp/root-ca.crt -authority grpc.poc.local 172.18.255.240:443 → {"status":"SERVING"}
  PASS   poc1 grpcurl list via reflection                                       grpc.health.v1.Health grpc.reflection.v1.ServerReflection grpc.reflection.v1alph list shows grpc.health.v1.Health and both ServerReflection services (demo 09)
  PASS   poc2 h2c Health/Check @ 172.18.255.177:80                              { "status": "SERVING" }                              grpcurl -plaintext -authority grpc.poc2.shop.poc.local 172.18.255.177:80 → {"status":"SERVING"}
  PASS   poc2 TLS Health/Check @ 172.18.255.177:443                             { "status": "SERVING" }                              grpcurl -cacert .tmp/root-ca.crt -authority grpc.poc2.shop.poc.local 172.18.255.177:443 → {"status":"SERVING"}
  PASS   poc2 grpcurl list via reflection                                       grpc.health.v1.Health grpc.reflection.v1.ServerReflection grpc.reflection.v1alph list shows grpc.health.v1.Health and both ServerReflection services (demo 09)
  PASS   poc2 grpcroute/grpc Accepted on both parents                           accepted=2/2 resolved=2/2                            every parent Accepted=True and ResolvedRefs=True (≥ 2 parents: https-grpc and http)
  PASS   poc2 shop-gw listener https-grpc Programmed                            Programmed=True                                      status.listeners[name=https-grpc] Programmed=True
  PASS   poc2 grpc-tls Ready                                                    Ready=True                                           Certificate grpc-tls Ready=True
  WARN   Mac grpcurl (not installed)                                            command -v grpcurl: not found                        skip: brew install grpcurl, then grpcurl -plaintext -authority grpc.poc2.shop.poc.local 172.18.255.177:80 grpc.health.v1.Health/Check
```

## Reference

Certificate spec (`20-certificates.yaml` in demo 40):

```yaml
kind: Certificate
metadata: {name: grpc-tls, namespace: shop-edge}
spec:
  secretName: grpc-tls
  commonName: grpc.poc2.shop.poc.local
  dnsNames:
    - grpc.poc2.shop.poc.local
  issuerRef: {kind: ClusterIssuer, name: ca-issuer}
```

Issued leaf: `subject=CN=grpc.poc2.shop.poc.local`,
`issuer=CN=clustermesh-root-ca`, SAN `DNS:grpc.poc2.shop.poc.local`,
`notBefore=Sep 18 19:02:42 2026 GMT`,
`notAfter=Dec 17 19:02:42 2026 GMT`,
fingerprint `DD:A5:35:55:F6:93:90:9D:B4:BD:22:C1:E2:1D:94:36:E6:53:59:C1:65:AC:F6:86:3B:32:4C:FF:DB:0E:42:CF`.
A client trusts `.tmp/root-ca.crt` (live root
`sha256 Fingerprint=F4:FD:F8:B7:78:D9:D3:9E:69:53:E1:CB:FB:26:CD:1A:9B:85:48:66:D4:48:8D:08:0F:E9:73:7E:8A:97:BF:27`).
`list` names Health and both reflection services; `routedemo.Echo` is a
health status name, not a reflected service.

| File | What |
|---|---|
| [`10-poc2-grpc-app.yaml`](10-poc2-grpc-app.yaml) | Deployment + Service + CNP `grpc` |
| [`../40-shop-mesh-phase0/20-certificates.yaml`](../40-shop-mesh-phase0/20-certificates.yaml) | `Certificate` `grpc-tls` |
| [`../40-shop-mesh-phase0/30-gateways-poc2.yaml`](../40-shop-mesh-phase0/30-gateways-poc2.yaml) | `shop-gw` listener `https-grpc` |
| [`30-poc2-grpcroute.yaml`](30-poc2-grpcroute.yaml) | GRPCRoute on `https-grpc` and `http` |
| [`apply.sh`](apply.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, prove, remove |
| [`policy-proof.sh`](policy-proof.sh) / [`tls-proof.sh`](tls-proof.sh) | the two proofs |

## Troubleshooting

- TLS verify fails with `unable to get local issuer certificate`:
  `docs/root-ca.crt` is a previous build
  ([issue #60](https://github.com/ephico2real2/cilium-implementation-poc/issues/60));
  use `.tmp/root-ca.crt` from the export under *Prerequisites*.
- Health/Check returns `DeadlineExceeded`: CNP `grpc` is missing and
  demo 41's default-deny drops `reserved:ingress`
  ([gotcha #80](../../docs/GOTCHAS.md#80)); re-apply
  [`10-poc2-grpc-app.yaml`](10-poc2-grpc-app.yaml).
- grpcurl errors when both `-authority` and `-servername` are set: pass
  `-authority` only.

## Clean up

```bash
demos/53-grpc-parity/cleanup.sh
```

Removes the route, the app, CNP `grpc`, and `grpc-tls` (Certificate +
Secret). The `https-grpc` listener stays — it is demo 40's door. Re-apply
`20-certificates.yaml` to restore the leaf.

## What's next

- [GUIDE.md](GUIDE.md) — unmatched method, wrong `:authority`, `list`.
- Demos 51 and 54 put this app and this route shape on Envoy Gateway.
- The Cilium column of `docs/EG-VS-CILIUM.md` is enhancement 007 phase 4
  ([enhancement 007](../../enhancements/007-envoy-gateway-lab.md) §4
  row 3b, issue
  [#58](https://github.com/ephico2real2/cilium-implementation-poc/issues/58)).
- The shop door and the HTTPRoute are
  [demo 40](../40-shop-mesh-phase0/README.md) and
  [demo 41](../41-shop-mesh-phase1/README.md)
  ([enhancement 002](../../enhancements/002-shop-platform-clustermesh.md)).
