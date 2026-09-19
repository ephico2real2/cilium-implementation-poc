# Demo 53 — gRPC parity on the Cilium clusters

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

This is the Cilium half of enhancement 007 R10: demo 09's gRPC test
re-run on poc1, and poc2's first GRPCRoute on `shop-gw`. HTTP and gRPC
share `172.18.255.177`; SNI and `:authority` pick the protocol. Tracking:
[enhancement 007](../../enhancements/007-envoy-gateway-lab.md) §1 R10,
§4 row 3b, §5 D9; issue
[#58](https://github.com/ephico2real2/cilium-implementation-poc/issues/58)
(parent [#53](https://github.com/ephico2real2/cilium-implementation-poc/issues/53)).
The shop door is
[enhancement 002](../../enhancements/002-shop-platform-clustermesh.md).
No docker build (gotcha #118). `routedemo:local` is already on the nodes.

## Summary context — the enterprise case

One load-balancer IP, two protocols. An operator who already has
`shop-gw` at `172.18.255.177` for `api.poc2.shop.poc.local` adds
`grpc.poc2.shop.poc.local` on that Gateway. A listener has one hostname;
demo 41's HTTPRoute occupies `https`. Gateway API requires `:authority`
to intersect the route's hostnames, and forbids an HTTPRoute and a
GRPCRoute sharing a hostname on one listener. Cilium 1.20.2 evaluates
the kinds separately ([read, not measured](../../docs/REVIEW_DEMO53.md)).
poc2 gets listener `https-grpc` on port 443, distinguished by SNI, and
Certificate `grpc-tls`. The `:80` listener has no hostname; the
GRPCRoute attaches there as h2c. The path a request takes is in the
[RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`10-poc2-grpc-app.yaml`](10-poc2-grpc-app.yaml) | `grpc` Deployment + Service in `shop-edge` (`appProtocol: kubernetes.io/h2c`, TCP probes) and CNP `grpc` (`fromEntities: ingress` on 9090) |
| [`20-poc2-grpc-listener.yaml`](20-poc2-grpc-listener.yaml) | **not applied** — pointer only. The listener and Certificate live in demo 40 |
| [`../40-shop-mesh-phase0/20-certificates.yaml`](../40-shop-mesh-phase0/20-certificates.yaml) | `Certificate/grpc-tls` |
| [`../40-shop-mesh-phase0/30-gateways-poc2.yaml`](../40-shop-mesh-phase0/30-gateways-poc2.yaml) | `shop-gw` listener `https-grpc` |
| [`30-poc2-grpcroute.yaml`](30-poc2-grpcroute.yaml) | GRPCRoute `grpc` on `https-grpc` and `http`, three method matches from demo 09 |
| [`apply.sh`](apply.sh) | restore poc1 if needed; poc2 door + app + route; records `check.sh`, then `policy-proof.sh` and `tls-proof.sh` |
| [`check.sh`](check.sh) | PASS/FAIL/WARN rows; exit = FAIL count |
| [`policy-proof.sh`](policy-proof.sh) | delete CNP → Health/Check fails → Hubble DROPPED from identity 8 → re-apply → SERVING |
| [`tls-proof.sh`](tls-proof.sh) | leaf SAN/issuer/fingerprint/dates; live root OK; `docs/root-ca.crt` failed (issue [#60](https://github.com/ephico2real2/cilium-implementation-poc/issues/60)) |
| [`cleanup.sh`](cleanup.sh) | route, app, CNP, `grpc-tls`; **the listener stays** |
| [`GUIDE.md`](GUIDE.md) | unmatched method, wrong `:authority`, `list`, the check |

The lab root PEM is **`.tmp/root-ca.crt`** (gitignored, issue #60).

## Run it

From the repo root. Both clusters up, demos 40 and 41 applied. Do not
rebuild `routedemo:local`.

```bash
demos/53-grpc-parity/apply.sh
demos/53-grpc-parity/check.sh
```

`apply.sh` exports the live root, restores demo 09 on poc1 if
`grpcroute/grpc` is absent, applies demo 40's certificate and Gateway
files, the app, the route, the unmatched-method probe, then `check.sh`,
`policy-proof.sh` and `tls-proof.sh`. It appends to
[`output/transcript.txt`](output/transcript.txt) and does not truncate
it. Every command goes through `scripts/record.sh`.

## What was recorded

The last apply (`2026-09-18T19:37:03Z`) and the last `check.sh`
(`2026-09-18T19:37:08Z`).

### 1. Deploy the app and the CiliumNetworkPolicy

apply.sh exports the live root first, then applies the Deployment, the
Service and CNP `grpc`. Last apply found poc1's route already present.

```bash
scripts/lab-trust.sh export kind-poc2
kubectl --context kind-poc2 apply -f demos/53-grpc-parity/10-poc2-grpc-app.yaml
kubectl --context kind-poc2 -n shop-edge wait deploy/grpc \
  --for=condition=Available --timeout=120s
```

Recorded (last apply):

```text
the issuer's root from kind-poc2 → .tmp/root-ca.crt: subject=CN=clustermesh-root-ca sha256 Fingerprint=F4:FD:F8:B7:78:D9:D3:9E:69:53:E1:CB:FB:26:CD:1A:9B:85:48:66:D4:48:8D:08:0F:E9:73:7E:8A:97:BF:27
```

Recorded (last apply):

```text
deployment.apps/grpc unchanged
service/grpc unchanged
ciliumnetworkpolicy.cilium.io/grpc unchanged
deployment.apps/grpc condition met
```

### 2. Add the listener and the GRPCRoute

Demo 40's files are the source of truth for `grpc-tls` and
`https-grpc`. The GRPCRoute parents both `https-grpc` and `http`.

```bash
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/20-certificates.yaml
kubectl --context kind-poc2 -n shop-edge wait certificate/grpc-tls \
  --for=condition=Ready --timeout=90s
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/30-gateways-poc2.yaml
kubectl --context kind-poc2 -n shop-edge wait --for=condition=Programmed \
  gateway/shop-gw --timeout=120s
kubectl --context kind-poc2 apply -f demos/53-grpc-parity/30-poc2-grpcroute.yaml
```

Recorded (last apply):

```text
certificate.cert-manager.io/shop-tls unchanged
certificate.cert-manager.io/grpc-tls unchanged
certificate.cert-manager.io/shop-tls condition met
certificate.cert-manager.io/grpc-tls condition met
gateway.gateway.networking.k8s.io/shop-gw configured
gateway.gateway.networking.k8s.io/shop-vip-gw configured
gateway.gateway.networking.k8s.io/shop-gw condition met
kind-poc2 gateway/shop-gw: 3/3 listeners Programmed
grpcroute.gateway.networking.k8s.io/grpc configured
kind-poc2 grpcroute/grpc: all parents Accepted+ResolvedRefs
```

The unmatched-method probe (GUIDE exercise 1) is recorded on every
apply:

```bash
docker run --rm --network kind fullstorydev/grpcurl:latest \
  -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
  172.18.255.177:80 routedemo.Echo/DoesNotExist
```

Recorded (last apply):

```text
Error invoking method "routedemo.Echo/DoesNotExist": target server does not expose service "routedemo.Echo"
```

### 3. Prove the policy drop

```bash
demos/53-grpc-parity/policy-proof.sh
```

Recorded (last apply):

```text
== 1. delete CNP grpc in shop-edge on poc2 (demo 41 default-deny then drops reserved:ingress)
ciliumnetworkpolicy.cilium.io "grpc" deleted from shop-edge namespace
== 2. grpcurl -plaintext Health/Check from the client container must fail (-max-time 10)
Error invoking method "grpc.health.v1.Health/Check": rpc error: code = DeadlineExceeded desc = failed to query for service descriptor "grpc.health.v1.Health": context deadline exceeded
== 3. hubble observe -P --kube-context kind-poc2 --to-pod shop-edge/grpc-c59b4f578-dqr55 --verdict DROPPED --last 5 -o compact
Sep 18 19:37:18.678: 10.20.0.33:53156 (ingress) <> shop-edge/grpc-c59b4f578-dqr55:9090 (ID:145376) Policy denied DROPPED (TCP Flags: SYN)
source identity 8 (reserved:ingress)
== 4. re-apply demos/53-grpc-parity/10-poc2-grpc-app.yaml
deployment.apps/grpc unchanged
service/grpc unchanged
ciliumnetworkpolicy.cilium.io/grpc created
== 5. Health/Check SERVING again
{
  "status": "SERVING"
}
policy-proof: CNP grpc required; Policy denied DROPPED from (ingress) identity 8; SERVING restored
```

### 4. Prove the leaf

```bash
demos/53-grpc-parity/tls-proof.sh
```

Recorded (last apply):

```text
== 1. openssl s_client -servername grpc.poc2.shop.poc.local -connect 172.18.255.177:443 | openssl x509 -noout -subject -issuer -ext subjectAltName -fingerprint -sha256 -dates
subject=CN=grpc.poc2.shop.poc.local
issuer=CN=clustermesh-root-ca
X509v3 Subject Alternative Name:
    DNS:grpc.poc2.shop.poc.local
sha256 Fingerprint=DD:A5:35:55:F6:93:90:9D:B4:BD:22:C1:E2:1D:94:36:E6:53:59:C1:65:AC:F6:86:3B:32:4C:FF:DB:0E:42:CF
notBefore=Sep 18 19:02:42 2026 GMT
notAfter=Dec 17 19:02:42 2026 GMT
== 2. openssl verify -CAfile .tmp/root-ca.crt .tmp/grpc-poc2.crt (want OK)
.tmp/grpc-poc2.crt: OK
== 3. openssl verify -CAfile docs/root-ca.crt .tmp/grpc-poc2.crt (want failed — issue #60)
CN=grpc.poc2.shop.poc.local
error 20 at 0 depth lookup: unable to get local issuer certificate
error .tmp/grpc-poc2.crt: verification failed
tls-proof: live root OK; docs/root-ca.crt failed (issue #60)
```

## Checks

`check.sh` at `2026-09-18T19:37:08Z`: 10 PASS, 0 FAIL, 1 WARN (11 rows).
The WARN is the missing Mac binary, not a FAIL.

Recorded (last check):

```text
### 2026-09-18T19:37:08Z
$ demos/53-grpc-parity/check.sh
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

## What is deliberately not here

- A same-hostname GRPCRoute on listener `https` — not applied; the code
  reading is in [`docs/REVIEW_DEMO53.md`](../../docs/REVIEW_DEMO53.md).
- Removing the `https-grpc` listener — cleanup leaves it; it is demo 40's
  door.
- A docker build (gotcha #118).
- Envoy Gateway doors and `docs/EG-VS-CILIUM.md` — demos 51 / 54 and
  enhancement 007 phase 4.
- `routedemo.Echo` as a reflected service — it is a health status name.
  The unmatched method and the wrong `:authority` are
  [GUIDE.md](GUIDE.md).

## Clean up

```bash
demos/53-grpc-parity/cleanup.sh
```

Removes the route, the app, CNP `grpc`, and `grpc-tls` (Certificate +
Secret). The `https-grpc` listener stays. Re-apply
`20-certificates.yaml` to restore the leaf.
