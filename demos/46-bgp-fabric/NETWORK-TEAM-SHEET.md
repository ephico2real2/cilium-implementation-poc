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
| 3 | Session security: one password per fabric, TTL | `FABRIC_BGP_PASSWORD` in [`fabric/.env`](fabric/.env) (copy [`.env.example`](fabric/.env.example); default `lab-bgp`) on every session; TTL 1 (same segment), **no GTSM** on SERVERS — kube-vip (gobgp) and FRR-K8s send TTL 1 and cannot pass `ttl-security` | `neighbor … password ${FABRIC_BGP_PASSWORD}` rendered at start; committed `frr.conf` has no secret. **This host's kernel refuses `TCP_MD5SIG`** (`Unable to set TCP MD5 option … Protocol not available`): MD5 configured; on this Docker VM the kernel refuses TCP_MD5SIG — measured — so the lab's sessions are unauthenticated; a real fabric enforces it. check.sh row 13 records it |
| 4 | Prefixes a cluster may announce | exact `/32`s in the per-cluster `/26`s | enforced by prefix-list + as-path per cluster: `EG-POC1-VIPS` `10.98.0.0/26 ge 32 le 32` + `^65021$`; `EG-POC2-VIPS` `10.98.0.64/26` + `^65022$`; `EG-ANYCAST-VIPS` `10.98.0.192/26` from either; the same for `CILIUM-*` / `65001` / `65002`. Aggregates `EG-VIPS` / `CILIUM-VIPS` (`/24 ge 32 le 32`) are LEAF-OUT / FABRIC-IN only |
| 5 | What the servers may receive | nothing (Cilium does not import; kube-vip / MetalLB do not need fabric routes) | `route-map NOTHING deny 10`; `neighbor SERVERS route-map NOTHING out` |
| 6 | Backstops | `maximum-prefix 64` on SERVERS; `maximum-prefix 256` on fabric links | session torn down — prefix-lists first |
| 7 | Timers | hold 9 / keepalive 3 on every fabric and SERVERS session | `neighbor … timers 3 9` |
| 9 | What the fabric originates | edge: `10.200.100.0/24`; every router: its `/32` loopback; company supernet `10.200.0.0/16` | `network` statements; `ip prefix-list COMPANY seq 10 permit 10.200.0.0/16 le 32` |
| 11 | Out-of-band management LAN | `10.200.200.0/24` — edge `.1`, spine `.2`, leaf1 `.11`, leaf2 `.12`, dashboard `.100`, the Docker bridge `.254`; **not in BGP** | compose `mgmt`; no `network 10.200.200` and no `redistribute` in any `frr.conf`; the NMS (dashboard) reaches the show-only agent on these addresses |

Loopbacks: edge `10.200.255.1`, spine `.2`, leaf1 `.11`, leaf2 `.12`.

WAN hosts: client0 `10.200.100.10` (default via edge `.2`). The dashboard
sits on the management LAN at `10.200.200.100` (published
`127.0.0.1:8088`; the routers publish no port — the agent is reached over
mgmt, not through the traffic they route).

## Envoy Gateway lab (`kind-eg`)

Used by demos 56 and 57. Overlay:
[`fabric/compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml).

| # | The team decides | This lab | How it is enforced |
|---|---|---|---|
| 1 | Cluster ASNs | eg-poc1 **65021**, eg-poc2 **65022** | enforced by prefix-list + as-path per cluster (`EG-POC1` `^65021$`, `EG-POC2` `^65022$`) |
| 2 | Peering addresses | leaf1 `172.19.254.11`, leaf2 `172.19.254.12`; servers from `172.19.0.0/17` | `bgp listen range 172.19.0.0/17 peer-group SERVERS` (one of the two recorded ranges) |
| 3 | Session security: one password per fabric, TTL | the same `FABRIC_BGP_PASSWORD` (`lab-bgp`); kube-vip on eg-poc1 sends **no password** (`bgp_peers=172.19.254.11:65101::false,172.19.254.12:65102::false`): gobgp sets `TCP_MD5SIG` on its connecting socket and this VM's kernel refuses it, so a password keeps the session in ACTIVE forever (measured 2026-09-20, demo 56 run 2: est=0 after 90 s; without it, Established after 3 s in every later run) — on a real kernel the speaker signs; TTL 1 (gobgp `ttl = 1` for eBGP, no GTSM) | `neighbor SERVERS password ${FABRIC_BGP_PASSWORD}`; no GTSM on SERVERS; demo 56 header on `10a`/`10b` |
| 4 | Prefixes each cluster may announce | eg-poc1 `10.98.0.0/26` (demo 56 doors `.10` / `.11`), eg-poc2 `10.98.0.64/26`, reserved `.128/26`, anycast `.192/26`; exact `/32`s | enforced by prefix-list + as-path per cluster: `EG-POC1-VIPS` + `EG-POC1`; `EG-POC2-VIPS` + `EG-POC2`; `EG-ANYCAST-VIPS` from either |
| 8 | Route back to the servers' networks | `kind-eg` `172.19.0.0/16` is connected on both leaves when the overlay is applied | connected routes only |
| 10 | Hand-off record | this file; password in `fabric/.env` (from `.env.example`) | — |

## Cilium lab (`kind`)

Used by demos 47–49. Overlay:
[`fabric/compose.lan-cilium.yaml`](fabric/compose.lan-cilium.yaml).
Written, not exercised (the Cilium clusters are paused).

| # | The team decides | This lab | How it is enforced |
|---|---|---|---|
| 1 | Cluster ASNs | poc1 **65001**, poc2 **65002** | enforced by prefix-list + as-path per cluster (`CILIUM-POC1` `^65001$`, `CILIUM-POC2` `^65002$`) |
| 2 | Peering addresses | leaf1 `172.18.254.11`, leaf2 `172.18.254.12`; servers from `172.18.0.0/17` | `bgp listen range 172.18.0.0/17 peer-group SERVERS` (one of the two recorded ranges) |
| 4 | Prefixes each cluster may announce | poc1 `10.99.0.0/26`, poc2 `10.99.0.64/26`, reserved `.128/26`, anycast `.192/26`; exact `/32`s | enforced by prefix-list + as-path per cluster: `CILIUM-POC1-VIPS` + `CILIUM-POC1`; `CILIUM-POC2-VIPS` + `CILIUM-POC2`; `CILIUM-ANYCAST-VIPS` from either |
| 8 | Route back to the servers' networks | `kind` `172.18.0.0/16` is connected on both leaves when the overlay is applied | connected routes only |
| 10 | Hand-off record | this file; password in `fabric/.env` (from `.env.example`) | — |

Rows 1–3 are *who may talk to whom*, 4–6 are *what they may say*, 7 is
*how fast we notice when they stop*, 8–9 are *how packets get back*.
None of it is Kubernetes.
