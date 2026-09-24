# Demo 55 — a four-router company fabric in docker compose

This page brings up four FRR routers — an edge, a spine, and two leaves
— on their own docker bridges, with an outside-world client behind the
edge. The leaves join the Envoy lab's node LAN (`kind-eg`) by a compose
overlay. `bgp-dashboard` draws the live topology from a show-only agent
on each router — a clean-room take on
[Make BGP visible: a live topology dashboard with Containerlab](https://gergovadasz.hu/make-bgp-visible-a-live-topology-dashboard-with-containerlab/).

## What you get

- Apply `2026-09-20T19:29:04Z`. Four FRR routers in project
  `bgp-fabric` running `frr-agent:local` (built on
  `quay.io/frrouting/frr:10.7.1`): edge AS 65000, spine AS 65100,
  leaf1 AS 65101, leaf2 AS 65102.
- Six fabric eBGP sessions `"state":"Established"` at the first poll
  (`peerUptime` `00:00:06` on the edge); `converged after 0 s (1
  polls)`.
- Loopbacks `10.200.255.1`, `.2`, `.11`, `.12` reachable from `client0`
  (`ttl=62`, 0% loss); traceroute `10.200.100.2 → 10.200.1.18 →
  10.200.255.11`.
- Management LAN `10.200.200.0/24` (edge `.1`, spine `.2`, leaf1 `.11`,
  leaf2 `.12`, dashboard `.100`, Docker bridge `.254`); not in BGP.
- Dashboard `dashboard ready after 0 s (routers=4/4 sessions=6/6
  external=2)`; `dashboard showed the drop after 1.49 s`; `dashboard
  confirmed recovery after 0.67 s (polled after the screenshots)`;
  `spine recovery: first Idle 2026-09-20T19:29:23.904Z last
  Established 2026-09-20T19:29:25.906Z recovered=yes window=2.002 s`.
- `check.sh` at `2026-09-20T19:29:40Z`: 16 rows, 15 PASS, 1 WARN, 0
  FAIL. Row 16: `client0_rc=28,28,28,28`.

## Architecture

A packet from the Mac to a routed VIP (demos 56 / 57) takes this
path. The `mgmt` LAN is out of band (not in BGP). This apply already
sees demo 56's kube-vip nodes as external (`172.19.0.2` / `.3`, AS
65021):

```text
 MacBook
 curl / grpcurl / browser 127.0.0.1:8088
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
        |   edge  AS 65000   lo 10.200.255.1   mgmt .1
        |      |  10.200.1.16/29  (edge .19 · spine .18)
        |      v
        |   spine AS 65100   lo 10.200.255.2   mgmt .2
        |     / \  10.200.1.0/29            10.200.1.8/29
        |    /   \ (leaf1 .2 · spine .3)   (leaf2 .10 · spine .11)
        |   v     v
        | leaf1 AS 65101                leaf2 AS 65102
        | lo 10.200.255.11  mgmt .11    lo 10.200.255.12  mgmt .12
        | kind-eg 172.19.254.11         kind-eg 172.19.254.12
        |        \                     /
        |         \   kind-eg 172.19.0.0/16
        |          v                   v
        |   eg-poc1 AS 65021            - - eg-poc2 AS 65022 - -
        |   kube-vip BGP (demo 56)      MetalLB FRR-K8s (demo 57)
        |   172.19.0.2 / .3             172.19.0.4 / .5
        |
        |   mgmt 10.200.200.0/24 (not in BGP; FORWARD + INPUT)
        |   dashboard .100  →  127.0.0.1:8088
        |   Docker bridge .254
```

| Name | Address | What it is | Who answers |
|---|---|---|---|
| client0 | `10.200.100.10` | outside world, default via `10.200.100.2` | netshoot v0.16 |
| edge | lo `10.200.255.1`, wan `10.200.100.2`, link `10.200.1.19` | border, originates `10.200.100.0/24` | FRR AS 65000 |
| spine | lo `10.200.255.2`, links `10.200.1.3` / `.11` / `.18` | transit, `multipath-relax`, `maximum-paths 8` | FRR AS 65100 |
| leaf1 | lo `10.200.255.11`, link `10.200.1.2`, kind-eg `172.19.254.11` | ToR, SERVERS listen, `maximum-paths 8` | FRR AS 65101 |
| leaf2 | lo `10.200.255.12`, link `10.200.1.10`, kind-eg `172.19.254.12` | ToR, SERVERS listen, `maximum-paths 8` | FRR AS 65102 |
| mgmt | `10.200.200.0/24` | out-of-band; not in BGP; FORWARD drops transit, INPUT drops the agent port except on mgmt and `lo` | Docker bridge `.254` |
| agents | edge `.1`, spine `.2`, leaf1 `.11`, leaf2 `.12` on `:8080` | allow-listed `show … json` | `frr-agent` |
| dashboard | `10.200.200.100`, published `127.0.0.1:8088` | live topology, Events, RIB | `bgp-dashboard:local` |

Overlay: [`compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml). Address
plan: [enhancement 006 §3.1 / §9.1](../../enhancements/006-bgp-tutorial.md).

## Prerequisites

- Docker and Compose. The up script builds `frr-agent:local` and
  `bgp-dashboard:local` if they are absent.
- Pins from
  [`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env):
  `FRR_IMAGE=quay.io/frrouting/frr:10.7.1`,
  `NETSHOOT_IMAGE=nicolaka/netshoot:v0.16`.
- The `kind-eg` network already exists (`172.19.0.0/16`). The fabric
  does not create it. One fabric per Docker host: the `/29` link
  subnets overlap with any second copy.
- One password: copy [`fabric/.env.example`](fabric/.env.example) to
  `.env` (default `lab-bgp`). This VM refuses `TCP_MD5SIG`.

```bash
test -f scripts/bootstrap/versions-eg.env
docker network inspect kind-eg --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

## Steps

Do these in order from the repo root:

### 1. Bring the fabric up

compose starts the four routers, `client0` and the dashboard; the up
script waits for the six fabric sessions.

```bash
scripts/fabric-up.sh eg
```

Result: `bgp-fabric_mgmt` Created; six containers Healthy;
`frr-agent:local`, `bgp-dashboard:local`, `nicolaka/netshoot:v0.16`.

```text
 Container bgp-fabric-client0-1 Healthy
 Container bgp-fabric-spine-1 Healthy
 Container bgp-fabric-edge-1 Healthy
 Container bgp-fabric-leaf2-1 Healthy
 Container bgp-fabric-dashboard-1 Healthy
bgp-fabric-client0-1     nicolaka/netshoot:v0.16   "sh -c 'ip route rep…"   client0     11 seconds ago   Up 11 seconds (healthy)
bgp-fabric-dashboard-1   bgp-dashboard:local       "/dashboard"             dashboard   11 seconds ago   Up 6 seconds (healthy)    127.0.0.1:8088->8080/tcp
bgp-fabric-edge-1        frr-agent:local           "/sbin/tini -- /usr/…"   edge        11 seconds ago   Up 10 seconds (healthy)
```

### 2. Watch it converge

Every fabric session is Established at the first poll
(`2026-09-20T19:29:15Z`).

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp summary json'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf2 vtysh -c 'show bgp summary json'
```

Result: `converged after 0 s (1 polls)`; each listed neighbor
`"state":"Established"`, edge `peerUptime` `00:00:06`.

```text
converged after 0 s (1 polls)
```

```text
  "routerId":"10.200.255.1",
  "as":65000,
    "10.200.1.18":{
      "remoteAs":65100,
      "peerUptime":"00:00:06",
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

`show ip bgp` is the RIB. `show ip route` on edge is the FIB.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'show ip bgp'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show ip bgp'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T edge vtysh -c 'show ip route'
```

Result: spine `10.200.100.0/24` via `10.200.1.19` path `65000`; edge
`B>* 10.200.255.11/32 [20/0] via 10.200.1.18, eth1`; `Displayed 7
routes and 9 total paths`.

```text
 *>  10.200.100.0/24  10.200.1.19              0             0 65000 i
 *>  10.200.255.11/32 10.200.1.2               0             0 65101 i
 *>  10.200.255.12/32 10.200.1.10              0             0 65102 i
 *>  10.98.0.10/32    10.200.1.18                            0 65100 65101 65021 i
 *>  10.200.255.11/32 10.200.1.18                            0 65100 65101 i
 *>  10.200.255.12/32 10.200.1.18                            0 65100 65102 i
B>* 10.200.255.11/32 [20/0] via 10.200.1.18, eth1, weight 1, 00:00:06
Displayed 7 routes and 9 total paths
```

### 4. Walk the path from the outside world

From `client0` the path to leaf1's loopback is edge → spine → leaf1.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T client0 ping -c 3 -W 2 10.200.255.11
```

Result: hops `10.200.100.2`, `10.200.1.18`, `10.200.255.11`; ping 3/3,
0% loss, `ttl=62`; default `via 10.200.100.2`.

```text
 1  10.200.100.2  0.009 ms  0.005 ms  0.003 ms
 2  10.200.1.18  0.002 ms  0.004 ms  0.004 ms
 3  10.200.255.11  0.001 ms  0.004 ms  0.002 ms
3 packets transmitted, 3 received, 0% packet loss, time 2064ms
default via 10.200.100.2 dev eth0
```

### 5. Touch the node LAN

leaf1 is on-link to `kind-eg` at `172.19.254.11`. This ping does not
touch BGP.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 ping -c 1 -W 2 172.19.0.3
```

Result: 1/1, 0% loss, `ttl=64`, `time=0.146 ms`.

```text
64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.146 ms
1 packets transmitted, 1 packets received, 0% packet loss
```

### 6. Read the servers' policy

The listen ranges, prefix-lists and route-maps are
[NETWORK-TEAM-SHEET.md](NETWORK-TEAM-SHEET.md).

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show ip prefix-list'
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T leaf1 vtysh -c 'show route-map'
```

Result: SERVERS 2 IPv4 listen ranges; members `172.19.0.2` / `.3`
(dynamic) Established; per-cluster lists `ge 32 le 32`;
`maximum-paths 8`.

```text
BGP peer-group SERVERS, remote AS 0
  Peer-group type is external
  2 IPv4 listen range(s)
    172.19.0.0/17
    172.18.0.0/17
  Peer-group members:
    172.19.0.2 (dynamic) Established
    172.19.0.3 (dynamic) Established
BGP: ip prefix-list EG-POC1-VIPS: 1 entries
   seq 10 permit 10.98.0.0/26 ge 32 le 32
BGP: ip prefix-list EG-POC2-VIPS: 1 entries
   seq 10 permit 10.98.0.64/26 ge 32 le 32
BGP: ip prefix-list EG-ANYCAST-VIPS: 1 entries
   seq 10 permit 10.98.0.192/26 ge 32 le 32
BGP: ip prefix-list EG-VIPS: 1 entries
   seq 10 permit 10.98.0.0/24 ge 32 le 32
BGP: ip prefix-list CILIUM-POC1-VIPS: 1 entries
   seq 10 permit 10.99.0.0/26 ge 32 le 32
    as-path EG-POC1
    as-path EG-POC2
route-map: SERVERS-IN Invoked: 12 (0 milliseconds total) Optimization: enabled Processed Change: false
route-map: NOTHING Invoked: 14 (0 milliseconds total) Optimization: enabled Processed Change: false
  PASS   ECMP maximum-paths on spine and leaves                                 maximum-paths 8                                      R5 — maximum-paths 8
```

### 7. Read the dashboard's state

The dashboard polls each agent on `mgmt` and exposes one snapshot.

```bash
curl -fsS --max-time 5 http://127.0.0.1:8088/api/state | python3 scripts/fabric-dashboard-state.py
```

Result: `routers=4/4 sessions=6/6 external=2`.

```text
routers=4/4 sessions=6/6 external=2
```

### 8. Open the dashboard

The page is at `http://127.0.0.1:8088/`.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --window-size=1200,700 \
  --user-data-dir=<tmp> --virtual-time-budget=4000 \
  --screenshot=demos/55-bgp-fabric-desktop/output/screenshots/dashboard-steady.png \
  http://127.0.0.1:8088/?router=spine
```

Result: header `routers 4/4`, `fabric sessions 6/6`, `server sessions
4/4`; `screenshot written after 2.0 s; chrome_rc=0`.

```text
screenshot written after 2.0 s; chrome_rc=0
demos/46-bgp-fabric/output/screenshots/dashboard-steady.png: PNG image data, 1200 x 700, 8-bit/color RGB, non-interlaced
```

![Steady: fabric sessions 6/6 · server sessions 4/4; spine RIB holds
the loopbacks, wan and the VIP /32s.](output/screenshots/dashboard-steady.png)

### 9. Clear the spine's sessions and watch them come back

`clear bgp *` on the spine drops the three fabric sessions; they
return on their own.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T spine vtysh -c 'clear bgp *'
```

Result: `event mark before clear: id=42`; `dashboard showed the drop
after 1.49 s` (the loop's notice); `dashboard confirmed recovery after
0.67 s (polled after the screenshots)`; `spine recovery: first Idle
2026-09-20T19:29:23.904Z last Established 2026-09-20T19:29:25.906Z
recovered=yes window=2.002 s`.

```text
event mark before clear: id=42
clear bgp * issued on spine
dashboard showed the drop after 1.49 s
dashboard confirmed recovery after 0.67 s (polled after the screenshots)
spine recovery: first Idle 2026-09-20T19:29:23.904Z last Established 2026-09-20T19:29:25.906Z recovered=yes window=2.002 s
```

![Clear: header `fabric sessions 0/6 · server sessions 4/4`; three
fabric links red; spine RIB is only `10.200.255.2/32`; kube-vip
sessions on the leaves stay Established.](output/screenshots/dashboard-clear-bgp.png)

![Recovered: header `fabric sessions 6/6 · server sessions 4/4`;
fabric links green; spine RIB restored.](output/screenshots/dashboard-recovered.png)

### 10. Confirm the agents stay on the management LAN

FORWARD drops transit onto `10.200.200.0/24`. INPUT accepts the
agent port on mgmt and `lo` and drops it everywhere else
([`fabric/entrypoint.sh`](fabric/entrypoint.sh)).

```bash
demos/55-bgp-fabric-desktop/check.sh
```

Result: row 16 `client0_rc=28,28,28,28` (timed out on
`10.200.200.1`, `.2`, `.11`, `.12`); `;reboot=404`; `summary=200`.

```text
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only
```

## Verify

```bash
scripts/fabric-status.sh
```

Expect six neighbors `"state":"Established"` and
`routers=4/4 sessions=6/6 external=2`.

```bash
curl -fsS --max-time 5 http://127.0.0.1:8088/api/state | python3 scripts/fabric-dashboard-state.py
```

Expect `routers=4/4 sessions=6/6 external=2`.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  exec -T client0 traceroute -n 10.200.255.11
```

Expect hops `10.200.100.2`, `10.200.1.18`, `10.200.255.11`.

```bash
demos/55-bgp-fabric-desktop/check.sh
```

Recorded at `2026-09-20T19:29:40Z`: 16 rows, 15 PASS, 1 WARN, 0 FAIL.

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
  PASS   ECMP maximum-paths on spine and leaves                                 maximum-paths 8                                      R5 — maximum-paths 8
  PASS   SERVERS listen both /17s on both leaves                                leaf1+leaf2                                          D5 / §9.1 — listen range on the peer-group
  PASS   per-cluster VIP prefix-lists                                           EG/CILIUM POC1/POC2/ANYCAST ge 32 le 32              R8 — prefix-list + as-path per cluster
  PASS   leaves on kind-eg 172.19.254.11/.12                                    leaf1=172.19.254.11 leaf2=172.19.254.12              §9.1 — 172.19.254.11/.12
  PASS   RFC 8212 in effect                                                     traditional profile, ebgp-requires-policy on         §8 row 5 — traditional defaults, explicit route-maps
  WARN   TCP MD5 in effect on the leaves                                        leaf1:TCP_MD5SIG-refused=9 leaf2:TCP_MD5SIG-refused=9  §8 row 3 — no CONFIG_TCP_MD5SIG here: sessions run unsigned
  PASS   dashboard reachable, 4/4 routers polled                                routers=4/4 sessions=6/6 external=2                  D8 — /api/state from 127.0.0.1:8088
  PASS   dashboard sessions agree with vtysh                                    6/6 = 6/6                                            D17 — state Established matches fabric-bgp-summary
  PASS   agent on mgmt only, show-only                                          no ports; ;reboot=404 summary=200; client0_rc=28,28,28,28 D8 — agent on 10.200.200.0/24, show-only
demo 46 check: 0 FAIL
```

## Reference

Pins
([`scripts/bootstrap/versions-eg.env`](../../scripts/bootstrap/versions-eg.env)):
`quay.io/frrouting/frr:10.7.1`, `nicolaka/netshoot:v0.16`. Password:
copy `fabric/.env.example` to `.env` (default `lab-bgp`). Dashboard
port: `FABRIC_DASHBOARD_PORT` (default 8088). The up script refuses to
start when another container publishes it and names the holder.

| Item | Value |
|---|---|
| Project | `bgp-fabric` |
| Company supernet | `10.200.0.0/16` |
| Loopbacks | edge `10.200.255.1`, spine `.2`, leaf1 `.11`, leaf2 `.12` |
| Links (`/29`) | leaf1–spine `10.200.1.0/29` (`.2` / `.3`); leaf2–spine `10.200.1.8/29` (`.10` / `.11`); spine–edge `10.200.1.16/29` (`.18` / `.19`) |
| wan | `10.200.100.0/24`: edge `.2`, client0 `.10` |
| mgmt | `10.200.200.0/24`: edge `10.200.200.1`, spine `10.200.200.2`, leaf1 `10.200.200.11`, leaf2 `10.200.200.12`, dashboard `10.200.200.100`, Docker bridge `10.200.200.254` |
| ASNs | edge 65000, spine 65100, leaf1 65101, leaf2 65102 |
| `kind-eg` (this apply) | `172.19.0.0/16`; leaves `172.19.254.11` / `.12`; listen `172.19.0.0/17`; VIP `10.98.0.0/24`; cluster ASNs 65021 / 65022 |
| `kind` (written, not exercised) | `172.18.0.0/16`; leaves `172.18.254.11` / `.12`; listen `172.18.0.0/17`; VIP `10.99.0.0/24`; cluster ASNs 65001 / 65002 |
| SERVERS | listen both `/17`s; `maximum-prefix 64`; `timers 3 9`; no GTSM (the speakers send TTL 1); `listen limit 16` |
| Fabric sessions | `maximum-prefix 256`; `timers 3 9` |
| EG-VIPS | `10.98.0.0/24 ge 32 le 32` (LEAF-OUT / FABRIC-IN) |
| CILIUM-VIPS | `10.99.0.0/24 ge 32 le 32` (LEAF-OUT / FABRIC-IN) |
| SERVERS-IN | prefix-list + as-path per cluster (exact `/32`s) |
| COMPANY | `10.200.0.0/16 le 32` |
| Isolation | FORWARD drops transit onto `10.200.200.0/24`. INPUT accepts the agent port on mgmt and `lo`, drops it everywhere else. Row 16: `client0_rc=28,28,28,28`. Live gate: [`tests/fabric-agent-mgmt-input.sh`](../../tests/fabric-agent-mgmt-input.sh). |

| Path | What |
|---|---|
| `/` | embedded UI (Cytoscape vendored, no CDN) |
| `/api/state` | latest snapshot |
| `/api/events?since=` | event ring |
| `/healthz` | 200 once every router has answered once |
| `/ws` | `event` / `state` on graph change (HTTP already painted the first frame) |

| Name | Command |
|---|---|
| `bgp-summary` | `show bgp summary json` |
| `bgp-ipv4` | `show bgp ipv4 unicast json` |
| `bgp-neighbors` | `show bgp neighbors json` |
| `ip-route` | `show ip route json` |
| `interface` | `show interface brief json` |

| File | What |
|---|---|
| [`fabric/compose.yaml`](fabric/compose.yaml) | four routers + client0 + dashboard; `mgmt` `10.200.200.0/24` |
| [`fabric/compose.lan-eg.yaml`](fabric/compose.lan-eg.yaml) | leaves on `kind-eg` at `.254.11` / `.12` |
| [`fabric/compose.lan-cilium.yaml`](fabric/compose.lan-cilium.yaml) | leaves on `kind` at `.254.11` / `.12` |
| [`fabric/frr/<router>/`](fabric/frr/) | `frr.conf`, `daemons`, `vtysh.conf` |
| [`fabric/entrypoint.sh`](fabric/entrypoint.sh) | renders the password, FORWARD drop on mgmt, INPUT accept on mgmt/`lo` and drop elsewhere, then `docker-start` |
| [`fabric/.env.example`](fabric/.env.example) | copy to `.env`; default `lab-bgp` |
| [`../../scripts/bgp-fabric.env`](../../scripts/bgp-fabric.env) | which bgp-fabric commit this lab builds against — the agent and the dashboard come from there |
| [`../../scripts/bgp-fabric-fetch.sh`](../../scripts/bgp-fabric-fetch.sh) | puts that commit on disk under `vendor/`; `BGP_FABRIC_DIR` overrides it |
| [`../../scripts/fabric-up.sh`](../../scripts/fabric-up.sh) | builds images if absent, compose up + convergence |
| [`../../scripts/fabric-down.sh`](../../scripts/fabric-down.sh) | compose down; never removes `kind` / `kind-eg` |
| [`../../scripts/fabric-status.sh`](../../scripts/fabric-status.sh) | four summaries + topology + dashboard one-liner |
| [`../../scripts/fabric-vm-route.sh`](../../scripts/fabric-vm-route.sh) | prints the two Mac-path lines; `--apply` is VM only |
| [`../../scripts/fabric-bgp-summary.py`](../../scripts/fabric-bgp-summary.py) | exact `state` == `Established` |
| [`../../scripts/fabric-dashboard-state.py`](../../scripts/fabric-dashboard-state.py) | `routers=N/N sessions=N/N external=N` |
| [`../../demos/shared/browser-shot.sh`](../../demos/shared/browser-shot.sh) | headless Chrome shot |
| [`NETWORK-TEAM-SHEET.md`](NETWORK-TEAM-SHEET.md) | §8 filled for both LANs |

## Troubleshooting

- Dashboard shows routers 0/4 or `/api/state` fails: another container
  published `FABRIC_DASHBOARD_PORT` (default 8088) — the up script
  names the holder and refuses to start — or an agent is not bound
  yet.

```bash
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  ps
docker compose -p bgp-fabric \
  -f demos/55-bgp-fabric-desktop/fabric/compose.yaml \
  -f demos/55-bgp-fabric-desktop/fabric/compose.lan-eg.yaml \
  logs spine
```

- `client0` cannot reach any agent (`client0_rc=28,28,28,28`): FORWARD
  drops transit onto `10.200.200.0/24`; INPUT drops the agent's port
  on every interface but `mgmt` and `lo`.
- `TCP MD5 in effect` is WARN: this kernel has no `TCP_MD5SIG`. Every
  `password` is refused and the sessions run unsigned.

## Clean up

```bash
demos/55-bgp-fabric-desktop/cleanup.sh
```

The fabric's own networks go; `kind` and `kind-eg` stay.

## What's next

- Demo 56 attaches `eg-poc1` (kube-vip in BGP mode) to this fabric.
- Demo 57 attaches `eg-poc2` (MetalLB FRR-K8s BGP) to this fabric.
- Demos 47–49 attach the Cilium clusters (paused today).
