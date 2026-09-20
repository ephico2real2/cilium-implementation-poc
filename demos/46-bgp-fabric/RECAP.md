# Demo 46 — a four-router company fabric in docker compose

This page brings up four FRR routers — an edge, a spine, and two leaves —
on their own docker bridges, with an outside-world client behind the
edge. The leaves join the Envoy lab's node LAN (`kind-eg`) by a compose
overlay. No cluster peers yet. The six fabric sessions come up
Established at the first poll; `client0` reaches every loopback through
the fabric.

## What you get

- Four FRR 10.5.3 routers in project `bgp-fabric`: edge AS 65000, spine
  AS 65100, leaf1 AS 65101, leaf2 AS 65102.
- Six fabric eBGP sessions `"state":"Established"` at the first poll
  (`peerUptime` `00:00:03`).
- Loopbacks `10.200.255.1`, `.2`, `.11`, `.12` reachable from `client0`
  (`ttl=62`, 0% loss).
- Traceroute `10.200.100.2 → 10.200.1.18 → 10.200.255.11`.
- leaf1 ping `172.19.0.3` on-link (0% loss); leaves at
  `172.19.254.11` / `.12`.
- SERVERS peer-group: 2 listen ranges (`172.19.0.0/17`,
  `172.18.0.0/17`), 0 peers; prefix-lists `EG-VIPS` `10.98.0.0/24 le 32`
  and `CILIUM-VIPS` `10.99.0.0/24 le 32`.
- `check.sh` at `2026-09-20T03:38:19Z`: 12 PASS, 0 FAIL.

## Architecture

A packet from the Mac to a routed VIP (demos 56 / 57) takes this path.
Solid lines are docker bridges; dashed lines are the next demos'
attachment (no cluster peers in this demo):

```text
 MacBook
 curl / grpcurl / browser
 route 10.98.0.0/24 → 192.168.64.2     (optional, D18)
        |
        v
 Docker VM 192.168.64.2
 VM route 10.98.0.0/24 via leaf1 172.19.254.11
        |
        |                      company fabric (demo 46)
        |   client0 10.200.100.10
        |      |  wan 10.200.100.0/24
        |      v
        |   edge  AS 65000   lo 10.200.255.1
        |      |  10.200.1.16/29  (edge .19 · spine .18)
        |      v
        |   spine AS 65100   lo 10.200.255.2
        |     / \  10.200.1.0/29            10.200.1.8/29
        |    /   \ (leaf1 .2 · spine .3)   (leaf2 .10 · spine .11)
        |   v     v
        | leaf1 AS 65101                leaf2 AS 65102
        | lo 10.200.255.11              lo 10.200.255.12
        | kind-eg 172.19.254.11         kind-eg 172.19.254.12
        |        \                     /
        |         \   kind-eg 172.19.0.0/16
        |          v                   v
        |   - - - - - - NEXT - - - - - - - - - -
        |   eg-poc1 AS 65021            eg-poc2 AS 65022
        |   kube-vip BGP (demo 56)      MetalLB FRR-K8s (demo 57)
        |   172.19.0.2 / .3             172.19.0.4 / .5
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| client0 | `10.200.100.10` | outside world, default via `10.200.100.2` | netshoot v0.16 |
| edge | lo `10.200.255.1`, wan `10.200.100.2`, link `10.200.1.19` | border, originates `10.200.100.0/24` | FRR AS 65000 |
| spine | lo `10.200.255.2`, links `10.200.1.3` / `.11` / `.18` | transit, `multipath-relax`, `maximum-paths 8` | FRR AS 65100 |
| leaf1 | lo `10.200.255.11`, link `10.200.1.2`, kind-eg `172.19.254.11` | ToR, SERVERS listen | FRR AS 65101 |
| leaf2 | lo `10.200.255.12`, link `10.200.1.10`, kind-eg `172.19.254.12` | ToR, SERVERS listen | FRR AS 65102 |

Loopbacks are `/32`s on `lo`, programmed by zebra from `interface lo`
in each `frr.conf`. The leaves' second leg is the overlay
([`compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml)). Address plan:
[enhancement 006 §3.1 / §9.1](../../enhancements/006-bgp-tutorial.md).

## Prerequisites

- Docker Engine 29.8.0 and Compose v5.5.1 (measured on this lab).
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  `FRR_IMAGE=quay.io/frrouting/frr:10.5.3` (D16: the tag MetalLB's
  chart pins), `NETSHOOT_IMAGE=nicolaka/netshoot:v0.16`.
- The `kind-eg` network already exists (`172.19.0.0/16`). The fabric
  does not create it.
- One password in [`fabric/.env`](fabric/.env):
  `FABRIC_BGP_PASSWORD=lab-bgp` (the committed `frr.conf` has no
  secret).

```bash
test -f scripts/bootstrap/versions-eg.env
docker network inspect kind-eg --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

## Steps

Do these in order from the repo root (apply.sh records steps 2–6 after
fabric-up):

### 1. Bring the fabric up

compose starts the four routers and `client0` with the Envoy overlay;
the up script then waits for the six fabric sessions.

```bash
scripts/fabric-up.sh eg
```

Result: four fabric networks Created; five containers Healthy; image
`quay.io/frrouting/frr:10.5.3` and `nicolaka/netshoot:v0.16`.

```text
 Container bgp-fabric-client0-1 Healthy
 Container bgp-fabric-spine-1 Healthy
 Container bgp-fabric-leaf1-1 Healthy
 Container bgp-fabric-edge-1 Healthy
 Container bgp-fabric-leaf2-1 Healthy
bgp-fabric-client0-1   nicolaka/netshoot:v0.16        "sh -c 'ip route rep…"   client0   8 seconds ago   Up 7 seconds (healthy)
bgp-fabric-edge-1      quay.io/frrouting/frr:10.5.3   "/sbin/tini -- /usr/…"   edge      8 seconds ago   Up 7 seconds (healthy)
```

### 2. Watch it converge

The up script polls `show bgp summary json` on all four routers. Every
fabric session is Established at the first recorded poll
(`2026-09-20T03:38:14Z`).

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf2 vtysh -c 'show bgp summary json'
```

Result: edge `10.200.1.18` AS 65100; spine `10.200.1.2` / `.10` / `.19`
(AS 65101 / 65102 / 65000); leaf1 `10.200.1.3`; leaf2 `10.200.1.11`;
each `"state":"Established"`, `peerUptime` `00:00:03`.

```text
  "routerId":"10.200.255.1",
  "as":65000,
    "10.200.1.18":{
      "remoteAs":65100,
      "peerUptime":"00:00:03",
      "state":"Established",
  "routerId":"10.200.255.2",
  "as":65100,
    "10.200.1.2":{
      "remoteAs":65101,
    "10.200.1.10":{
      "remoteAs":65102,
    "10.200.1.19":{
      "remoteAs":65000,
  "routerId":"10.200.255.11",
  "as":65101,
    "10.200.1.3":{
  "routerId":"10.200.255.12",
  "as":65102,
    "10.200.1.11":{
      "state":"Established",
```

### 3. Read the routes

`show ip bgp` is the BGP RIB (AS paths). `show ip route` on edge is
the FIB: loopbacks as `B>*` via spine.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'show ip bgp'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show ip bgp'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show ip route'
```

Result: spine holds `10.200.100.0/24` via `10.200.1.19` path `65000`;
edge holds `10.200.255.11/32` via `10.200.1.18` path `65100 65101`;
edge FIB `B>* 10.200.255.11/32 [20/0] via 10.200.1.18`.

```text
 *>  10.200.100.0/24  10.200.1.19              0             0 65000 i
 *>  10.200.255.11/32 10.200.1.2               0             0 65101 i
 *>  10.200.255.12/32 10.200.1.10              0             0 65102 i
 *>  10.200.255.11/32 10.200.1.18                            0 65100 65101 i
 *>  10.200.255.12/32 10.200.1.18                            0 65100 65102 i
B>* 10.200.255.11/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:03
Displayed 5 routes and 5 total paths
```

### 4. Walk the path from the outside world

From `client0` the path to leaf1's loopback is edge → spine → leaf1.
`client0`'s default is via the edge.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T client0 ping -c 3 -W 2 10.200.255.11
```

Result: hops `10.200.100.2`, `10.200.1.18`, `10.200.255.11`; ping 3/3,
0% loss, `ttl=62`; default `via 10.200.100.2`.

```text
 1  10.200.100.2  0.007 ms  0.002 ms  0.006 ms
 2  10.200.1.18  0.002 ms  0.000 ms  0.002 ms
 3  10.200.255.11  0.002 ms  0.001 ms  0.001 ms
3 packets transmitted, 3 received, 0% packet loss, time 2052ms
default via 10.200.100.2 dev eth0
```

### 5. Touch the node LAN

leaf1 is on-link to `kind-eg` at `172.19.254.11`. This ping does not
touch BGP.

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 ping -c 1 -W 2 172.19.0.3
```

Result: 1/1, 0% loss, `ttl=64`, `time=0.152 ms`.

```text
64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.152 ms
1 packets transmitted, 1 packets received, 0% packet loss
```

### 6. Read the servers' policy

The listen ranges, prefix-lists and route-maps are the network team's
sheet, enforced on the leaf
([NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md)).

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip prefix-list'
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show route-map'
```

Result: SERVERS remote AS 0, external, 2 IPv4 listen ranges, no
members; `EG-VIPS` `10.98.0.0/24 le 32`; `CILIUM-VIPS`
`10.99.0.0/24 le 32`; `COMPANY` `10.200.0.0/16 le 32`; `SERVERS-IN`
matches the VIP lists; `NOTHING` deny 10.

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
BGP: ip prefix-list EG-VIPS: 1 entries
   seq 10 permit 10.98.0.0/24 le 32
BGP: ip prefix-list CILIUM-VIPS: 1 entries
   seq 10 permit 10.99.0.0/24 le 32
route-map: SERVERS-IN Invoked: 0 (0 milliseconds total) Optimization: enabled Processed Change: false
route-map: NOTHING Invoked: 0 (0 milliseconds total) Optimization: enabled Processed Change: false
```

## Verify

```bash
scripts/fabric-status.sh
```

Expect every fabric session Established (the recorded JSON
`"state":"Established"` on all six neighbors).

```bash
docker compose -p bgp-fabric \
  -f demos/46-bgp-fabric/fabric/compose.yaml \
  -f demos/46-bgp-fabric/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
```

Expect hops `10.200.100.2`, `10.200.1.18`, `10.200.255.11`.

```bash
demos/46-bgp-fabric/check.sh
```

Recorded `2026-09-20T03:38:19Z`:

```text
== demo 46 — the BGP fabric (four FRR routers, Envoy overlay)
  STATUS WHAT                                                                   MEASURED                                             RULE
  PASS   four routers running                                                   running=4/4                                          R1 — edge spine leaf1 leaf2 running
  PASS   six fabric sessions Established                                        6/6 Established                                      R1 — leaf1–spine, leaf2–spine, spine–edge, both directions
  PASS   client0 ping 10.200.255.1                                              rc=0                                                 R1 — loopback reachable from client0
  PASS   client0 ping 10.200.255.2                                              rc=0                                                 R1 — loopback reachable from client0
  PASS   client0 ping 10.200.255.11                                             rc=0                                                 R1 — loopback reachable from client0
  PASS   client0 ping 10.200.255.12                                             rc=0                                                 R1 — loopback reachable from client0
  PASS   10.200.100.0/24 in leaf1 via spine                                     via 10.200.1.3                                       R1 — wan learned via 10.200.1.3
  PASS   ECMP maximum-paths on spine                                            maximum-paths 8                                      R5 — maximum-paths 8
  PASS   SERVERS listen 172.19.0.0/17 on both leaves                            leaf1+leaf2                                          D5 / §9.1 — listen range on the peer-group
  PASS   prefix-list EG-VIPS present                                            10.98.0.0/24                                         R8 — EG-VIPS permit 10.98.0.0/24 le 32
  PASS   leaves on kind-eg 172.19.254.11/.12                                    leaf1=172.19.254.11 leaf2=172.19.254.12              §9.1 — 172.19.254.11/.12
  PASS   RFC 8212 in effect                                                     no ebgp-requires-policy disabled                     §8 row 5 — traditional defaults, explicit route-maps
demo 46 check: 0 FAIL
```

## Reference

Pins
([`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env)):
`quay.io/frrouting/frr:10.5.3` (D16, the tag MetalLB's chart pins),
`nicolaka/netshoot:v0.16`. Password: `fabric/.env` →
`FABRIC_BGP_PASSWORD` (default `lab-bgp`);
[`fabric/entrypoint.sh`](fabric/entrypoint.sh) replaces
`${FABRIC_BGP_PASSWORD}` in the mounted `frr.conf.tmpl` and execs
`/usr/lib/frr/docker-start`.

| Item | Value |
|---|---|
| Project | `bgp-fabric` |
| Company supernet | `10.200.0.0/16` |
| Loopbacks | edge `10.200.255.1`, spine `.2`, leaf1 `.11`, leaf2 `.12` |
| Links (`/29`) | leaf1–spine `10.200.1.0/29` (`.2` / `.3`); leaf2–spine `10.200.1.8/29` (`.10` / `.11`); spine–edge `10.200.1.16/29` (`.18` / `.19`) |
| wan | `10.200.100.0/24`: edge `.2`, client0 `.10` |
| ASNs | edge 65000, spine 65100, leaf1 65101, leaf2 65102 |
| `kind-eg` (this apply) | `172.19.0.0/16`; leaves `172.19.254.11` / `.12`; listen `172.19.0.0/17`; VIP `10.98.0.0/24`; cluster ASNs 65021 / 65022 |
| `kind` (written, not exercised) | `172.18.0.0/16`; leaves `172.18.254.11` / `.12`; listen `172.18.0.0/17`; VIP `10.99.0.0/24`; cluster ASNs 65001 / 65002 |
| SERVERS | listen both `/17`s; `maximum-prefix 64`; `timers 3 9`; `ttl-security hops 1`; `listen limit 16` |
| Fabric sessions | `maximum-prefix 256`; `timers 3 9` |
| EG-VIPS | `10.98.0.0/24 le 32` |
| CILIUM-VIPS | `10.99.0.0/24 le 32` |
| COMPANY | `10.200.0.0/16 le 32` |

| File | What |
|---|---|
| [`fabric/compose.yaml`](fabric/compose.yaml) | four routers + client0 on their own bridges |
| [`fabric/compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml) | leaves on `kind-eg` at `.254.11` / `.12` |
| [`fabric/compose.lan-cilium.yaml`](fabric/compose.lan-cilium.yaml) | leaves on `kind` at `.254.11` / `.12` |
| [`fabric/frr/<router>/`](fabric/frr/) | `frr.conf`, `daemons`, `vtysh.conf` |
| [`fabric/entrypoint.sh`](fabric/entrypoint.sh) | renders the password, then `docker-start` |
| [`fabric/.env`](fabric/.env) | `FABRIC_BGP_PASSWORD=lab-bgp` |
| [`../../scripts/fabric-up.sh`](../../scripts/fabric-up.sh) | compose up + convergence |
| [`../../scripts/fabric-down.sh`](../../scripts/fabric-down.sh) | compose down; never removes `kind` / `kind-eg` |
| [`../../scripts/fabric-status.sh`](../../scripts/fabric-status.sh) | four summaries + topology (D17 phase 1) |
| [`../../scripts/fabric-vm-route.sh`](../../scripts/fabric-vm-route.sh) | prints the two Mac-path lines; `--apply` is VM only |
| [`../../scripts/fabric-bgp-summary.py`](../../scripts/fabric-bgp-summary.py) | exact `state` == `Established` |
| [`NETWORK-TEAM-SHEET.md`](NETWORK-TEAM-SHEET.md) | §8 filled for both LANs |

## Troubleshooting

- A fabric session stuck Active: password mismatch or GTSM
  (`ttl-security hops 1` on SERVERS). `show bgp neighbors` prints the
  last reset reason and whether a password / TTL security is
  configured.
- compose with the `eg` overlay fails: `kind-eg` is declared
  `external: true` and does not exist — Docker refuses the overlay.
  Create the LAN with the Envoy lab's net script, or bring the fabric
  up without an overlay.
- The Mac cannot reach `10.98.0.0/24`: the VM route is missing (D18).
  Print the two lines; `--apply` installs only the VM route:

```bash
scripts/fabric-vm-route.sh
scripts/fabric-vm-route.sh --apply
```

## Clean up

```bash
demos/46-bgp-fabric/cleanup.sh
```

cleanup.sh calls `scripts/fabric-down.sh`. The fabric's own networks
go; `kind` and `kind-eg` stay.

## What's next

- Demo 56 attaches `eg-poc1` (kube-vip in BGP mode) to this fabric.
- Demo 57 attaches `eg-poc2` (MetalLB FRR-K8s BGP) to this fabric.
- The dashboard (D17 phase 2) reads the routers over the fabric.
- Demos 47–49 attach the Cilium clusters (poc1/poc2 are paused today).
