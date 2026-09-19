# Demo 40 — the shop platform on the mesh, phase 0: the ground under it

For the reader in a hurry: [RECAP.md](RECAP.md) — the guide

This is phase 0 of [enhancement 002](../../enhancements/002-shop-platform-clustermesh.md)
revision 4, tracking issue #42. Demo 35 is the platform this builds on;
demo 41 (phase 1) deploys that platform behind these doors. This phase
only lays the ground: the shared VIP, a door per cluster, the leaf, the
image, and both clients.

Builds happen here (`shopapi:local`, both `shopctl`s). That is a build
on the Docker VM, and it is allowed in this phase (gotcha #118).
Measurements start in demo 41, after the VM is quiet.

## Summary context — the enterprise case

One public URL, a door per cluster, the VIP announced by one cluster at
a time. An external customer keeps calling `https://api.shop.poc.local`
through every failure; what happens behind that address is the mesh's
business. Each cluster also has its own door
(`api.poc1.shop.poc.local`, `api.poc2.shop.poc.local`) so an operator
can watch one side without going through the VIP.

The VIP cannot share a Service with the per-cluster address. Measured
2026-09-18 on poc1, Cilium 1.20.2: a Gateway with two `spec.addresses`
gets both IPs on its single Service. A `CiliumL2AnnouncementPolicy`
selects Services, not IPs, so that Gateway would have poc2 announce the
VIP too — an ARP conflict on the kind bridge. Phase 0 therefore creates
two Gateways per cluster: `shop-gw` (the per-cluster address, announced
by kind-l2-announce) and `shop-vip-gw` (`.16`, announced only where
`shop-vip-announce` is applied).

The doors exist and are Programmed. They answer 404 until demo 41
attaches the platform. No HTTPRoutes and no backends in this phase. The
path a request takes is in the [RECAP Architecture](RECAP.md#architecture).

## Files

| File | What |
|---|---|
| [`cilium/lb-ippool-shared.yaml`](../../cilium/lb-ippool-shared.yaml) | `shared-vip-pool` `.16–.31`, selector `owning-gateway In [shop-vip-gw]`; both clusters |
| [`cilium/l2-shop-vip-announce.yaml`](../../cilium/l2-shop-vip-announce.yaml) | `shop-vip-announce`; applied to **one** cluster (poc1 in this phase) |
| [`cilium/lb-ippool-poc1.yaml`](../../cilium/lb-ippool-poc1.yaml) / [`-poc2.yaml`](../../cilium/lb-ippool-poc2.yaml) | `kind-l2-announce` now excludes `shop-vip-gw` |
| [`00-namespaces.yaml`](00-namespaces.yaml) | `shop-edge` with demo 35's `part-of=shop` and `gateway-access: shop-gw` |
| [`20-certificates.yaml`](20-certificates.yaml) | `Certificate/shop-tls` — three dnsNames, not a wildcard; `Certificate/grpc-tls` (demo 53, CN/SAN `grpc.poc2.shop.poc.local`) |
| [`30-gateways-poc1.yaml`](30-gateways-poc1.yaml) / [`30-gateways-poc2.yaml`](30-gateways-poc2.yaml) | two files a junior can read; no Helm, no kustomize. poc2's `shop-gw` has a third listener `https-grpc` (demo 53) |
| [`apply.sh`](apply.sh) | both contexts, recorded into [`output/transcript.txt`](output/transcript.txt) |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`hosts-entries.sh`](hosts-entries.sh) | prints four `/etc/hosts` lines from live state; never writes |
| [`cleanup.sh`](cleanup.sh) | doors, leaf, announcer, shared pool; restores L2 without the exclusion; namespaces kept |
| [`scripts/vip-takeover.sh`](../../scripts/vip-takeover.sh) | delete from the other first, then apply; `--status`; `--force` in DR |
| [`shopapi/`](shopapi/) | Go backend (`/healthz`, `/ready`, `/orders`); image loaded, no Deployment |
| [`client/go/shopctl/`](client/go/shopctl/) / [`client/python/shopctl.py`](client/python/shopctl.py) | one contract, same table columns |
| [`GUIDE.md`](GUIDE.md) | hosts-block prerequisite and five exercises |

The shared pool is applied to **both** clusters. That is safe: a static
`spec.addresses` request lands in the pool that holds the address, and
only one cluster announces it. The L2 policy `shop-vip-announce` lives
in its own file, not in the pool file, so applying the pool on poc2
cannot start a second announcer.

## Run it

From the repo root. Both clusters up (Gateway API and L2 already on
poc2):

```bash
demos/40-shop-mesh-phase0/apply.sh
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
demos/40-shop-mesh-phase0/check.sh
```

Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt) (append, never
truncate). `apply.sh` sets `RECORD_STRICT=1`.

## What was recorded

The last apply (`2026-09-18T13:20:26Z`) and the takeover recorded after
it. Each step below quotes that apply.

### 1. Apply the pools and L2 policies

The shared pool on both contexts, then the per-cluster pool files
(leases printed before and after). Applying the edited kind-l2-announce
(NotIn `shop-vip-gw`) re-evaluates leases. The selector excluded a
Service that did not exist yet; nothing had to be dropped.

```bash
kubectl --context kind-poc1 apply -f cilium/lb-ippool-shared.yaml
kubectl --context kind-poc2 apply -f cilium/lb-ippool-shared.yaml
kubectl --context kind-poc1 apply -f cilium/lb-ippool-poc1.yaml
kubectl --context kind-poc2 apply -f cilium/lb-ippool-poc2.yaml
```

Recorded (last apply):

```text
ciliumloadbalancerippool.cilium.io/shared-vip-pool created
ciliumloadbalancerippool.cilium.io/kind-docker-pool unchanged
ciliumloadbalancerippool.cilium.io/gateway-pool configured
ciliuml2announcementpolicy.cilium.io/kind-l2-announce configured
cilium-l2announce-default-cilium-gateway-sw-gateway   poc1-control-plane                                                              2d14h
cilium-l2announce-kube-system-hubble-ui               poc1-control-plane                                                              2d14h
cilium-l2announce-routes-cilium-gateway-routes-gw     poc1-control-plane                                                              2d14h
cilium-l2announce-team-b-cilium-gateway-team-b-gw     poc1-control-plane                                                              2d
cilium-l2announce-default-rebel-base-lb   poc2-control-plane                                                              2d14h
```

### 2. Issue the certificates

One `Certificate` covers three names (the CN is the product name).
Gateways live in `shop-edge` with the Secret, so no ReferenceGrant. A
wildcard `*.shop.poc.local` would not cover the two-label per-cluster
names; the three dnsNames are listed in full.

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

Recorded (last apply):

```text
namespace/shop-edge unchanged
certificate.cert-manager.io/shop-tls created
certificate.cert-manager.io/shop-tls condition met
```

### 3. Create the Gateways

Two Gateways per cluster via `spec.addresses` (type `IPAddress`). New
leases appeared only when the Gateways were created:
`cilium-l2announce-shop-edge-cilium-gateway-shop-gw` (both clusters) and
`cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw` (poc1 only).
Then `shop-vip-announce` on poc1 only.

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

Recorded (last apply):

```text
gateway.gateway.networking.k8s.io/shop-gw created
gateway.gateway.networking.k8s.io/shop-vip-gw created
gateway.gateway.networking.k8s.io/shop-gw condition met
gateway.gateway.networking.k8s.io/shop-vip-gw condition met
ciliuml2announcementpolicy.cilium.io/shop-vip-announce created
== VIP 172.18.255.16 announced by: poc1
-- poc1
  shop-vip-announce: present
  lease holder=poc1-worker
-- poc2
  shop-vip-announce: absent
  lease: none
CLUSTER  GATEWAY      ADDRESS          PROGRAMMED   CERT_READY   VIP_BY
poc1     shop-gw      172.18.255.242   True         True         -
poc1     shop-vip-gw  172.18.255.16    True         True         poc1
poc2     shop-gw      172.18.255.177   True         True         -
poc2     shop-vip-gw  172.18.255.16    True         True         poc1
```

### 4. Build the app image

`shopapi` opens one connection pool with a one-second connect timeout
and runs as a non-root static binary. apply.sh loads the image onto all
four nodes. No Deployment.

```bash
demos/40-shop-mesh-phase0/shopapi/build.sh
```

Recorded (last apply):

```text
#17 exporting config sha256:0fe505058b3662534f6a431d2848ad3dd7d7d03b76e021bb7320f12421bbc2a4 done
Image: "shopapi:local" with ID "sha256:a18c0904a8767fc195926b31b6337a3c7de70644be7daaf84acf072c7c252b4d" not yet present on node "poc1-control-plane", loading...
Image: "shopapi:local" with ID "sha256:a18c0904a8767fc195926b31b6337a3c7de70644be7daaf84acf072c7c252b4d" not yet present on node "poc1-worker", loading...
Image: "shopapi:local" with ID "sha256:a18c0904a8767fc195926b31b6337a3c7de70644be7daaf84acf072c7c252b4d" not yet present on node "poc2-control-plane", loading...
Image: "shopapi:local" with ID "sha256:a18c0904a8767fc195926b31b6337a3c7de70644be7daaf84acf072c7c252b4d" not yet present on node "poc2-worker", loading...
shopapi:local loaded into poc1 and poc2
```

### 5. Build the clients

Go and Python accept the same `--duration` / `--timeout` spelling (a
bare number is seconds, or a Go duration: `3`, `3s`, `500ms`) and print
the same nearest-rank percentiles on the same sample. M seconds = M
one-second batches; the run ends after the last batch. Neither client
knows there are two clusters; `X-Served-By` is only reported.

```bash
demos/40-shop-mesh-phase0/client/go/shopctl/build.sh
```

Recorded (last apply):

```text
wrote bin/shopctl-darwin-arm64 bin/shopctl-linux-amd64
```

Against a local HTTP server (default path `/healthz` is 404, so every
second is a fail):

```bash
demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-darwin-arm64 \
  load --rate 5 --duration 2 --timeout 500ms
```

```text
SECOND   OK     FAIL   X-SERVED-BY
1        0      5      -
2        0      5      -
latency_ms  p50=2.6  p95=9.8  p99=9.8  max=9.8
```

```bash
python3 demos/40-shop-mesh-phase0/client/python/shopctl.py \
  load --rate 5 --duration 2 --timeout 500ms
```

```text
SECOND   OK     FAIL   X-SERVED-BY
1        0      5      -
2        0      5      -
latency_ms  p50=4.1  p95=10.2  p99=10.2  max=11.0
```

### 6. Measure the takeover

Delete-from-the-other-first. poc2 acquired the VIP lease on
`poc2-control-plane` at 0 s; poc1's lease lingered with an empty holder
(`27s` age in the same listing) then vanished. Immediately after the
flip, `--status` printed `announced by: poc2` — a dying lease is not a
second announcer. Restored to poc1 (`poc1-worker` at 0 s).

`arp -n 172.18.255.16` on this Mac: no entry. The host route sends
`172.18.0.0/16` to the Docker VM; the next hop is the VM, not `.16`.

```bash
scripts/vip-takeover.sh poc2
scripts/vip-takeover.sh --status
scripts/vip-takeover.sh poc1
```

Recorded (last apply):

```text
== takeover: poc2 will announce 172.18.255.16 (delete poc1 first)
ciliuml2announcementpolicy.cilium.io "shop-vip-announce" deleted
ciliuml2announcementpolicy.cilium.io/shop-vip-announce created
cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw   poc2-control-plane                                                              0s
cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw                                                                                   27s
== VIP 172.18.255.16 announced by: poc2
```

Recorded (last apply):

```text
== VIP 172.18.255.16 announced by: poc2
-- poc1
  shop-vip-announce: absent
  lease: none
-- poc2
  shop-vip-announce: present
  lease holder=poc2-control-plane
== arp -n 172.18.255.16
172.18.255.16 (172.18.255.16) -- no entry
```

Recorded (last apply):

```text
== takeover: poc1 will announce 172.18.255.16 (delete poc2 first)
cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw   poc1-worker                                                                     0s
== VIP 172.18.255.16 announced by: poc1
```

Recorded (last apply):

```text
== VIP 172.18.255.16 announced by: poc1
-- poc1
  shop-vip-announce: present
  lease holder=poc1-worker
-- poc2
  shop-vip-announce: absent
  lease: none
```

## Checks

`check.sh` at `2026-09-18T13:21:02Z`: 21 PASS, 0 FAIL. 404 is a PASS in
phase 0: the door exists. 000 is a FAIL. After demo 41 attaches routes
the doors return 200; `check.sh` PASSes on 404 or 200 and FAILs on 000
or any other code.

Recorded (last apply):

```text
### 2026-09-18T13:21:02Z
$ demos/40-shop-mesh-phase0/check.sh
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

## What is deliberately not here

- HTTPRoutes and backends — demo 41. 404 is the pass mark.
- `db-service.poc.local` / `db-gw` at `172.18.255.244` — phase 2.
- CiliumNetworkPolicy — generated from flows in demo 41.
- A clustermesh global Service with affinity local — demo 41.
- A write to `/etc/hosts` — `hosts-entries.sh` prints the block; checks
  use `--resolve`.
- A unique VIP marker via `spec.infrastructure.labels` — the marker is
  the Gateway **name** (`io.cilium.gateway/owning-gateway`). Another
  namespace's `shop-vip-gw` would match. The lab has one `shop-edge`.
  Not measured on Cilium 1.20.2 yet.

## Clean up

```bash
demos/40-shop-mesh-phase0/cleanup.sh
```

Removes the Gateways, the certificate, the leftover `Secret/shop-tls`,
`shop-vip-announce`, and `shared-vip-pool` from both clusters, and
restores kind-l2-announce **without** the exclusion (an inline
manifest — the on-disk pool files keep the exclusion for the next
`apply.sh`). KEPT: namespace `shop-edge` and the `gateway-access:
shop-gw` label apply.sh added to it.
