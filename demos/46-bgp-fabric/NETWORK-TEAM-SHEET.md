# Network-team sheet — the company fabric (demo 46)

The point of R8: every value below exists before the first cluster
object. This file is the hand-off record for **both** LANs the fabric
can attach to. Enforcement is the leaves' `frr.conf` as recorded
(`show bgp peer-group SERVERS`, `show ip prefix-list`).

## Fabric (common to both LANs)

| # | The team decides | This fabric | How it is enforced |
|---|---|---|---|
| 1 | ASN plan (RFC 6996): one per router tier | edge **65000**, spine **65100**, leaf1 **65101**, leaf2 **65102** | `router bgp <asn>` |
| 2 | Who may dial (listen ranges) | `172.19.0.0/17` and `172.18.0.0/17` (recorded: 2 IPv4 listen range(s), 0 peers) | `bgp listen range … peer-group SERVERS`; `bgp listen limit 16` |
| 3 | Session security: one password per fabric, TTL | `FABRIC_BGP_PASSWORD` in [`fabric/.env`](fabric/.env) (default `lab-bgp`); fabric links MD5; SERVERS `ttl-security hops 1` | `neighbor … password ${FABRIC_BGP_PASSWORD}` rendered at start; `neighbor SERVERS ttl-security hops 1`; committed `frr.conf` has no secret |
| 4 | Prefixes a cluster may announce | `EG-VIPS` `10.98.0.0/24 le 32`; `CILIUM-VIPS` `10.99.0.0/24 le 32`; exact `/32`s | `ip prefix-list EG-VIPS seq 10 permit 10.98.0.0/24 le 32`; `ip prefix-list CILIUM-VIPS seq 10 permit 10.99.0.0/24 le 32`; `route-map SERVERS-IN permit 10/20` |
| 5 | What the servers may receive | nothing (Cilium does not import; kube-vip / MetalLB do not need fabric routes) | `route-map NOTHING deny 10`; `neighbor SERVERS route-map NOTHING out` |
| 6 | Backstops | `maximum-prefix 64` on SERVERS; `maximum-prefix 256` on fabric links | session torn down — prefix-lists first |
| 7 | Timers | hold 9 / keepalive 3 on every fabric and SERVERS session | `neighbor … timers 3 9` |
| 9 | What the fabric originates | edge: `10.200.100.0/24`; every router: its `/32` loopback; company supernet `10.200.0.0/16` | `network` statements; `ip prefix-list COMPANY seq 10 permit 10.200.0.0/16 le 32` |

Loopbacks: edge `10.200.255.1`, spine `.2`, leaf1 `.11`, leaf2 `.12`.

## Envoy Gateway lab (`kind-eg`)

Used by demos 56 and 57. Overlay:
[`fabric/compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml).

| # | The team decides | This lab | How it is enforced |
|---|---|---|---|
| 1 | Cluster ASNs | eg-poc1 **65021**, eg-poc2 **65022** | `neighbor SERVERS remote-as external` |
| 2 | Peering addresses | leaf1 `172.19.254.11`, leaf2 `172.19.254.12`; servers from `172.19.0.0/17` | `bgp listen range 172.19.0.0/17 peer-group SERVERS` (one of the two recorded ranges) |
| 4 | Prefixes each cluster may announce | eg-poc1 `10.98.0.0/26`, eg-poc2 `10.98.0.64/26`, reserved `.128/26`, anycast `.192/26`; exact `/32`s | `ip prefix-list EG-VIPS seq 10 permit 10.98.0.0/24 le 32`; `route-map SERVERS-IN permit 10` matches it |
| 8 | Route back to the servers' networks | `kind-eg` `172.19.0.0/16` is connected on both leaves when the overlay is applied | connected routes only |
| 10 | Hand-off record | this file; password in `fabric/.env` | — |

## Cilium lab (`kind`)

Used by demos 47–49. Overlay:
[`fabric/compose.lan-cilium.yaml`](fabric/compose.lan-cilium.yaml).
Written, not exercised (poc1/poc2 are paused).

| # | The team decides | This lab | How it is enforced |
|---|---|---|---|
| 1 | Cluster ASNs | poc1 **65001**, poc2 **65002** | `neighbor SERVERS remote-as external` |
| 2 | Peering addresses | leaf1 `172.18.254.11`, leaf2 `172.18.254.12`; servers from `172.18.0.0/17` | `bgp listen range 172.18.0.0/17 peer-group SERVERS` (one of the two recorded ranges) |
| 4 | Prefixes each cluster may announce | poc1 `10.99.0.0/26`, poc2 `10.99.0.64/26`, reserved `.128/26`, anycast `.192/26`; exact `/32`s | `ip prefix-list CILIUM-VIPS seq 10 permit 10.99.0.0/24 le 32`; `route-map SERVERS-IN permit 20` matches it |
| 8 | Route back to the servers' networks | `kind` `172.18.0.0/16` is connected on both leaves when the overlay is applied | connected routes only |
| 10 | Hand-off record | this file; password in `fabric/.env` | — |

Rows 1–3 are *who may talk to whom*, 4–6 are *what they may say*, 7 is
*how fast we notice when they stop*, 8–9 are *how packets get back*.
None of it is Kubernetes.
