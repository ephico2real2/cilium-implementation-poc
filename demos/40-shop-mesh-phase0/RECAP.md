# Demo 40 — the shop platform's front doors on the Cilium clustermesh

This page hangs the shop platform's front doors on poc1 and poc2 before
the platform moves in. One public URL `api.shop.poc.local` sits on VIP
`172.18.255.16` from a shared LB IPAM pool (Cilium's range of addresses a
LoadBalancer Service may claim) that only one cluster announces. Each
cluster also has its own door. The doors exist and answer 404 until
demo 41 attaches routes.

## What you get

- One public URL `api.shop.poc.local` on `172.18.255.16` from
  `shared-vip-pool` `.16–.31` in both clusters; poc1 announces it
  (`lease holder=poc1-worker`).
- A door per cluster: `api.poc1.shop.poc.local` at `172.18.255.242`,
  `api.poc2.shop.poc.local` at `172.18.255.177`.
- Two Gateways per cluster: `shop-gw` (the per-cluster address) and
  `shop-vip-gw` (the VIP). A Gateway with two `spec.addresses` gets both
  IPs on one Service; the L2 policy selects Services, not IPs.
- The same leaf spec in both clusters: CN `api.shop.poc.local` plus the
  two per-cluster SANs; issuer `CN=clustermesh-root-ca`; fingerprints
  differ (poc1 `43:21:FC:A4…`, poc2 `C8:9E:AB:79…`).
- `shopapi:local` (every answer stamped `X-Served-By`) loaded on all four
  nodes; both `shopctl` clients built.
- Lease move poc1 → poc2 in ~40 ms (agent logs,
  [docs/REVIEW_DEMO40.md](../../docs/REVIEW_DEMO40.md)); a dying lease
  lingers ~15 s with an empty holder. `scripts/vip-takeover.sh` deletes
  the other policy first.
- `check.sh` at `2026-09-18T13:21:02Z`: 21 PASS, 0 FAIL. Doors answer
  404.

## Architecture

On Cilium a Gateway is listeners in the shared per-node Envoy. An L2
announcement is one node answering ARP for the address, a lease per
Service. No CiliumNetworkPolicy (a Cilium object that admits or drops
traffic by identity) and no clustermesh global Service with affinity
local (a Service that prefers backends in its own cluster) yet — those
arrive in demo 41.

```text
                  api.shop.poc.local ─── 172.18.255.16 ─── announced by ONE cluster (shop-vip-announce)
                              │                                        │
             ┌────────────────┴───────────┐             ┌──────────────┴───────────────┐
             │  poc1                      │             │  poc2                        │
             │  shop-vip-gw  .16          │             │  shop-vip-gw  .16            │
             │   https:443 api.shop.poc.local (shop-tls)│   https:443 api.shop.poc.local (shop-tls)
             │   http:80                  │             │   http:80                    │
             │                            │             │                              │
             │  shop-gw      .242         │             │  shop-gw      .177           │
             │   https:443 api.poc1.shop.poc.local      │   https:443 api.poc2.shop.poc.local
             │   http:80                  │             │   http:80                    │
             │        │  (demo 41: HTTPRoute shop-api → api-gateway, X-Served-By)
             │        ▼                   │             │        ▼                     │
             │  api-gateway (shop-edge)   │             │  api-gateway (shop-edge)     │
             └────────────────────────────┘             └──────────────────────────────┘
   pools:  shared-vip-pool .16–.31 (both clusters, only shop-vip-gw may land here)
           poc1 gateway-pool .240–.250 (shop-gw .242)
           poc2 gateway-pool .176–.186 (shop-gw .177)
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| `api.shop.poc.local` | `172.18.255.16` | the product name — the only one a customer knows | whichever cluster holds `shop-vip-announce` (poc1; `lease holder=poc1-worker`) |
| `api.poc1.shop.poc.local` | `172.18.255.242` | poc1's own door | poc1 |
| `api.poc2.shop.poc.local` | `172.18.255.177` | poc2's own door | poc2 |
| `db-service.poc.local` | `172.18.255.244` | the database door — phase 2, not created | poc1 |

`shop-vip-announce` lives in its own file so applying the shared pool on
poc2 cannot start a second announcer. kind-l2-announce excludes
`shop-vip-gw`. The lab has no DNS for `.poc.local`: clients use
`--resolve` or the hosts block.

## Prerequisites

- Both clusters up: Cilium `1.20.2` (the lab's own build), Gateway API
  and L2 already on poc2. Pins from
  [`scripts/bootstrap/versions.env`](../../scripts/bootstrap/versions.env):
  kind `v0.33.0`, kubectl `v1.36.4`, helm `v3.21.4`.

```bash
kubectl --context kind-poc1 get --raw /readyz
kubectl --context kind-poc2 get --raw /readyz
```

- A route on the Mac to the kind bridge ([SETUP.md](../../docs/SETUP.md)
  §3.5; the next hop is the Docker VM, so the Mac never ARPs for `.16`):

```bash
sudo route -n add -net 172.18.0.0/16 192.168.64.2
```

- The hosts block if a client needs the names without `--resolve` (the
  script only prints; the `tee` writes):

```bash
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
```

## Steps

Do these in order from the repo root. `apply.sh` records steps 1–5
(builds first, gotcha #118); step 6 is recorded after the check:

### 1. Build the app image

`shopapi` is `/healthz`, `/ready` (`SELECT 1`), `/orders`; one pool,
connect timeout 1 s, `SetMaxOpenConns 8`. No Deployment in this phase.

```bash
demos/40-shop-mesh-phase0/shopapi/build.sh
```

Result: `shopapi:local` loaded into poc1 and poc2 (config
`0fe50505…`).

```text
shopapi:local loaded into poc1 and poc2
```

### 2. Build the clients

Go and Python share one contract: `probe` hits every path once; `load`
prints per-second OK/FAIL and which cluster answered. Both accept a bare
number or Go units (`3`, `3s`, `500ms`). They know only the URL.

```bash
demos/40-shop-mesh-phase0/client/go/shopctl/build.sh
```

Result: both binaries written. The Python client is the script itself.

```text
wrote bin/shopctl-darwin-arm64 bin/shopctl-linux-amd64
```

### 3. Apply the pools and L2 policies

The shared pool is safe in both clusters: a static `spec.addresses`
request lands in the pool that holds the address
([enhancement 002 §8.1](../../enhancements/002-shop-platform-clustermesh.md)).

```bash
kubectl --context kind-poc1 apply -f cilium/lb-ippool-shared.yaml
kubectl --context kind-poc2 apply -f cilium/lb-ippool-shared.yaml
kubectl --context kind-poc1 apply -f cilium/lb-ippool-poc1.yaml
kubectl --context kind-poc2 apply -f cilium/lb-ippool-poc2.yaml
```

Result: `shared-vip-pool` created on both (`.16–.31`); `gateway-pool`
and kind-l2-announce configured; existing leases unchanged (`2d14h` /
`2d` on poc1; `rebel-base-lb` on poc2).

```text
ciliumloadbalancerippool.cilium.io/shared-vip-pool created
ciliuml2announcementpolicy.cilium.io/kind-l2-announce configured
cilium-l2announce-default-cilium-gateway-sw-gateway   poc1-control-plane                                                              2d14h
cilium-l2announce-default-rebel-base-lb   poc2-control-plane                                                              2d14h
```

### 4. Issue the certificates

One `Certificate` per cluster, the same spec. A wildcard
`*.shop.poc.local` covers one label and fails the two-label names
(RFC 6125).

```bash
kubectl --context kind-poc1 apply -f demos/40-shop-mesh-phase0/00-namespaces.yaml
kubectl --context kind-poc1 apply -f demos/40-shop-mesh-phase0/20-certificates.yaml
kubectl --context kind-poc1 -n shop-edge wait certificate/shop-tls \
  --for=condition=Ready --timeout=90s
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/00-namespaces.yaml
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/20-certificates.yaml
kubectl --context kind-poc2 -n shop-edge wait certificate/shop-tls \
  --for=condition=Ready --timeout=90s
```

Result: `shop-tls` Ready on both.

```text
certificate.cert-manager.io/shop-tls created
certificate.cert-manager.io/shop-tls condition met
```

### 5. Create the Gateways

Two files, one per cluster. Then `shop-vip-announce` on poc1 only
(delete from the other first).

```bash
kubectl --context kind-poc1 apply -f demos/40-shop-mesh-phase0/30-gateways-poc1.yaml
kubectl --context kind-poc1 -n shop-edge wait --for=condition=Programmed \
  gateway/shop-gw --timeout=120s
kubectl --context kind-poc1 -n shop-edge wait --for=condition=Programmed \
  gateway/shop-vip-gw --timeout=120s
kubectl --context kind-poc2 apply -f demos/40-shop-mesh-phase0/30-gateways-poc2.yaml
kubectl --context kind-poc2 -n shop-edge wait --for=condition=Programmed \
  gateway/shop-gw --timeout=120s
kubectl --context kind-poc2 -n shop-edge wait --for=condition=Programmed \
  gateway/shop-vip-gw --timeout=120s
kubectl --context kind-poc2 delete ciliuml2announcementpolicy shop-vip-announce \
  --ignore-not-found
kubectl --context kind-poc1 apply -f cilium/l2-shop-vip-announce.yaml
scripts/vip-takeover.sh --status
```

Result: all four Programmed; VIP announced by poc1,
`lease holder=poc1-worker`; poc2 `shop-vip-announce: absent`,
`lease: none`.

```text
CLUSTER  GATEWAY      ADDRESS          PROGRAMMED   CERT_READY   VIP_BY
poc1     shop-gw      172.18.255.242   True         True         -
poc1     shop-vip-gw  172.18.255.16    True         True         poc1
poc2     shop-gw      172.18.255.177   True         True         -
poc2     shop-vip-gw  172.18.255.16    True         True         poc1
```

### 6. Measure the takeover

Delete-from-the-other-first: never two announcers. `--force` skips the
delete when the other API is down and warns; `--status` then reports
UNKNOWN instead of absent.

```bash
scripts/vip-takeover.sh poc2
scripts/vip-takeover.sh --status
scripts/vip-takeover.sh poc1
```

Result: poc2 acquired the VIP lease on `poc2-control-plane` at 0 s;
poc1's lease lingered with an empty holder (`27s` in the same listing).
After 20 s: `announced by: poc2`, `lease holder=poc2-control-plane`,
poc1 `lease: none`. Restored to poc1 (`poc1-worker` at 0 s).

```text
== VIP 172.18.255.16 announced by: poc2
-- poc1
  shop-vip-announce: absent
  lease: none
-- poc2
  shop-vip-announce: present
  lease holder=poc2-control-plane
```

## Verify

From the Mac, with the route present:

```bash
curl -sk --resolve api.shop.poc.local:443:172.18.255.16 \
  -o /dev/null -w '%{http_code}\n' https://api.shop.poc.local/
```

Expect `404`. 000 is a failure — the door is unreachable.

```bash
echo | openssl s_client -servername api.shop.poc.local \
  -connect 172.18.255.16:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
```

Expect `issuer=CN=clustermesh-root-ca`, `subject=CN=api.shop.poc.local`,
and the three SANs.

```bash
demos/40-shop-mesh-phase0/check.sh
```

Recorded `2026-09-18T13:21:02Z` (21 PASS, 0 FAIL):

```text
== demo 40 — the shop platform on the mesh, phase 0 (the ground under it)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   shared-vip-pool on poc1                                                172.18.255.16–172.18.255.31                        block 172.18.255.16–172.18.255.31 in both clusters
  PASS   shared-vip-pool on poc2                                                172.18.255.16–172.18.255.31                        block 172.18.255.16–172.18.255.31 in both clusters
  PASS   shop-tls Ready on poc1                                                 Ready=True                                           Certificate shop-tls Ready=True
  PASS   shop-tls Ready on poc2                                                 Ready=True                                           Certificate shop-tls Ready=True
  PASS   poc1/shop-gw Programmed at 172.18.255.242                              addr=172.18.255.242 Programmed=True (172.18.255.242) Programmed=True and status.addresses[0]=172.18.255.242
  PASS   poc1/shop-vip-gw Programmed at 172.18.255.16                           addr=172.18.255.16 Programmed=True (172.18.255.16)   Programmed=True and status.addresses[0]=172.18.255.16
  PASS   poc2/shop-gw Programmed at 172.18.255.177                              addr=172.18.255.177 Programmed=True (172.18.255.177) Programmed=True and status.addresses[0]=172.18.255.177
  PASS   poc2/shop-vip-gw Programmed at 172.18.255.16                           addr=172.18.255.16 Programmed=True (172.18.255.16)   Programmed=True and status.addresses[0]=172.18.255.16
  PASS   exactly one cluster holds the VIP l2announce lease                     poc1 holder=poc1-worker                              lease cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw has a holderIdentity in one context, none in the other
  PASS   VIP https://api.shop.poc.local @ 172.18.255.16 answers                 http_code=404                                        http_code=404 in phase 0
  PASS   VIP leaf issuer is clustermesh-root-ca                                 issuer=CN=clustermesh-root-ca                        openssl x509 -noout -issuer contains clustermesh-root-ca
  PASS   https://api.poc1.shop.poc.local @ 172.18.255.242 answers               404                                                  http_code=404 in phase 0
  PASS   api.poc1.shop.poc.local leaf issuer is clustermesh-root-ca             issuer=CN=clustermesh-root-ca                        same root as the VIP
  PASS   https://api.poc2.shop.poc.local @ 172.18.255.177 answers               404                                                  http_code=404 in phase 0
  PASS   api.poc2.shop.poc.local leaf issuer is clustermesh-root-ca             issuer=CN=clustermesh-root-ca                        same root as the VIP
  PASS   shopapi:local on poc1-control-plane                                    crictl images | grep shopapi matched                 docker exec poc1-control-plane crictl images contains shopapi
  PASS   shopapi:local on poc1-worker                                           crictl images | grep shopapi matched                 docker exec poc1-worker crictl images contains shopapi
  PASS   shopapi:local on poc2-control-plane                                    crictl images | grep shopapi matched                 docker exec poc2-control-plane crictl images contains shopapi
  PASS   shopapi:local on poc2-worker                                           crictl images | grep shopapi matched                 docker exec poc2-worker crictl images contains shopapi
  PASS   shopctl (Go) --help                                                    demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-darwin-arm64 the darwin-arm64 / linux-amd64 binary runs --help
  PASS   shopctl.py --help                                                      demos/40-shop-mesh-phase0/client/python/shopctl.py   the Python client runs --help
```

## Reference

Certificate spec (`20-certificates.yaml`):

```yaml
kind: Certificate
spec:
  secretName: shop-tls
  commonName: api.shop.poc.local
  dnsNames:
    - api.shop.poc.local
    - api.poc1.shop.poc.local
    - api.poc2.shop.poc.local
  issuerRef: {kind: ClusterIssuer, name: ca-issuer}
```

Issued leaf: `subject=CN=api.shop.poc.local`,
`issuer=CN=clustermesh-root-ca`, the three SANs. Fingerprints differ per
cluster — poc1 `43:21:FC:A4…`, poc2 `C8:9E:AB:79…` — so a call to `.16`
that shows poc1's fingerprint reached poc1. Issuer `ca-issuer` signs
from CA secret `clustermesh-root-ca` (the same root in both clusters).
A client trusts `docs/root-ca.crt`.

On the wire, from the review pass
([docs/REVIEW_DEMO40.md](../../docs/REVIEW_DEMO40.md)): ARP for `.16`
from a container on the `kind` bridge got three replies, all from
`2a:41:4a:7f:cf:12` (poc1-control-plane). Agent logs of one flip: poc1
`Job stopped` at 12:47:23.527/.530, poc2-worker `Successfully acquired
lease` at .569 — ~40 ms poc1 → poc2; the return flip was not timed.

Lease name:
`cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw` — format
`cilium-l2announce-<namespace>-cilium-gateway-<gateway-name>`.

| File | What |
|---|---|
| [`cilium/lb-ippool-shared.yaml`](../../cilium/lb-ippool-shared.yaml) | `shared-vip-pool` `.16–.31`, selector `owning-gateway In [shop-vip-gw]` |
| [`cilium/l2-shop-vip-announce.yaml`](../../cilium/l2-shop-vip-announce.yaml) | `shop-vip-announce`; one cluster at a time |
| [`cilium/lb-ippool-poc1.yaml`](../../cilium/lb-ippool-poc1.yaml) / [`-poc2.yaml`](../../cilium/lb-ippool-poc2.yaml) | `kind-l2-announce` excludes `shop-vip-gw` |
| [`20-certificates.yaml`](20-certificates.yaml) | `Certificate` `shop-tls` — three dnsNames, not a wildcard |
| [`30-gateways-poc1.yaml`](30-gateways-poc1.yaml) / [`30-gateways-poc2.yaml`](30-gateways-poc2.yaml) | two Gateways each; poc2's `shop-gw` has `https-grpc` (demo 53) |
| [`apply.sh`](apply.sh) / [`check.sh`](check.sh) / [`cleanup.sh`](cleanup.sh) | land, prove, remove |
| [`scripts/vip-takeover.sh`](../../scripts/vip-takeover.sh) | delete-other-first; `--status`; `--force` in DR |

Address block `172.18.255.0/26` (enhancement 002 §8.1): shared pool
`.16–.31`; poc1 doors `.240–.250`; poc2 doors `.176–.186`; node-held
reservation `.40–.47` (not LB IPAM).

## Troubleshooting

- `shopctl` prints `000`: the name does not resolve and the clients have
  no `--resolve` — add the hosts block under *Prerequisites*.
- The Mac's ARP table has no entry for `172.18.255.16`: the host route's
  next hop is the Docker VM, so the Mac never ARPs for the VIP.
- Two announcers for `.16`: the policy was applied on both — move it
  with `scripts/vip-takeover.sh` (delete-other-first).

## Clean up

```bash
demos/40-shop-mesh-phase0/cleanup.sh
```

Removes the Gateways, the certificate, `Secret/shop-tls`,
`shop-vip-announce`, and `shared-vip-pool` from both clusters, and
restores kind-l2-announce without the exclusion. Keeps namespace
`shop-edge`.

## What's next

- [Demo 41](../41-shop-mesh-phase1/README.md) attaches HTTPRoutes and
  deploys the platform as clustermesh global Services with affinity
  local.
- CiliumNetworkPolicy objects are generated from the flows (cf2cnp).
- Phase 2 publishes `db-service.poc.local` at `172.18.255.244`.
- Demo 45 uses `--force` when poc1's API is gone.
- Do not rebuild during demo 41 (gotcha #118).
