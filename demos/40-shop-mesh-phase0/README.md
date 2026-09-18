# Demo 40 — the shop platform on the mesh, phase 0: the ground under it

For the reader in a hurry: [RECAP.md](RECAP.md) — what this demo did and proved, in plain English.

**Where this sits in the whole:** [enhancement 002](../../enhancements/002-shop-platform-clustermesh.md)
revision 4, tracking issue #42. Demo 35 is the platform this builds on; demo 41 (phase 1) deploys that
platform behind these doors and starts measuring. This phase only lays the ground.

Builds happen here (`shopapi:local`, both `shopctl`s). That is a build on the Docker VM, and it is
allowed in this phase (gotcha #118). Measurements start in demo 41, after the VM is quiet.

## Summary context — the enterprise case

One public URL, a door per cluster, the VIP announced by one cluster at a time. An external customer
keeps calling `https://api.shop.poc.local` through every failure; what happens behind that address is
the mesh's business. Each cluster also has its own door (`api.poc1.shop.poc.local`,
`api.poc2.shop.poc.local`) so an operator can watch one side without going through the VIP.

The VIP cannot share a Service with the per-cluster address. Measured 2026-09-18 on poc1, Cilium
1.20.2: a Gateway with two `spec.addresses` gets **both** IPs on its single Service
(`cilium-gateway-two-addr lb=172.18.255.246 172.18.255.247`, Programmed=True). A
`CiliumL2AnnouncementPolicy` selects Services, not IPs, so that Gateway would have poc2 announce the
VIP too — an ARP conflict on the kind bridge. Phase 0 therefore creates two Gateways per cluster:
`shop-gw` (the per-cluster address, announced by `kind-l2-announce`) and `shop-vip-gw` (`.16`,
announced only where `shop-vip-announce` is applied).

The doors exist and are Programmed. They answer **404** until demo 41 attaches the platform. No
HTTPRoutes and no backends in this phase.

### Address plan ([enhancement 002 §8.1](../../enhancements/002-shop-platform-clustermesh.md))

| Name | Address | Who announces | Pool |
|---|---|---|---|
| `api.shop.poc.local` (VIP) | `172.18.255.16` | one cluster at a time (`shop-vip-announce`) | `shared-vip-pool` `.16–.31` |
| `api.poc1.shop.poc.local` | `172.18.255.242` | poc1 (`kind-l2-announce`) | poc1 `gateway-pool` |
| `api.poc2.shop.poc.local` | `172.18.255.177` | poc2 (`kind-l2-announce`) | poc2 `gateway-pool` |
| `db-service.poc.local` | `172.18.255.244` | poc1 (phase 2) | poc1 `gateway-pool` |
| node-held reservation | `172.18.255.40–.47` | not LB IPAM | — |

The shared pool is applied to **both** clusters. That is safe: a static `spec.addresses` request
lands in the pool that holds the address, and only one cluster announces it. The L2 policy
`shop-vip-announce` lives in its own file (`cilium/l2-shop-vip-announce.yaml`), not in the pool
file, so applying the pool on poc2 cannot start a second announcer.

## Files

| File | What |
|---|---|
| [`cilium/lb-ippool-shared.yaml`](../../cilium/lb-ippool-shared.yaml) | `shared-vip-pool` `.16–.31`, selector `owning-gateway In [shop-vip-gw]`; both clusters |
| [`cilium/l2-shop-vip-announce.yaml`](../../cilium/l2-shop-vip-announce.yaml) | `shop-vip-announce`; applied to **one** cluster (poc1 in this phase) |
| [`cilium/lb-ippool-poc1.yaml`](../../cilium/lb-ippool-poc1.yaml) / [`-poc2.yaml`](../../cilium/lb-ippool-poc2.yaml) | `kind-l2-announce` now excludes `shop-vip-gw` |
| [`00-namespaces.yaml`](00-namespaces.yaml) | `shop-edge` with demo 35's `part-of=shop` and `gateway-access: shop-gw` |
| [`20-certificates.yaml`](20-certificates.yaml) | `Certificate/shop-tls` — three dnsNames, not a wildcard |
| [`30-gateways-poc1.yaml`](30-gateways-poc1.yaml) / [`30-gateways-poc2.yaml`](30-gateways-poc2.yaml) | two files a junior can read; no Helm, no kustomize |
| [`apply.sh`](apply.sh) | both contexts, recorded into [`output/transcript.txt`](output/transcript.txt) |
| [`check.sh`](check.sh) | PASS/FAIL rows; exit = FAIL count |
| [`hosts-entries.sh`](hosts-entries.sh) | prints four `/etc/hosts` lines from live state; never writes |
| [`cleanup.sh`](cleanup.sh) | doors, leaf, announcer, shared pool; restores L2 without the exclusion; namespaces kept |
| [`scripts/vip-takeover.sh`](../../scripts/vip-takeover.sh) | delete from the other first, then apply; `--status` |
| [`shopapi/`](shopapi/) | Go backend (`/healthz`, `/ready`, `/orders`); image loaded, no Deployment |
| [`client/go/shopctl/`](client/go/shopctl/) / [`client/python/shopctl.py`](client/python/shopctl.py) | one contract, same table columns |

## The clients

Go and Python accept the same `--duration` / `--timeout` spelling (a bare number is seconds, or a
Go duration: `3`, `3s`, `500ms`) and print the same nearest-rank percentiles on the same sample.
M seconds = M one-second batches; the run ends after the last batch.

Against `python3 -m http.server` (default path `/healthz` is 404, so every second is a fail):

Go `shopctl load --rate 5 --duration 2 --timeout 500ms`:

```text
SECOND   OK     FAIL   X-SERVED-BY
1        0      5      -
2        0      5      -
latency_ms  p50=2.6  p95=9.8  p99=9.8  max=9.8
```

Python `shopctl.py load --rate 5 --duration 2 --timeout 500ms`:

```text
SECOND   OK     FAIL   X-SERVED-BY
1        0      5      -
2        0      5      -
latency_ms  p50=4.1  p95=10.2  p99=10.2  max=11.0
```

## Steps

From the repo root, both clusters up (Gateway API and L2 already on poc2):

```bash
demos/40-shop-mesh-phase0/apply.sh
demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
demos/40-shop-mesh-phase0/check.sh
```

`apply.sh` builds `shopapi:local` and `kind load`s it into both clusters, cross-compiles `shopctl`,
applies the shared pool, the edited L2 policies (leases printed before and after), the namespace,
the certificate (Ready ≤ 90 s), the two Gateways (Programmed ≤ 120 s), and `shop-vip-announce` on
poc1. Every command is recorded through `scripts/record.sh` into
[`output/transcript.txt`](output/transcript.txt).

Final table from this run:

```text
CLUSTER  GATEWAY      ADDRESS          PROGRAMMED   CERT_READY   VIP_BY
poc1     shop-gw      172.18.255.242   True         True         -
poc1     shop-vip-gw  172.18.255.16    True         True         poc1
poc2     shop-gw      172.18.255.177   True         True         -
poc2     shop-vip-gw  172.18.255.16    True         True         poc1
```

`check.sh` (exit 0), recorded 2026-09-18 (condensed; the lease line is verbatim from
[`output/transcript.txt`](output/transcript.txt)):

```text
  PASS   shared-vip-pool on poc1 / poc2                                         172.18.255.16–172.18.255.31
  PASS   shop-tls Ready on poc1 / poc2                                          Ready=True
  PASS   poc1/shop-gw Programmed at 172.18.255.242
  PASS   poc1/shop-vip-gw Programmed at 172.18.255.16
  PASS   poc2/shop-gw Programmed at 172.18.255.177
  PASS   poc2/shop-vip-gw Programmed at 172.18.255.16
  PASS   exactly one cluster holds the VIP l2announce lease                     poc1 holder=poc1-worker
  PASS   VIP https://api.shop.poc.local @ 172.18.255.16 answers                  http_code=404
  PASS   VIP leaf issuer is clustermesh-root-ca                                 issuer=CN=clustermesh-root-ca
  PASS   per-cluster doors @ .242 and .177                                      http_code=404, same issuer
  PASS   shopapi:local on all four nodes
  PASS   shopctl (Go) --help / shopctl.py --help
```

404 is a PASS in phase 0: the door exists. 000 is a FAIL. Demo 41 is where a 200 is the goal.

`hosts-entries.sh` never writes `/etc/hosts`. From live state this run:

```text
172.18.255.16  api.shop.poc.local
172.18.255.242  api.poc1.shop.poc.local
172.18.255.177  api.poc2.shop.poc.local
# db-service.poc.local  — phase 2 (db-gw does not exist yet)
```

## What was measured

**The two-address Gateway fact (2026-09-18, poc1, Cilium 1.20.2), built on here.** A Gateway with two
`spec.addresses` gets both IPs on one Service. This phase therefore uses one address per Gateway via
`spec.addresses` (type `IPAddress`). Live result: poc1 `shop-gw` Service
`cilium-gateway-shop-gw` `EXTERNAL-IP=172.18.255.242`; `shop-vip-gw` `172.18.255.16`; poc2
`.177` and `.16`. Each Gateway's status has exactly one address. Programmed=True with no routes.

**Lease movement when the L2 selector changed.** Applying the edited `kind-l2-announce` (NotIn
`shop-vip-gw`) on a live cluster re-evaluates leases. Before and after on poc1, the four existing
holders were unchanged — same names, same nodes, same ages (`2d14h` / `2d`). poc2's
`rebel-base-lb` lease likewise did not move. The selector excluded a Service that did not exist yet;
nothing had to be dropped. New leases appeared only when the Gateways were created:
`cilium-l2announce-shop-edge-cilium-gateway-shop-gw` (both clusters) and
`cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw` (poc1 only). The VIP lease name format
matches the existing ones: `cilium-l2announce-<namespace>-cilium-gateway-<gateway-name>`.

**The certificate issuers.** Both clusters' `ca-issuer` sign from `clustermesh-root-ca`. Each
cluster issued its own `shop-tls` leaf, Ready in under a second. From the Mac, all three doors
present `issuer=CN=clustermesh-root-ca` with SANs
`DNS:api.shop.poc.local, DNS:api.poc1.shop.poc.local, DNS:api.poc2.shop.poc.local`. A wildcard
`*.shop.poc.local` would not cover the two-label per-cluster names; the three dnsNames are listed
in full.

**`vip-takeover.sh poc2`, then back to poc1.** Delete-from-the-other-first: poc2 acquired the VIP
lease on `poc2-control-plane` at 0s; poc1's lease lingered with an empty holder (`27s` age in the
same listing) then vanished. Immediately after the flip, `--status` printed
`announced by: poc2` — a dying lease is not a second announcer. After 20 s:

```text
== VIP 172.18.255.16 announced by: poc2
-- poc1
  shop-vip-announce: absent
  lease: none
-- poc2
  shop-vip-announce: present
  lease holder=poc2-control-plane
```

Restored to poc1 (`poc1-worker` at 0s). After 20 s: `announced by: poc1`,
`lease holder=poc1-worker`, poc2 `lease: none`.

**`arp -n 172.18.255.16` on this Mac: no entry.** The Mac does not ARP for the VIP. The host route
(NETWORKING_DESIGN §4.3) sends `172.18.0.0/16` to the Docker VM; the next hop in `arp -n` is the
VM, not `.16`. `curl --resolve` to `.16` still returns 404, which is the proof the announcer is
reachable. On a Linux box on the kind bridge, `ip neigh` would show the node that holds the lease.

**`shopctl probe` without `/etc/hosts` returns 000.** The client knows only `--url`; it has no
`--resolve`. `check.sh` pins the name with `curl --resolve` and sees 404. After
`hosts-entries.sh | sudo tee -a /etc/hosts`, `shopctl probe` sees the same 404s (GUIDE exercise 3).

## Known limitations

The VIP marker is the Gateway **name** via Cilium's `io.cilium.gateway/owning-gateway` label —
another namespace's Gateway named `shop-vip-gw` would match the shared pool and the announce
policy. The lab has one `shop-edge` namespace. A propagated `spec.infrastructure.labels` marker
is the hardening to measure in a later phase (rejected for phase 0: not measured on Cilium 1.20.2
yet).

The lab regression's lease row (`scripts/lab-regression.sh:186–196`) fails on **any** empty-holder
lease, so a takeover's ~15 s dying lease inside a regression window would trip it. A note for
phase 5, not a change now.

## Cleanup

```bash
demos/40-shop-mesh-phase0/cleanup.sh
```

Removes the Gateways, the certificate, the leftover `Secret/shop-tls`, `shop-vip-announce`, and
`shared-vip-pool` from both clusters, and restores `kind-l2-announce` **without** the exclusion
(an inline manifest — the on-disk pool files keep the exclusion for the next `apply.sh`). KEPT:
namespace `shop-edge` and the `gateway-access: shop-gw` label apply.sh added to it.

## Where phase 1 starts

Demo 41 deploys the shop platform in both clusters, attaches HTTPRoutes to these doors, and starts
measuring. The image `shopapi:local` is already on all four nodes; both clients are already built.
Do not rebuild during that demo (gotcha #118).
