# What demo 53 did — the walk-through

**The goal.** Enhancement 007 wants gRPC through the doors on both stacks — Cilium on poc1/poc2,
and Envoy Gateway with kube-vip and MetalLB later — using one app and one client. This demo is the
Cilium half: re-run demo 09's test on poc1, and give poc2 its first GRPCRoute (a Gateway API object
that matches on gRPC service name, not on a URL path) on the shop door that demos 40 and 41 already
built. Demos 51 and 52 will copy the same objects onto Envoy Gateway so a later page can put four
`SERVING` lines in one table.

**1. The same door as HTTP, a different name.** poc2's `shop-gw` (Cilium's front door — a Service
plus listeners in the node's shared Envoy proxy) already answers `https://api.poc2.shop.poc.local`
on `172.18.255.177`. Putting gRPC on that address is the enterprise case: one load-balancer IP, two
protocols. A Gateway listener has one hostname. The existing HTTPS listener is already
`api.poc2.shop.poc.local`, and demo 41's HTTPRoute occupies it. A GRPCRoute whose hostname does
not intersect the listener's hostname is not accepted, so `grpc.poc2.shop.poc.local` cannot share
the `https` listener. Gateway API requires an implementation to accept exactly one HTTPRoute or
GRPCRoute when the two route kinds overlap on the same listener and hostname. Cilium 1.20.2 does not implement that cross-kind arbitration
in its route-status path: it validates HTTPRoutes and GRPCRoutes
separately, then appends both kinds during Gateway ingestion. A hypothetical GRPCRoute
using `api.poc2.shop.poc.local` would therefore likely be accepted and rendered alongside
`shop-api`. This demo does not rely on that non-conforming behavior: the distinct
`grpc.poc2.shop.poc.local` listener avoids the conflict and remains portable to conforming
Gateway API implementations. Read from the code, not measured:
`vendor/sigs.k8s.io/gateway-api/apis/v1/grpcroute_types.go:126-137` in `~/gitRepos/cilium`;
Cilium 1.20.2 evaluates the kinds separately in `operator/pkg/gateway-api/routechecks` /
`status_route.go:77-98,144-150,178-207` and appends both in `ingestion/gateway.go:194-210`. This
demo does not apply a conflicting route. So poc2 gained a third listener, `https-grpc`, still on
port 443, distinguished by SNI (the name the client presents in the TLS handshake) — the same
pattern demo 09 used for its wildcard and exact certificates. The plain HTTP listener on port 80
has no hostname and already serves any Host; the GRPCRoute attaches there too, which is gRPC over
cleartext HTTP/2 (h2c). `:authority` is the HTTP/2 header the route's hostnames match on;
`grpcurl -authority` sets it.

**2. A second leaf from the same root.** `shop-tls` cannot grow this name: adding a SAN would not
change the listener's hostname, and the listener is what SNI selects. Certificate `grpc-tls` is
issued in `shop-edge` by the same ClusterIssuer `ca-issuer`: common name and the one SAN
`grpc.poc2.shop.poc.local`. `tls-proof.sh` recorded `subject=CN=grpc.poc2.shop.poc.local`,
`issuer=CN=clustermesh-root-ca`, `sha256 Fingerprint=DD:A5:35:55:F6:93:90:9D:B4:BD:22:C1:E2:1D:94:36:E6:53:59:C1:65:AC:F6:86:3B:32:4C:FF:DB:0E:42:CF`,
`notBefore=Sep 18 19:02:42 2026 GMT`, `notAfter=Dec 17 19:02:42 2026 GMT`.
`openssl verify -CAfile .tmp/root-ca.crt .tmp/grpc-poc2.crt` printed `.tmp/grpc-poc2.crt: OK`.
`openssl verify -CAfile docs/root-ca.crt .tmp/grpc-poc2.crt` printed `unable to get local issuer certificate`
and `error .tmp/grpc-poc2.crt: verification failed` ([issue #60](https://github.com/ephico2real2/cilium-implementation-poc/issues/60)).
The live root fingerprint in the same transcript is
`sha256 Fingerprint=F4:FD:F8:B7:78:D9:D3:9E:69:53:E1:CB:FB:26:CD:1A:9B:85:48:66:D4:48:8D:08:0F:E9:73:7E:8A:97:BF:27`,
so every TLS client in this demo mounts `.tmp/root-ca.crt` exported from secret
`clustermesh-root-ca`, the same file demo 39 uses. grpcurl will not take `-authority` and
`-servername` together; `-authority` is the TLS server name.

**3. poc1 had nothing to re-run until the apps came back.** The brief's starting fact was that
demo 09's `GRPCRoute` still sat on `routes-gw` at `172.18.255.240`. It did not:
`kubectl --context kind-poc1 get grpcroute -A` was empty, because the lab's stack script applies
only the Gateway, not the demo 09 apps and routes. Those two files were applied on poc1 so the
re-run had a target. After that, `grpcurl -plaintext -authority grpc.poc.local 172.18.255.240:80
grpc.health.v1.Health/Check` and the TLS form on `:443` both returned `"status": "SERVING"`.

**4. The first apply on poc2 was accepted and still dropped.** The Deployment, the Service
(`appProtocol: kubernetes.io/h2c`, without which Envoy speaks HTTP/1.1 to the pod), the
Certificate, the third listener and the GRPCRoute all came up: three listeners Programmed, the
route Accepted and ResolvedRefs on both parents, and the pod Available. `Health/Check` against
`.177` then hit a deadline. Every apply re-proves that drop through `policy-proof.sh`; Hubble
named it:
`Sep 18 19:37:18.678: 10.20.0.33:53156 (ingress) <> shop-edge/grpc-c59b4f578-dqr55:9090 (ID:145376) Policy denied DROPPED (TCP Flags: SYN)`.
`source identity 8 (reserved:ingress)`. Demo 41 left a default-deny policy in `shop-edge` that
selects every pod labelled `part-of: shop`. Its `ingress: [{}]` section contains no explicit allow,
so the endpoint's only realized ingress allowance was Cilium's localhost rule. Kubelet
probes (`reserved:host`) worked and the Gateway's identity (`reserved:ingress`) did not. A small
policy using the same `fromEntities: ingress` allowance as the generated `api-gateway` rule,
restricted to TCP/9090, turned the second apply into `SERVING` on plaintext and TLS.

**5. Reflection lists three names, not four.** `grpcurl list` on both clusters prints
`grpc.health.v1.Health` and both `ServerReflection` services, which is exactly what demo 09
recorded. `routedemo.Echo` is a health status the process sets so a route *could* match on that
name; it is not a service reflection can list. Calling `routedemo.Echo/DoesNotExist` returns
`target server does not expose service "routedemo.Echo"`: grpcurl asks reflection (which is
matched) for a descriptor, then the backend says no. A wrong Host, `wrong.poc.local`, returns
`server does not support the reflection API` — no GRPCRoute matched, so reflection is not
forwarded. That is what Cilium's Envoy does with a name nobody claimed as gRPC.

**6. One source of truth for the door.** A Gateway's listeners are one object. The third listener
and the Certificate were added to demo 40's files, and this demo's apply runs those files rather
than a copy. Cleanup removes the route, the app, the policy and the leaf, and leaves the
listener: it is now part of poc2's door. The Mac has no `grpcurl`; that check is a warning with
`brew install grpcurl`, not a failure. No image was built (gotcha #118); `routedemo:local` was
already on all four nodes.

**The reference card — names, addresses, certificates, doors.** Read from the live clusters
(`kubectl --context kind-poc2 -n shop-edge get gateway,certificate,grpcroute`, `openssl s_client`,
the transcript).

*The names and their addresses.*

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `grpc.poc.local` | `172.18.255.240` | demo 09's gRPC name on poc1's `routes-gw` | poc1 |
| `grpc.poc2.shop.poc.local` | `172.18.255.177` | poc2's gRPC name on `shop-gw` | poc2 |
| `api.poc2.shop.poc.local` | `172.18.255.177` | the shop HTTP name, same door, different listener | poc2 |

*The certificate.* One `Certificate` `grpc-tls` in `shop-edge` on poc2 (also present in the
shared manifest demo 40 applies; unused on poc1, which has no `https-grpc` listener):

```yaml
kind: Certificate                     # cert-manager.io/v1, namespace shop-edge
spec:
  secretName: grpc-tls
  commonName: grpc.poc2.shop.poc.local
  dnsNames:
    - grpc.poc2.shop.poc.local        # CN repeated as the only SAN
  issuerRef: {kind: ClusterIssuer, name: ca-issuer}   # → CA secret clustermesh-root-ca
```

One name, not three: this leaf is for one listener on one cluster, not for a VIP that can move.
A wildcard `*.shop.poc.local` would not cover the two-label name (demo 40 already measured that
for the HTTP names). The issued leaf: `subject=CN=grpc.poc2.shop.poc.local`,
`issuer=CN=clustermesh-root-ca`, SAN `DNS:grpc.poc2.shop.poc.local`,
`notBefore=Sep 18 19:02:42 2026 GMT`, `notAfter=Dec 17 19:02:42 2026 GMT`,
fingerprint `DD:A5:35:55:F6:93:90:9D:B4:BD:22:C1:E2:1D:94:36:E6:53:59:C1:65:AC:F6:86:3B:32:4C:FF:DB:0E:42:CF`.
A client trusts `.tmp/root-ca.crt` (the live root), not `docs/root-ca.crt` (issue #60).

*The door.* poc2 `shop-gw` after this demo, three listeners, one address:

```text
                  grpc.poc2.shop.poc.local ─── 172.18.255.177 ─── poc2 (kind-l2-announce)
                  api.poc2.shop.poc.local  ─── 172.18.255.177 ─── same Service, SNI picks the cert
                              │
             ┌────────────────┴──────────────────────────────┐
             │  poc2  shop-gw  .177                          │
             │   https:443      api.poc2.shop.poc.local  (shop-tls)  → HTTPRoute shop-api
             │   https-grpc:443 grpc.poc2.shop.poc.local (grpc-tls)  → GRPCRoute grpc
             │   http:80        (no hostname)                        → both, by Host / :authority
             │        │                                              │
             │        ▼                                              ▼
             │  api-gateway :80                          grpc :9090 (routedemo -mode grpc)
             └───────────────────────────────────────────────────────┘
```

**What the review caught** (Codex and Grok, `docs/REVIEW_DEMO53.md`; OB1's pass is owed — the Fable usage
limit ended it, as it did for demo 41):

- The apply script wiped the transcript on every run, so the Hubble drop and the certificate checks quoted here
  lived in no artefact. They are now recorded proofs that every apply re-runs: delete the policy, watch the drop,
  restore it, watch `SERVING` return; and both `openssl verify` outcomes.
- Cilium 1.20.2 appears not to implement the Gateway API's rule that an HTTPRoute and a GRPCRoute overlapping on
  one listener and hostname must have exactly one accepted — read from its code, not measured; this demo never
  relied on it, which is why the gRPC name has its own listener.
- The regression row's "not found means skip" also matched a missing `kubectl`; a missing tool is a failure now.
- This recap had called the default-deny rule "allow-all"; Cilium's docs say the opposite, and so does step 4 now.
- Demo 40's own check had been failing its door rows since demo 41 attached routes (its rule wanted 404); the rule
  now accepts 404 before routes and 200 after.

Before the review, the first apply had already changed three things: poc1's route restored (the stack script never
applied it), TLS against the live root (the file in `docs/` is the previous build's — issue #60), and the
`fromEntities: ingress` policy after demo 41's default-deny dropped the Gateway's first call.

**What you can do with it right now.**

- `docker run --rm --network kind fullstorydev/grpcurl:latest -plaintext -authority grpc.poc2.shop.poc.local 172.18.255.177:80 grpc.health.v1.Health/Check` — `"status": "SERVING"`.
- The same command with `-authority grpc.poc.local` and `172.18.255.240:80` — poc1, still SERVING.
- `demos/53-grpc-parity/check.sh` — ten PASS rows and a WARN if `grpcurl` is not on the Mac.
- `demos/53-grpc-parity/GUIDE.md` exercise 2 — the wrong Host, and the sentence Envoy actually returns.

**Where the next demo starts.** Demos 51 and 52 take this app, this client and this route shape
onto Envoy Gateway's doors, one load balancer each. The two `SERVING` lines above are the Cilium
column of that comparison; `docs/EG-VS-CILIUM.md` is written in enhancement 007 phase 4, not here.
