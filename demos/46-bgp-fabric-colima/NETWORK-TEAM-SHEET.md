# Network-team sheet — the company fabric (demo 46-colima)

The point of R8: every value below exists before the first cluster
object. This file is the hand-off record for the fabric running on
the Colima Ubuntu VM. Enforcement is the leaves' `frr.conf` as
recorded (`show bgp peer-group SERVERS`, `show ip prefix-list`)
**and** TCP MD5 on the wire (this kernel has
`CONFIG_TCP_MD5SIG=y`). Both kind clusters have since dialled in
against these values unchanged — apply `2026-09-25T00:01:03Z`,
`routers=4/4 fabric=6/6 server=8/8 external=4` — which is what R8
was for: the fabric was specified before any cluster object existed,
and the clusters had to meet it.

## Fabric (common)

| # | The team decides | This fabric | How it is enforced |
|---|---|---|---|
| 1 | ASN plan (RFC 6996): one per router tier | edge **65000**, spine **65100**, leaf1 **65101**, leaf2 **65102** | `router bgp <asn>` |
| 2 | Who may dial (listen ranges) | `172.20.0.0/17` only (the Desktop Cilium lab's `172.18.0.0/17` is not here — that lab does not exist on this VM) | `bgp listen range … peer-group SERVERS`; `bgp listen limit 16` |
| 3 | Session security: one password per fabric, TTL | `FABRIC_BGP_PASSWORD` in [`fabric/.env`](fabric/.env) (copy [`.env.example`](fabric/.env.example); default `lab-bgp`) on every session; TTL 1 (same segment), **no GTSM** on SERVERS — kube-vip (gobgp) and FRR-K8s send TTL 1 and cannot pass `ttl-security` | `neighbor … password ${FABRIC_BGP_PASSWORD}` rendered at start; committed `frr.conf` has no secret. **This VM signs the sessions.** Apply `2026-09-25T00:01:03Z`: kernel `6.8.0-117-generic`, `CONFIG_TCP_MD5SIG=y`; each captured segment of the leaf1–spine session carried a TCP-MD5 option; check counted `md5-option packets=10/10 on 10.200.1.3`; wrong password on leaf1 neighbor `10.200.1.3`: `Established→Idle, down in 15/15 samples; restored Established`; while healthy `TcpExtTCPMD5{NotFound,Unexpected,Failure}` all 0. An unsigned session also shows zero kernel failures — the proof is the wire count **and** the mismatch. check.sh rows 12–14 record it |
| 4 | Prefixes a cluster may announce | exact `/32`s in the per-cluster `/26`s | enforced by prefix-list + as-path per cluster: `EG-POC1-VIPS` `10.198.0.0/26 ge 32 le 32` + `^65021$`; `EG-POC2-VIPS` `10.198.0.64/26` + `^65022$`; `EG-ANYCAST-VIPS` `10.198.0.192/26` from either; the same for reserved `CILIUM-*` `10.199.x` / `65001` / `65002`. Aggregates `EG-VIPS` / `CILIUM-VIPS` (`/24 ge 32 le 32`) are LEAF-OUT / FABRIC-IN only |
| 5 | What the servers may receive | nothing (Cilium does not import; kube-vip / MetalLB do not need fabric routes) | `route-map NOTHING deny 10`; `neighbor SERVERS route-map NOTHING out` |
| 6 | Backstops | `maximum-prefix 64` on SERVERS; `maximum-prefix 256` on fabric links | session torn down — prefix-lists first |
| 7 | Timers | hold 9 / keepalive 3 on every fabric and SERVERS session | `neighbor … timers 3 9` |
| 9 | What the fabric originates | edge: `10.200.100.0/24`; every router: its `/32` loopback; company supernet `10.200.0.0/16` | `network` statements; `ip prefix-list COMPANY seq 10 permit 10.200.0.0/16 le 32` |
| 11 | Out-of-band management LAN | `10.200.200.0/24` — edge `.1`, spine `.2`, leaf1 `.11`, leaf2 `.12`, dashboard `.100`, the Docker bridge `.254`; **not in BGP** | compose `mgmt`; no `network 10.200.200` and no `redistribute` in any `frr.conf`; the NMS (dashboard) reaches the show-only agent on these addresses |

Loopbacks: edge `10.200.255.1`, spine `.2`, leaf1 `.11`, leaf2 `.12`.

WAN hosts: client0 `10.200.100.10` (default via edge `.2`). The
dashboard sits on the management LAN at `10.200.200.100` (published
`127.0.0.1:8098`; the routers publish no port — the agent is
reached over mgmt, not through the traffic they route).

## Envoy Gateway lab (`eg-poc1-colima`, `eg-poc2-colima`) — attached

Both clusters run inside the Colima VM and dial the leaves from the
node LAN, against the listen range and prefix-lists that were already
there. Recorded at apply `2026-09-25T00:01:03Z`: four nodes peering —
`172.20.0.3` and `172.20.0.4` (`eg-poc1-colima-control-plane` and
`-worker`, AS `65021`), `172.20.0.5` and `172.20.0.6`
(`eg-poc2-colima-worker` and `-control-plane`, AS `65022`) — which is
eight SERVERS sessions across the two leaves, `server=8/8`. The
Docker Desktop fabric is demo 55's, not this VM's.

| # | The team decides | This lab | How it is enforced |
|---|---|---|---|
| 1 | Cluster ASNs | eg-poc1 **65021**, eg-poc2 **65022** | enforced by prefix-list + as-path per cluster (`EG-POC1` `^65021$`, `EG-POC2` `^65022$`) |
| 2 | Peering addresses | leaf1 `172.20.254.11`, leaf2 `172.20.254.12`; servers from `172.20.0.0/17` | `bgp listen range 172.20.0.0/17 peer-group SERVERS` |
| 3 | Session security: one password per fabric, TTL | the same `FABRIC_BGP_PASSWORD` (`lab-bgp`); this VM's kernel accepts `TCP_MD5SIG`, so a speaker that signs will Establish and a speaker that does not will not; TTL 1 (no GTSM) | `neighbor SERVERS password ${FABRIC_BGP_PASSWORD}`; no GTSM on SERVERS |
| 4 | Prefixes each cluster may announce | eg-poc1 `10.198.0.0/26`, eg-poc2 `10.198.0.64/26`, reserved `.128/26`, anycast `.192/26`; exact `/32`s | enforced by prefix-list + as-path per cluster: `EG-POC1-VIPS` + `EG-POC1`; `EG-POC2-VIPS` + `EG-POC2`; `EG-ANYCAST-VIPS` from either |
| 8 | Route back to the servers' networks | `kind-eg-colima` `172.20.0.0/16` is connected on both leaves; the overlay is applied | connected routes only. The reverse path is the node's own: `eg-poc1-colima`'s two nodes carry `ip route replace 10.200.0.0/16 via 172.20.254.11` because Docker does not forward between two bridges, so a reply to `client0` dies without it |
| 10 | Hand-off record | this file; password in `fabric/.env` (from `.env.example`) | — |

## Cilium lab — reserved, not attached

No Cilium cluster runs on Colima. The `CILIUM-*` prefix-lists stay on
the leaves at `10.199.0.0/24` (same `/26` layout as Desktop's
`10.99.0.0/24`) so a later speaker would have a block that cannot
collide with Desktop. There is no `bgp listen range` for Desktop's
`172.18.0.0/17`.

| # | The team decides | This lab | How it is enforced |
|---|---|---|---|
| 1 | Cluster ASNs | poc1 **65001**, poc2 **65002** | enforced by prefix-list + as-path per cluster (`CILIUM-POC1` `^65001$`, `CILIUM-POC2` `^65002$`) |
| 2 | Peering addresses | not listened; Desktop's `172.18.0.0/17` is the Cilium lab, which does not exist here | no second `bgp listen range` |
| 4 | Prefixes each cluster may announce | reserved: poc1 `10.199.0.0/26`, poc2 `10.199.0.64/26`, reserved `.128/26`, anycast `.192/26`; exact `/32`s | prefix-list + as-path per cluster: `CILIUM-POC1-VIPS` + `CILIUM-POC1`; `CILIUM-POC2-VIPS` + `CILIUM-POC2`; `CILIUM-ANYCAST-VIPS` from either |
| 8 | Route back to the servers' networks | no Cilium LAN on this VM | — |
| 10 | Hand-off record | this file; password in `fabric/.env` (from `.env.example`) | — |

Rows 1–3 are *who may talk to whom*, 4–6 are *what they may say*,
7 is *how fast we notice when they stop*, 8–9 are *how packets get
back*. None of it is Kubernetes.
